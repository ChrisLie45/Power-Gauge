// What the app reads about this Mac without privileges: its model, processor and memory, and
// how busy its CPUs and memory are.

import Foundation

enum ThisMac {
  /// This Mac's model identifier, such as "MacBookPro16,1".
  static let model = Sysctl.string("hw.model")

  /// "Intel Core i9-9980HK", from "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"; nil if the system
  /// does not say.
  static let processor: String? = {
    guard var name = Sysctl.string("machdep.cpu.brand_string") else { return nil }
    if let speed = name.range(of: " @") { name = String(name[..<speed.lowerBound]) }
    for part in ["(R)", "(TM)", " CPU"] { name = name.replacingOccurrences(of: part, with: "") }
    name = name.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
  }()

  /// The processor's base clock, in MHz, from the first of the places macOS gives it: its
  /// nominal frequency, the "@ 2.40GHz" its name ends with, or the rate of its time-stamp
  /// counter, which Intel processors run at their base clock. nil if none of them says, so that
  /// the base line and turbo are left out rather than judged against a guess.
  static let nominalMHz: Double? = {
    if let hz = Sysctl.int("hw.cpufrequency"), hz > 0 { return Double(hz) / Units.hertzPerMHz }
    let unit = "GHz"
    if let name = Sysctl.string("machdep.cpu.brand_string"), name.hasSuffix(unit),
      let at = name.range(of: "@ ", options: .backwards),
      let ghz = Double(name[at.upperBound...].dropLast(unit.count)),
      ghz > 0
    {
      return ghz * Units.mhzPerGHz
    }
    return Sysctl.int("machdep.tsc.frequency").flatMap {
      $0 > 0 ? Double($0) / Units.hertzPerMHz : nil
    }
  }()

  /// The logical CPUs, threads included.
  static let cpuCount = ProcessInfo.processInfo.processorCount
  /// The physical cores, each of which may run two of the CPUs.
  static let coreCount = Sysctl.int("hw.physicalcpu") ?? cpuCount

  /// The Mac's memory, in GB of 2^30 bytes as macOS counts them.
  static let memoryGB: Double = {
    var bytes: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
    return Double(bytes) / Units.bytesPerGB
  }()

  /// The Mac's memory in use, counted as Activity Monitor's "Memory Used" is (app memory, wired and
  /// compressed), the compressed part of it, and swap in use, all in GB.
  ///
  /// One Mach call and one sysctl: nothing from a driver or the SMC, and no privileges.
  static func memoryInUse() -> (used: Double, compressed: Double, swap: Double?)? {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let status = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return nil }
    let pageGB = Double(vm_kernel_page_size) / Units.bytesPerGB
    let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
    let compressed = Double(stats.compressor_page_count) * pageGB
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    let swapUsed =
      sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
      ? Double(swap.xsu_used) / Units.bytesPerGB : nil
    return ((appPages + Double(stats.wire_count)) * pageGB + compressed, compressed, swapUsed)
  }
}

/// Cumulative busy and total CPU ticks across all cores, as one read gives them; the CPUs'
/// utilization is the share of the ticks between two reads that were busy.
struct CPUTicks {
  let busy: Double
  let total: Double

  static func read() -> CPUTicks? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
    )
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return nil }
    // In the order of CPU_STATE_USER, _SYSTEM, _IDLE and _NICE.
    let (user, system, idle, nice) = info.cpu_ticks
    let busy = Double(user) + Double(system) + Double(nice)
    return CPUTicks(busy: busy, total: busy + Double(idle))
  }

  /// The CPUs' utilization since `earlier`, as a percentage: nil without an earlier read, or
  /// with no ticks between the two.
  func utilization(since earlier: CPUTicks?) -> Double? {
    guard let earlier = earlier, total > earlier.total else { return nil }
    return 100 * (busy - earlier.busy) / (total - earlier.total)
  }
}

/// The facts about this Mac that the dashboard shows.
///
/// The snapshot mode gives it fixed ones instead, so that its pictures are the same whichever Mac
/// makes them.
struct MachineInfo {
  /// As `ThisMac.processor` gives it.
  var processor: String?
  /// nil where macOS doesn't give it.
  var baseMHz: Double?
  var memoryGB: Double

  static let current = MachineInfo(
    processor: ThisMac.processor,
    baseMHz: ThisMac.nominalMHz,
    memoryGB: ThisMac.memoryGB
  )
}
