// The GPUs, as their drivers publish them in the I/O Registry, and what they report.

import Cocoa
import IOKit

/// A GPU as its driver publishes it in the I/O Registry.
///
/// The Intel, AMD and NVIDIA drivers all keep a "`PerformanceStatistics`" dictionary there that any
/// process may read, so this needs no privileges; what it holds beyond utilisation depends on the
/// driver.
///
/// Utilisation is every driver's own "Device Utilization %" by default (`UtilizationSource.driver`),
/// the figure other GPU monitors show. A driver works it out over the time since its statistics
/// were last read, by any process, so it reads true only while nothing else reads them: a second
/// read straight after another gives about 0 %.
///
/// Monitor > GPU Utilization can take it from the busy-time counters the driver keeps
/// (`GPUBusyCounters`) instead, where it keeps them, as the AMD driver does. They follow the load
/// more closely, since the drivers' own percentages each count their own way: AMD's "Device
/// Utilization %" reads well under 100 % for a GPU busy all the time, and Intel's is scaled by its
/// current clock over its top clock, so it reads low for a GPU busy at a low clock. The drivers'
/// figures are the fallback where there are no counters.
///
/// With the counters chosen, the Intel GPU's utilisation is the driver's "Device Utilization % at
/// cur p-state", the same share of time busy without the scaling by clock, where the driver gives
/// it. Its busy-time counter can stick at 100 %, counting time busy as fast as time passes whether
/// the GPU is idle or loaded, while the driver's figure goes on following the load.
///
/// NVIDIA's driver gives utilisation and nothing more: no temperature, power or clocks. On the
/// Macs in `GPU.nvidiaSMCKeys` its GPU's temperature and power are read from the SMC instead.
struct GPU {
  /// "AMD Radeon Pro 5500M".
  let name: String
  /// "AMD", which labels its lines in the rows.
  let short: String
  let color: NSColor
  /// The one in the processor, which powermetrics also reports on.
  var integrated = false
  /// Its driver's registry entry; 0 for a made-up GPU.
  var service: io_service_t = 0
  /// Which of its make it is; they share its colour, and their lines' patterns tell them apart.
  var nth = 1
  /// Where to read what the driver leaves out.
  var smcKeys: (temperature: String, power: String)?
  /// Its own video memory; nil for one that uses the Mac's memory.
  var memoryGB: Double?

  /// The registry entry's ID, which is how IOReport names the driver its counters come from.
  var registryID: UInt64 {
    var id: UInt64 = 0
    if service != 0 { IORegistryEntryGetRegistryEntryID(service, &id) }
    return id
  }

  /// Whether its utilisation comes from its driver's busy-time counters.
  var hasBusyCounters: Bool { service != 0 && GPUBusyCounters.shared?.covers(registryID) == true }

  /// Where the GPUs' utilisation comes from, as chosen in Monitor > GPU Utilization.
  ///
  /// The drivers' own figure is the default, since it is what other GPU monitors show, though the
  /// busy-time counters follow the load more closely.
  enum UtilizationSource {
    /// Each driver's own "Device Utilization %", as it gives it.
    case driver
    /// The busy-time counters where the driver keeps them, and otherwise the driver's figure
    /// that best follows the load; see `GPU`.
    case busyTime
  }

  /// What the driver reports right now, with the SMC filling in for it where it can.
  ///
  /// Anything that neither reports comes back nil, as does all of it while the system has the GPU
  /// powered down.
  ///
  /// - Parameters:
  ///   - busy: Each GPU's share of time busy from the counters, by registry ID, sampled once for
  ///     all the GPUs by `GPU.readAll(_:utilization:)`.
  ///   - source: Where the utilisation comes from.
  func read(busy: [UInt64: Double] = [:], utilization source: UtilizationSource = .driver)
    -> GPUReading
  {
    guard let stats = statistics() else { return GPUReading(poweredDown: true) }
    return reading(from: stats, busy: busy, utilization: source)
  }

  /// The driver's `PerformanceStatistics`, or nil while the system has the GPU powered down.
  func statistics() -> [String: Any]? {
    func property(_ key: String) -> [String: Any]? {
      guard service != 0 else { return nil }
      return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any]
    }
    if (property("AGCInfo")?["poweredOffByAGC"] as? NSNumber)?.boolValue == true { return nil }
    return property("PerformanceStatistics") ?? [:]
  }

  /// A reading from the driver's statistics as already read, with the counters and the SMC filling
  /// in for it.
  ///
  /// With the busy-time source, a GPU with counters takes its utilisation from them alone. Taking
  /// the statistics once lets `--gpu-check` show both sources' utilisation from the same read.
  ///
  /// - Parameters:
  ///   - stats: The driver's `PerformanceStatistics`.
  ///   - busy: Each GPU's share of time busy from the counters, by registry ID.
  ///   - source: Where the utilisation comes from.
  func reading(
    from stats: [String: Any],
    busy: [UInt64: Double],
    utilization source: UtilizationSource
  )
    -> GPUReading
  {
    var reading = GPU.reading(
      from: stats,
      nvidia: short.hasPrefix("NVIDIA"),
      integrated: integrated,
      utilization: source
    )
    // The Intel driver's own unscaled figure, where it gives one, over its busy-time counter.
    let unscaled = integrated && stats[GPU.unscaledUtilization] != nil
    if source == .busyTime, hasBusyCounters, !unscaled { reading.utilization = busy[registryID] }
    // Readings outside these ranges are a sensor with nothing to report, not a GPU.
    if let keys = smcKeys {
      if reading.tempC == nil, let celsius = SMC.shared.value(keys.temperature), celsius > 0,
        celsius < GPU.smcTemperatureCeilingC
      {
        reading.tempC = celsius
        reading.fromSMC.append("temperature")
      }
      if reading.watts == nil, let watts = SMC.shared.value(keys.power), watts >= 0,
        watts < GPU.smcPowerCeilingW
      {
        reading.watts = watts
        reading.fromSMC.append("power")
      }
    }
    return reading
  }

  /// The Intel driver's share of time busy at its current clock, not scaled down by the clock.
  static let unscaledUtilization = "Device Utilization % at cur p-state"
  /// The unit of NVIDIA's "GPU Core Utilization": ten-millionths of a percent.
  private static let nvidiaUtilizationScale = 10_000_000.0
  // The highest readings from a GPU's SMC keys that are a GPU's, not a sensor with nothing to
  // report.
  private static let smcTemperatureCeilingC = 125.0
  private static let smcPowerCeilingW = 150.0

  /// A reading from a driver's statistics.
  ///
  /// NVIDIA's driver also gives its core's load as "GPU Core Utilization", in ten-millionths of a
  /// percent (60000000 is 6 %), which the busy-time source takes in preference to its "Device
  /// Utilization %"; older versions give it as a plain percentage. The driver source takes
  /// "Device Utilization %" from every driver that has it, and otherwise the figure it has.
  ///
  /// The memory is what the GPU holds: its own video memory for a GPU that has some, the
  /// Mac's memory it has mapped for an integrated one. That is what apps have allocated plus
  /// what the driver keeps cached after they let it go ("orphanedReusable..."), which stays
  /// taken until the driver trims it. The drivers' own "in use" counts leave the cache out,
  /// but the Intel one is its mapped memory less a cache count that can run ahead, so it can
  /// go below zero. The Intel GPU's mapped memory is its mapping space less what is free
  /// there: the driver's own "`gartUsedBytes`" is a 32-bit count that wraps every 2 GB.
  ///
  /// - Parameters:
  ///   - stats: The driver's `PerformanceStatistics`.
  ///   - nvidia: Whether the driver is NVIDIA's.
  ///   - integrated: Whether the GPU is the integrated one.
  ///   - source: Which of the driver's figures the utilisation is.
  static func reading(
    from stats: [String: Any],
    nvidia: Bool,
    integrated: Bool,
    utilization source: UtilizationSource
  ) -> GPUReading {
    func value(_ key: String) -> Double? {
      guard let number = stats[key] as? NSNumber, number.doubleValue.isFinite,
        number.doubleValue >= 0
      else { return nil }
      return number.doubleValue
    }
    let device = value("Device Utilization %")
    let unscaled = integrated ? value(unscaledUtilization) : nil
    let core =
      nvidia
      ? value("GPU Core Utilization").map { $0 > 100 ? $0 / nvidiaUtilizationScale : $0 } : nil
    let utilization = source == .driver ? device ?? unscaled ?? core : core ?? unscaled ?? device
    let mapped = value("gartSizeBytes").flatMap { size in
      value("gartFreeBytes").flatMap { size >= $0 ? size - $0 : nil }
    }
    let memory =
      integrated
      ? mapped
      : value("vramUsedBytes")
        ?? value("inUseVidMemoryBytes").map { $0 + (value("orphanedReusableVidMemoryBytes") ?? 0) }
    return GPUReading(
      utilization: utilization.map { min($0, 100) },
      watts: value("Total Power(W)"),
      tempC: value("Temperature(C)"),
      coreMHz: value("Core Clock(MHz)"),
      memoryMHz: value("Memory Clock(MHz)"),
      memoryGB: memory.map { $0 / Units.bytesPerGB }
    )
  }

  /// Reads every GPU, sampling the busy-time counters once for all of them.
  ///
  /// The counters are sampled whichever source is shown, so that going back to them gives a
  /// reading at once rather than one measured over the whole time away.
  static func readAll(_ gpus: [GPU], utilization source: UtilizationSource = .driver)
    -> [GPUReading]
  {
    let busy = GPUBusyCounters.shared?.sample() ?? [:]
    return gpus.map { $0.read(busy: busy, utilization: source) }
  }
}

struct GPUReading {
  var utilization: Double?
  var watts: Double?
  var tempC: Double?
  var coreMHz: Double?
  var memoryMHz: Double?
  /// Memory the GPU holds; see `GPU.reading(from:nvidia:integrated:)`.
  var memoryGB: Double?
  /// Switched off by the system to save power, so there is nothing to read.
  var poweredDown = false
  /// Which of the readings the SMC gave, the driver having none.
  var fromSMC: [String] = []
}
