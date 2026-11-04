// The CPU's readings for one second, and where they come from.

import Foundation

/// Where the CPU's readings come from.
enum ReadingsSource: String {
  /// The kernel's power statistics and the SMC (`KernelStats`), with no password.
  case kernel
  /// powermetrics, run as root, which needs an administrator password.
  case powermetrics
}

/// The CPU's readings for one second, from powermetrics or, read the same way, from the kernel.
struct Sample {
  var source = ReadingsSource.powermetrics
  var systemMHz: Double?
  /// Each CPU's average frequency while active.
  var coreMHz: [Double] = []
  /// The lowest and highest clock any CPU worked at in the second, from readings 10 ms apart,
  /// where the kernel's readings give them (`KernelStats.activeMHz`).
  var burstMHz: ClosedRange<Double>?
  /// The highest clock in the second: a CPU's fastest burst where known, otherwise the fastest
  /// CPU's average while active.
  var peakMHz: Double? { burstMHz?.upperBound ?? coreMHz.max() ?? systemMHz }
  /// The lowest clock in the second, chosen as `peakMHz` is.
  var lowMHz: Double? { burstMHz?.lowerBound ?? coreMHz.min() ?? systemMHz }
  var packageWatts: Double?
  var cpuWatts: Double?
  /// The integrated GPU's power.
  var gpuWatts: Double?
  /// The integrated GPU's average frequency while active.
  var gpuMHz: Double?
  var dramWatts: Double?
  var cpuTempC: Double?
  /// Each core's temperature, from the SMC (`coreTemperatures`), read beside each sample.
  var coreTempsC: [Double] = []
  var fanRPM: Double?
  var prochots: Int?
  // The processor's limit reasons (see CPULimits): perf_limit_reasons, the names, which
  // powermetrics leaves out when there are none; and ia_frq_clipping_cause and
  // gt_frq_clipping_cause, the same as Intel's bits for the cores and the integrated GPU.
  var limits: [String] = []
  var cpuClipping: Int?
  var gpuClipping: Int?
  /// Whether the sample has the processor's package record, where they are given.
  var reportsLimits = false
  /// The Mac's, read beside each sample.
  var memory: (used: Double, compressed: Double, swap: Double?)?
  /// When it was read from the stream, in seconds of uptime, which only go forward.
  var arrived: TimeInterval?
}
