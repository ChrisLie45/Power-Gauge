import Foundation

/// The kinds of limit on the CPU (see `CPULimits`), from the least to the most a reason to look
/// at the Mac.
enum LimitKind: Int, Comparable {
  /// Part of how turbo works, or not documented: shown, not counted as throttling.
  case normal
  /// The package's power or current budget, or Low Power Mode: expected under heavy load.
  case power
  /// Heat: the processor's thermal limit, a voltage regulator's thermal alert.
  case thermal
  /// macOS capping the CPU: its speed or scheduler limit, or CPUs taken offline.
  case macOS
  /// Something outside the processor told it to slow down hard (PROCHOT).
  case prochot

  static func < (a: LimitKind, b: LimitKind) -> Bool { a.rawValue < b.rawValue }

  /// The kind of a reason, by the words of its name, so that names with no entry here, such as
  /// other generations', are sorted too.
  ///
  /// PROCHOT first, as its own kind; then thermal words, so that a voltage regulator's thermal
  /// alert counts as heat, not power; then the turbo and other normal ones, so that TVB is normal;
  /// then power. A name with none of these words is shown as it is and counted as normal: it is not
  /// called throttling without knowing what it means.
  static func of(_ reason: String) -> LimitKind {
    let name = reason.uppercased()
    if name.contains("PROCHOT") { return .prochot }
    if ["THERM", "RATL"].contains(where: name.contains) { return .thermal }
    if ["TURBO", "ATTEN", "TVB", "RSR", "RESIDENCY", "UTILIZATION", "GTDRIVER", "INEFFICIENT"]
      .contains(where: name.contains)
    {
      return .normal
    }
    if ["PL1", "PL2", "PL4", "ICCMAX", "TDC", "EDP", "RAPL", "PBM", "PECI", "POWER", "CURRENT"]
      .contains(where: name.contains)
    {
      return .power
    }
    return .normal
  }
}
