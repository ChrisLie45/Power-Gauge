// Made-up hardware and readings for the test modes, the same on any Mac.

import Cocoa

enum MadeUp {
  /// Made-up GPUs, by make, as a comma-separated list such as "intel,amd" (a MacBook Pro 16-inch),
  /// "intel" (a MacBook Air), "amd,amd" (a Mac Pro) or "intel,nvidia" (a MacBook Pro of 2014).
  static func gpus(_ list: String = "intel,amd") -> [GPU] {
    GPU.numbered(
      list.split(separator: ",").compactMap { make -> GPU? in
        switch make {
        case "intel":
          return GPU(
            name: "Intel UHD Graphics 630",
            short: "Intel",
            color: .systemBlue,
            integrated: true
          )
        case "amd":
          return GPU(
            name: "AMD Radeon Pro 5500M",
            short: "AMD",
            color: .systemRed,
            memoryGB: 8176.0 / 1024
          )
        case "nvidia":
          return GPU(
            name: "NVIDIA GeForce GT 750M",
            short: "NVIDIA",
            color: .systemGreen,
            memoryGB: 2
          )
        default: return nil
        }
      }
    )
  }

  /// What a made-up GPU reports at `seconds`: the Intel driver reports utilisation and memory only,
  /// the AMD one adds power, temperature and clocks, and for the NVIDIA one temperature and power
  /// come from the SMC.
  ///
  /// A second GPU of a make runs two seconds behind the first.
  static func reading(_ gpu: GPU, at seconds: Double) -> GPUReading {
    let lag = 2.0  // seconds behind the first of its make
    let seconds = seconds + Double(gpu.nth - 1) * lag
    switch gpu.short.split(separator: " ").first {
    case "Intel":
      return GPUReading(
        utilization: 12 + 8 * sin(seconds / 2),
        memoryGB: 0.25 + 0.05 * sin(seconds / 3)
      )
    case "NVIDIA":
      return GPUReading(
        utilization: 30 + 20 * sin(seconds / 3),
        watts: 18 + 6 * sin(seconds / 3),
        tempC: 64 + 6 * sin(seconds / 5),
        memoryGB: 0.6 + 0.2 * sin(seconds / 4)
      )
    default:
      return GPUReading(
        utilization: 40 + 30 * sin(seconds / 3),
        watts: 22 + 6 * sin(seconds / 3),
        tempC: 68 + 5 * sin(seconds / 5),
        coreMHz: 500 + 400 * sin(seconds / 3),
        memoryMHz: 1472,
        memoryGB: 0.85 + 0.35 * sin(seconds / 4)
      )
    }
  }

  // The Mac the snapshots show, whatever Mac makes them: a MacBook Pro 16-inch of 2019, or a Mac
  // Pro of 2019 with the most cores one came with; each core runs two CPUs.
  static let machine = MachineInfo(processor: "Intel Core i9-9980HK", baseMHz: 2400, memoryGB: 32)
  static let cores = 8
  static let macPro = MachineInfo(processor: "Intel Xeon W-3275M", baseMHz: 2500, memoryGB: 96)
  static let macProCores = 28
  static let cpusPerCore = 2

  /// Made-up readings of the kernel's statistics at `seconds`, as from a running Mac: the package
  /// drawing 20 W, the cores 15, the integrated GPU 1 and the memory 1.5, in the usual unit
  /// (1/16384 J), and `cpus` CPUs busy a quarter, a half and so on of the time at 1.5 times the
  /// base clock.
  ///
  /// `nanoseconds` is when they were read.
  static func kernelReading(
    seconds: Double,
    nanoseconds: UInt64,
    cpus: Int = 4,
    baseMHz: Double = KernelStats.baseMHz ?? 2400
  ) -> KernelStats.Reading {
    func energy(_ watts: Double) -> UInt64 {
      UInt64(watts * seconds * countsPerJoule) & UInt64(UInt32.max)
    }
    let turbo = 1.5  // the CPUs' clock over the base clock
    let cpuList = (0..<cpus).map { cpu -> KernelStats.CPU in
      let busy = 0.25 * Double(cpu % 4 + 1)
      let mperf = baseMHz * Units.hertzPerMHz * busy * seconds
      let ticks = seconds * Units.nanosecondsPerSecond / KernelStats.timebase
      return KernelStats.CPU(
        aperf: UInt64(mperf * turbo),
        mperf: UInt64(mperf),
        run: UInt64(busy * ticks),
        idle: UInt64((1 - busy) * ticks)
      )
    }
    return KernelStats.Reading(
      nanoseconds: nanoseconds,
      unit: energyUnitRegister,
      package: energy(20),
      cores: energy(15),
      graphics: energy(1),
      memory: energy(1.5),
      cpuLimits: 0,
      gpuLimits: 0,
      cpus: cpuList
    )
  }

  // The usual energy unit, 1/2^14 J (bits 8 to 12 of the register read 14), and the counts it makes
  // in a joule.
  static let energyUnitRegister: UInt64 = 0xA0E03
  static let countsPerJoule = 16384.0
}

/// The kernel's statistics made up as time passes (`MadeUp.kernelReading`), for the app check,
/// until told to break: then each reading has CPU 0's MPERF going backwards, which can't be
/// trusted.
final class MadeUpKernel {
  private let lock = NSLock()
  private var broken = false
  private var calls: UInt64 = 0
  private let started = KernelStats.nanoseconds()

  func breakReadings() {
    lock.lock()
    broken = true
    lock.unlock()
  }

  func read() -> KernelStats.Reading? {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    let now = KernelStats.nanoseconds()
    let uptime = 100.0  // as if the Mac had been up this many seconds at the start
    var reading = MadeUp.kernelReading(
      seconds: uptime + Double(now - started) / Units.nanosecondsPerSecond,
      nanoseconds: now
    )
    if broken { reading.cpus[0].mperf = 1 << 50 - calls }  // falling from far above any real count
    return reading
  }
}
