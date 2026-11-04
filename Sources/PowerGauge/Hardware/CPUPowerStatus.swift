import Foundation
import IOKit.pwr_mgt

/// macOS's own limits on the CPU, as `pmset -g therm` shows them (pmset reads them with
/// `IOPMCopyCPUPowerStatus` too).
///
/// Apple's `IOPM.h` describes them as limits that keep the CPU "within allowable thermal and power
/// constraints":
/// - the speed it lets the CPU run at, as a percentage of its maximum;
/// - the share of CPU time available, also a percentage, "100% at normal operation";
/// - how many CPUs are available.
/// The Mac's SMC works them out and the kernel applies them. Any of them may be missing, and
/// each is nil while it is. Then two more:
/// - whether Low Power Mode is on;
/// - the highest frequency the kernel's power management lets the CPU run at now:
///   `machdep.xcpm.hard_plimit_max_100mhz_ratio`, in steps of 100 MHz. That setting is
///   undocumented (XCPM is not open source); it moves with the speed limit, as that share of
///   the top frequency.
struct CPUPowerStatus: Equatable {
  var speedLimit: Int?
  var schedulerLimit: Int?
  var availableCPUs: Int?
  var lowPowerMode = false
  var ceilingMHz: Double?

  /// What the speed and scheduler limits read while they aren't limiting: 100 %.
  static let unlimited = 100
  /// `hard_plimit_max_100mhz_ratio` counts in steps of 100 MHz.
  static let ceilingStepMHz = 100.0

  /// The limits now.
  ///
  /// macOS's are read straight from IOKit as pmset reads them (about 0.1 ms, where running pmset
  /// would take a process each time). Low Power Mode is asked of macOS where it can say (macOS 12
  /// and later), and of the kernel otherwise.
  static func read() -> CPUPowerStatus {
    var result = CPUPowerStatus()
    var status: Unmanaged<CFDictionary>?
    if IOPMCopyCPUPowerStatus(&status) == kIOReturnSuccess,
      let values = status?.takeRetainedValue() as? [String: Any]
    {
      result.speedLimit = (values["CPU_Speed_Limit"] as? NSNumber)?.intValue
      result.schedulerLimit = (values["CPU_Scheduler_Limit"] as? NSNumber)?.intValue
      result.availableCPUs = (values["CPU_Available_CPUs"] as? NSNumber)?.intValue
    }
    result.lowPowerMode = Sysctl.int("machdep.xcpm.lpm_enabled").map { $0 != 0 } ?? false
    #if compiler(>=5.5.1)
      if #available(macOS 12.0, *) {
        result.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
      }
    #endif
    result.ceilingMHz = Sysctl.int("machdep.xcpm.hard_plimit_max_100mhz_ratio").flatMap {
      $0 > 0 ? Double($0) * ceilingStepMHz : nil
    }
    return result
  }
}
