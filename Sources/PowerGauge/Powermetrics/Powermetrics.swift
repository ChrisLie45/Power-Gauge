// powermetrics' output: its stream split into plist documents, and each document read as a
// sample.

import Foundation

/// Reads powermetrics' plist samples.
enum Powermetrics {
  /// Reads one plist document from `powermetrics -f plist` on Intel, taking what is there.
  ///
  /// It takes these keys:
  ///
  /// ```
  /// processor: freq_hz, package_watts, packages[]: perf_limit_reasons[], ia_frq_clipping_cause,
  ///            gt_frq_clipping_cause, cores[]: cpus[]: cpu, freq_hz
  ///            and with --show-extra-power-info: cpu_watts, igpu_watts, dram_watts
  /// smc:       cpu_die, fan, num_prochots                    (smc sampler)
  /// GPU[]:     freq_hz, for the integrated GPU only          (gpu_power sampler)
  /// ```
  ///
  /// The frequencies are averages over the time each CPU was active, idle left out (powermetrics'
  /// manual: the average frequency "when not idle within the sampled interval"); `freq_hz` is the
  /// system's, weighted by active time, which is why it is not the mean of the CPUs' own. So they
  /// read high on a nearly idle Mac, whose brief wake-ups often run at turbo.
  static func parse(_ data: Data) -> Sample? {
    guard
      let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any]
    else { return nil }
    var sample = Sample()
    if let processor = root["processor"] as? [String: Any] {
      sample.systemMHz = (processor["freq_hz"] as? NSNumber).flatMap {
        $0.doubleValue.isFinite ? $0.doubleValue / Units.hertzPerMHz : nil
      }
      sample.packageWatts = number("package_watts", in: processor)
      sample.cpuWatts = number("cpu_watts", in: processor)
      sample.gpuWatts = number("igpu_watts", in: processor)
      sample.dramWatts = number("dram_watts", in: processor)
      sample.reportsLimits = processor["packages"] != nil
      sample.limits = (find("perf_limit_reasons", in: processor) as? [String]) ?? []
      sample.cpuClipping = (find("ia_frq_clipping_cause", in: processor) as? NSNumber)?.intValue
      sample.gpuClipping = (find("gt_frq_clipping_cause", in: processor) as? NSNumber)?.intValue
      var cpus: [(cpu: Int, mhz: Double)] = []
      cpuFrequencies(in: processor, into: &cpus)
      sample.coreMHz = cpus.sorted { $0.cpu < $1.cpu }.map { $0.mhz }
    }
    // The integrated GPU's average frequency while it was active: 0 when it was idle for the
    // whole sample, as it often is, which is no frequency, so it is left out rather than
    // plotted as 0 MHz.
    if let gpu = (root["GPU"] as? [[String: Any]])?.first, let hz = gpu["freq_hz"] as? NSNumber,
      hz.doubleValue.isFinite,
      hz.doubleValue > 0
    {
      sample.gpuMHz = hz.doubleValue / Units.hertzPerMHz
    }
    let smc = root["smc"]
    sample.cpuTempC = number("cpu_die", in: smc)
    sample.fanRPM = number("fan", in: smc)
    sample.prochots = number("num_prochots", in: smc).flatMap { Int(exactly: $0) }
    if sample.systemMHz == nil, !sample.coreMHz.isEmpty {
      sample.systemMHz = sample.coreMHz.reduce(0, +) / Double(sample.coreMHz.count)
    }
    return sample
  }

  /// Depth-first search for the first value stored under `key` anywhere in a plist.
  private static func find(_ key: String, in node: Any) -> Any? {
    if let dict = node as? [String: Any] {
      if let hit = dict[key] { return hit }
      for value in dict.values { if let hit = find(key, in: value) { return hit } }
    } else if let array = node as? [Any] {
      for value in array { if let hit = find(key, in: value) { return hit } }
    }
    return nil
  }

  private static func number(_ key: String, in node: Any?) -> Double? {
    guard let node = node, let number = find(key, in: node) as? NSNumber else { return nil }
    let value = number.doubleValue
    return value.isFinite ? value : nil
  }

  /// Collects (cpu index, MHz) from every per-CPU dictionary, wherever it is nested.
  private static func cpuFrequencies(in node: Any, into out: inout [(cpu: Int, mhz: Double)]) {
    if let dict = node as? [String: Any] {
      if let cpu = dict["cpu"] as? NSNumber, let hz = dict["freq_hz"] as? NSNumber,
        hz.doubleValue.isFinite
      {
        out.append((cpu.intValue, hz.doubleValue / Units.hertzPerMHz))
      }
      for value in dict.values { cpuFrequencies(in: value, into: &out) }
    } else if let array = node as? [Any] {
      for value in array { cpuFrequencies(in: value, into: &out) }
    }
  }
}

/// Splits the powermetrics stream into plist documents as they complete.
struct PlistStream {
  private var buffer = Data()
  private let terminator = Data("</plist>".utf8)

  private static let separators: Set<UInt8> = [
    0,
    UInt8(ascii: "\n"),
    UInt8(ascii: "\r"),
    UInt8(ascii: " "),
  ]

  mutating func append(_ chunk: Data) -> [Data] {
    buffer.append(chunk)
    var documents: [Data] = []
    while let end = buffer.range(of: terminator) {
      var document = buffer.subdata(in: buffer.startIndex..<end.upperBound)
      buffer.removeSubrange(buffer.startIndex..<end.upperBound)
      // Documents are separated by NUL bytes and newlines.
      while let first = document.first, PlistStream.separators.contains(first) {
        document.removeFirst()
      }
      if !document.isEmpty { documents.append(document) }
    }
    return documents
  }
}
