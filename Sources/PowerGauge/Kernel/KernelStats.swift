import Foundation

/// Reading the CPU without powermetrics, and so without a password: the kernel's power statistics,
/// and the SMC for the temperature and the fan.
///
/// EXPERIMENTAL, and off unless turned on (`Monitor.readsKernel`, `AppDelegate.Key.kernel`): the
/// app reads powermetrics, Apple's own, by default, since the kernel call is undocumented and the
/// SMC keys for the temperature and fan differ from Mac to Mac.
///
/// The kernel's power statistics come from the diagnostic call that powermetrics itself takes its
/// CPU samples from (xnu's `dgPowerStat`, in `osfmk/i386/Diagnostics.c`). `Monitor` reads these
/// first, and starts powermetrics instead when they can't be read here or give figures that don't
/// hold together. The call itself is made in `KernelStats+Calls.swift`, and `KernelSampler` makes
/// it every 10 ms.
///
/// What one call gives, all as running counts:
/// - for the package: the energy counters of the package, the cores (PP0), the integrated GPU
///   (PP1) and the memory (DDR), the unit they count in, and the cores' and the integrated
///   GPU's limit registers, read during the call;
/// - for each CPU: APERF and MPERF, and the time it has run and been idle, as the CPU last
///   stored them. The call has every CPU store them afresh, but by a message it does not wait
///   for, sent just before it copies them out. So each call gives what the one before had the
///   CPUs store: `KernelSampler`'s calls are 10 ms apart, and a reading taken on its own, as when
///   opening, is two calls 2 ms apart (`Reader.read()`). Each CPU stores its four together, so
///   they agree.
enum KernelStats {
  /// `dgPowerStat`.
  static let powerStatSelector = 17
  // pkg_energy_statistics_t is 416 bytes up to its per-CPU records, core_energy_stat_t, which
  // are 304 bytes each, or 336 in a kernel built with DIAG_ALL_PMCS.
  static let headerSize = 416
  static let plainRecordSize = 304
  static let allPMCsRecordSize = 336
  static let recordSizes = [plainRecordSize, allPMCsRecordSize]

  struct CPU: Equatable {
    var aperf: UInt64
    var mperf: UInt64
    var run: UInt64
    var idle: UInt64
  }

  struct Reading {
    /// When it was read, on the clock that stands still while the Mac sleeps.
    var nanoseconds: UInt64
    /// The energy counters' unit: 1/2^n J, n in bits 8-12.
    var unit: UInt64
    var package: UInt64
    var cores: UInt64
    var graphics: UInt64
    var memory: UInt64
    var cpuLimits: UInt64
    var gpuLimits: UInt64
    var cpus: [CPU]
  }

  /// Why the kernel's statistics can't be read here.
  struct Unavailable: Error { let reason: String }

  /// Why two readings don't give a sample that can be trusted.
  struct Malformed: Error { let reason: String }

  /// What the kernel leaves in a counter or register the processor doesn't have: all ones.
  static let absent: UInt64 = ~0
  // The energy unit is 1/2^n J, with n in bits 8 to 12 of its register: the SDM's Energy Status
  // Units in MSR_RAPL_POWER_UNIT.
  private static let energyUnitShift: UInt64 = 8
  private static let energyUnitMask: UInt64 = 0x1f

  /// What the hardware can do, which each sample is checked against (see sample).
  private enum Bounds {
    /// Between the two readings.
    static let seconds = 0.05...60.0
    /// The units Intel uses: 1/2^8 to 1/2^24 J.
    static let energyExponents: ClosedRange<UInt64> = 8...24
    static let packageWatts = 500.0
    static let memoryWatts = 100.0
    // A part of the package may read a little over the package, the two being read a moment apart.
    static let partOfPackage = 1.05
    static let partOfPackageWatts = 0.5
    // A CPU's run and idle times must cover more than half and less than one and a half times
    // the time that passed.
    static let leastCovered = 0.5
    static let mostCovered = 1.5
    /// MPERF runs at the base clock, so it may only be a little faster, by rounding.
    static let mperfOverBaseClock = 1.05
    static let cpuMHz = 7000.0
  }

  /// The time-stamp counter's rate in MHz, or the processor's nominal clock where the kernel
  /// doesn't give it.
  ///
  /// MPERF counts at the rate of the time-stamp counter, so APERF/MPERF times that rate is the
  /// average frequency while active. Without it the readings can't be used.
  static let baseMHz: Double? =
    Sysctl.int("machdep.tsc.frequency").flatMap { $0 > 0 ? Double($0) / Units.hertzPerMHz : nil }
    ?? ThisMac.nominalMHz

  /// A Xeon counts its memory energy in a unit of its own, which the call doesn't give, so its
  /// memory power is left out rather than shown up to four times too high.
  static let memoryInPackageUnit = !(ThisMac.processor ?? "").contains("Xeon")
  // The keys powermetrics' own table names for the CPU's temperature and for the fan's speed,
  // each Mac having one or another. powermetrics picks its row by model, which Power Gauge can't
  // see, so it takes the first key this Mac has.
  static let temperatureKeys = ["TCXc", "TC0F", "TC0p"]
  static let fanKeys = ["F0Ac", "F1Ac"]

  /// Nanoseconds per tick of `mach_absolute_time`, the clock of the CPUs' run and idle times.
  static let timebase: Double = {
    var info = mach_timebase_info()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
  }()

  static func nanoseconds() -> UInt64 { UInt64(Double(mach_absolute_time()) * timebase) }

  /// The readings between two calls, as powermetrics would have given them, or why they can't be
  /// trusted.
  ///
  /// Each figure is checked against what the hardware can do: the time between the calls is
  /// sensible, the energy unit is one Intel uses, no part of the package draws more than the
  /// package, each CPU's counters have moved forward, its run and idle times add up to the time
  /// that passed, MPERF has run no faster than the base clock, and no CPU has gone faster than 7
  /// GHz. The temperature and fan come from the SMC, on the main thread: see `addSMCReadings`. A
  /// CPU that stored nothing new, as one macOS has taken offline would, makes the readings
  /// untrusted too, since what powermetrics shows for it is not known.
  ///
  /// - Parameters:
  ///   - earlier: The first call's reading.
  ///   - later: The second call's reading.
  ///   - baseMHz: The rate MPERF counts at (see `baseMHz`).
  ///   - memoryInPackageUnit: Whether the memory's energy counts in the package's unit, which a
  ///     Xeon's doesn't (see `memoryInPackageUnit`).
  static func sample(
    from earlier: Reading,
    to later: Reading,
    baseMHz: Double? = KernelStats.baseMHz,
    memoryInPackageUnit: Bool = KernelStats.memoryInPackageUnit
  ) -> Result<Sample, Malformed> {
    func bad(_ reason: String) -> Result<Sample, Malformed> { .failure(Malformed(reason: reason)) }
    guard let baseMHz = baseMHz else { return bad("macOS doesn't give the processor's base clock") }
    guard later.nanoseconds > earlier.nanoseconds else { return bad("the clock went backwards") }
    let seconds = Double(later.nanoseconds - earlier.nanoseconds) / Units.nanosecondsPerSecond
    guard Bounds.seconds.contains(seconds) else {
      return bad(String(format: "%.2f s passed between readings", seconds))
    }
    guard !later.cpus.isEmpty, earlier.cpus.count == later.cpus.count else {
      return bad("the number of CPUs went from \(earlier.cpus.count) to \(later.cpus.count)")
    }
    let exponent = (later.unit >> energyUnitShift) & energyUnitMask
    guard later.unit == earlier.unit, Bounds.energyExponents.contains(exponent) else {
      return bad(String(format: "the energy unit read 0x%llX", later.unit))
    }
    let joulesPerCount = 1 / pow(2, Double(exponent))
    // The energy counters are 32 bits wide and wrap. One that was reset, as sleep can do,
    // reads as a huge figure, which the bounds below catch.
    func watts(_ start: UInt64, _ end: UInt64) -> Double {
      Double(UInt32(truncatingIfNeeded: end &- start)) * joulesPerCount / seconds
    }
    func withinPackage(_ part: Double, _ package: Double) -> Bool {
      part <= package * Bounds.partOfPackage + Bounds.partOfPackageWatts
    }
    var sample = Sample()
    sample.source = .kernel
    let package = watts(earlier.package, later.package)
    let cores = watts(earlier.cores, later.cores)
    guard package < Bounds.packageWatts else {
      return bad(String(format: "the package drew %.0f W", package))
    }
    guard withinPackage(cores, package) else {
      return bad(String(format: "the cores drew %.1f W of the package's %.1f W", cores, package))
    }
    (sample.packageWatts, sample.cpuWatts) = (package, cores)
    // A processor with no integrated GPU has no graphics counter, and the kernel then gives
    // the cores' figure again.
    if earlier.graphics != earlier.cores || later.graphics != later.cores {
      let graphics = watts(earlier.graphics, later.graphics)
      guard withinPackage(graphics, package) else {
        return bad(
          String(
            format: "the integrated GPU drew %.1f W of the package's %.1f W",
            graphics,
            package
          )
        )
      }
      sample.gpuWatts = graphics
    }
    if memoryInPackageUnit, earlier.memory != absent, later.memory != absent {
      let memory = watts(earlier.memory, later.memory)
      guard memory < Bounds.memoryWatts else {
        return bad(String(format: "the memory drew %.0f W", memory))
      }
      sample.dramWatts = memory
    }
    var aperfTotal = 0.0
    var mperfTotal = 0.0
    for (cpu, (before, after)) in zip(earlier.cpus, later.cpus).enumerated() {
      guard after.mperf > before.mperf, after.aperf >= before.aperf, after.run >= before.run,
        after.idle >= before.idle
      else {
        return bad(
          before == after
            ? "CPU \(cpu) stopped reporting, as it would if macOS had taken it offline"
            : "CPU \(cpu)'s counters went backwards"
        )
      }
      let aperf = Double(after.aperf - before.aperf)
      let mperf = Double(after.mperf - before.mperf)
      let covered =
        Double((after.run - before.run) + (after.idle - before.idle)) * timebase
        / Units.nanosecondsPerSecond
      guard covered > seconds * Bounds.leastCovered, covered < seconds * Bounds.mostCovered else {
        return bad(
          String(
            format: "CPU %d's run and idle times cover %.2f s of %.2f s",
            cpu,
            covered,
            seconds
          )
        )
      }
      guard mperf <= seconds * baseMHz * Units.hertzPerMHz * Bounds.mperfOverBaseClock else {
        return bad("CPU \(cpu)'s MPERF ran faster than the base clock")
      }
      let mhz = baseMHz * aperf / mperf
      guard mhz < Bounds.cpuMHz else {
        return bad(String(format: "CPU %d ran at %.0f MHz", cpu, mhz))
      }
      sample.coreMHz.append(mhz)
      aperfTotal += aperf
      mperfTotal += mperf
    }
    sample.systemMHz = baseMHz * aperfTotal / mperfTotal
    // A register the processor doesn't have reads as all ones, which powermetrics writes as -1.
    sample.reportsLimits = true
    sample.cpuClipping =
      later.cpuLimits == absent ? LimitBits.unreadable : Int(later.cpuLimits & UInt64(UInt32.max))
    sample.gpuClipping =
      later.gpuLimits == absent ? LimitBits.unreadable : Int(later.gpuLimits & UInt64(UInt32.max))
    return .success(sample)
  }

  /// The least time a CPU must have run between two readings for its clock to count: one that
  /// hardly ran moves its counters too little to divide reliably.
  static let leastActiveSeconds = 0.000_01

  /// Each CPU's clock while it was active between two readings a moment apart, in MHz, for the
  /// CPUs that ran for long enough (`leastActiveSeconds`) and whose counters moved as they must.
  ///
  /// Turbo boosts last milliseconds, so readings 10 ms apart catch the clock a CPU worked at,
  /// which a second's average, mostly of time spent at lower clocks, hides.
  static func activeMHz(
    from earlier: Reading,
    to later: Reading,
    baseMHz: Double? = KernelStats.baseMHz
  ) -> [Double] {
    guard let baseMHz = baseMHz, earlier.cpus.count == later.cpus.count else { return [] }
    let leastMperf = UInt64(leastActiveSeconds * baseMHz * Units.hertzPerMHz)
    return zip(earlier.cpus, later.cpus).compactMap { before, after in
      guard after.mperf > before.mperf, after.aperf >= before.aperf,
        after.mperf - before.mperf >= leastMperf
      else { return nil }
      let mhz = baseMHz * Double(after.aperf - before.aperf) / Double(after.mperf - before.mperf)
      return mhz < Bounds.cpuMHz ? mhz : nil
    }
  }

  /// The CPU's temperature and the fan's speed, from the SMC (see `temperatureKeys`), on the main
  /// thread, where the SMC is used.
  static func addSMCReadings(to sample: inout Sample) {
    sample.cpuTempC = temperatureKeys.lazy.compactMap { SMC.shared.value($0) }.first {
      $0 > 0 && $0 < SMC.temperatureCeilingC
    }
    sample.fanRPM = fanKeys.lazy.compactMap { SMC.shared.value($0) }.first {
      $0 >= 0 && $0 < fanCeilingRPM
    }
  }

  /// A fan reading at or above this is a sensor with nothing to report.
  private static let fanCeilingRPM = 20_000.0
}
