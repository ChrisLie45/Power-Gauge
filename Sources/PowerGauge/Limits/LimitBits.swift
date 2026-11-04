import Foundation

/// The processor's limit bits and their names, which differ by generation.
///
/// xnu reads the cores' register at 0x64F on the Skylake, Kaby Lake (which takes in Coffee Lake),
/// Ice Lake and Comet Lake families, and at 0x690, Haswell's layout, on any other; the integrated
/// GPU's at 0x6B0. The names are Apple's, as powermetrics gives them. For the Skylake layout they
/// are the names of the "msr limits" channels that Apple's pmtelemetry driver publishes through
/// IOReport, which name every bit, those Intel reserves for these processors included (`SPARE_IA_9`
/// and the like). For Haswell they are the names in Apple's driver for its bits (GTDRIVER,
/// `IA_UTILIZATION`, `VR_ICCMAX`, RAPL). A bit with no name is shown by number.
enum LimitBits {
  enum Layout { case haswell, skylake }

  /// This Mac's layout, from its CPU family as the kernel gives it.
  static let current = layout(cpuFamily: Sysctl.int("hw.cpufamily") ?? 0)

  /// CPU families as `hw.cpufamily` gives them: `CPUFAMILY_INTEL_SKYLAKE` and so on, in xnu's
  /// `mach/machine.h`.
  private enum CPUFamily {
    static let skylake: UInt32 = 0x37fc219f
    /// Which takes in Coffee Lake.
    static let kabyLake: UInt32 = 0x0f817246
    static let iceLake: UInt32 = 0x38435547
    static let cometLake: UInt32 = 0x1cf8a03e
  }

  /// The families whose cores' register xnu reads at 0x64F, in Skylake's layout.
  private static let skylakeLayoutFamilies = [
    CPUFamily.skylake,
    CPUFamily.kabyLake,
    CPUFamily.iceLake,
    CPUFamily.cometLake,
  ]

  static func layout(cpuFamily: Int) -> Layout {
    skylakeLayoutFamilies.contains(UInt32(truncatingIfNeeded: cpuFamily)) ? .skylake : .haswell
  }

  /// The cores' bits.
  ///
  /// Skylake and later (SDM table 2-39): bits 2, 3, 9 and 15 are reserved for these processors, and
  /// 14 is too in Intel's documents, but Apple names it TVB (Thermal Velocity Boost), as HWiNFO
  /// does; Apple's names for 2 and 3, `DDR_RAPL` and `PECI_LIMIT`, are those bits' meanings on
  /// later processors (11th generation). Haswell (table 2-30): 4 is the graphics driver's override,
  /// 5 autonomous utilization-based frequency control, 8 the electrical design point (maximum
  /// current), 9 the cores' own power limit; 7 is reserved.
  static func cpu(_ layout: Layout) -> [Int: String] {
    switch layout {
    case .skylake:
      return [
        0: "PROCHOT",
        1: "THERMAL",
        2: "DDR_RAPL",
        3: "PECI_LIMIT",
        4: "RSR_LIMIT",
        5: "RATL",
        6: "VR_THERMALERT",
        7: "VR_TDC",
        8: "ICCMAX/PL4/OTHER",
        9: "SPARE_IA_9",
        10: "PL1",
        11: "PL2_PL3",
        12: "MAX_TURBO_LIMIT",
        13: "TURBO_ATTENUATION",
        14: "TVB",
        15: "SPARE_IA_15",
      ]
    case .haswell:
      return [
        0: "PROCHOT",
        1: "THERMAL",
        4: "GTDRIVER",
        5: "IA_UTILIZATION",
        6: "VR_THERMALERT",
        8: "VR_ICCMAX",
        9: "RAPL",
        10: "PL1",
        11: "PL2",
        12: "MAX_TURBO_LIMIT",
        13: "TURBO_ATTENUATION",
      ]
    }
  }

  /// The integrated GPU's bits.
  ///
  /// Skylake and later: 12 is inefficient operation (the GPU below its target frequency), and 2, 3,
  /// 9, 13, 14 and 15 are reserved, which Apple, after Intel's own field names, calls `SPARE_GT_2`
  /// and so on. Haswell: as the cores', with 9 the graphics' own power limit.
  static func gpu(_ layout: Layout) -> [Int: String] {
    switch layout {
    case .skylake:
      return [
        0: "PROCHOT",
        1: "THERMAL",
        2: "SPARE_GT_2",
        3: "SPARE_GT_3",
        4: "RSR_LIMIT",
        5: "RATL",
        6: "VR_THERMALERT",
        7: "VR_TDC",
        8: "ICCMAX/PL4/OTHER",
        9: "SPARE_GT_9",
        10: "PL1",
        11: "PL2_PL3",
        12: "INEFFICIENT_OP",
        13: "SPARE_GT_13",
        14: "SPARE_GT_14",
        15: "SPARE_GT_15",
      ]
    case .haswell:
      return [
        0: "PROCHOT",
        1: "THERMAL",
        4: "GTDRIVER",
        5: "GT_UTILIZATION",
        6: "VR_THERMALERT",
        8: "VR_ICCMAX",
        9: "RAPL",
        10: "PL1",
        11: "PL2",
      ]
    }
  }

  /// A register's value as limit bits, or nil if it is no reading.
  ///
  /// When the kernel cannot read the register it gives all ones (`Diagnostics.c` starts each at
  /// ~0), and powermetrics writes the value as a signed 32-bit number, so that comes as -1; any
  /// other negative number is the reserved bit 31 set, and is read as the 32 bits it is.
  static func reading(_ raw: Int) -> Int? {
    if raw == unreadable || raw > Int(UInt32.max) || raw < Int(Int32.min) { return nil }
    return raw & Int(UInt32.max)
  }

  /// How powermetrics writes a register that couldn't be read: all ones, as a signed number.
  static let unreadable = -1

  /// The bits for the reasons limiting the processor now; the high 16 are the same reasons, logged.
  static let currentBits = 0..<16

  /// The names of the reasons limiting now, the low 16 bits, in the order of their bits.
  static func now(_ bits: Int, _ names: [Int: String]) -> [String] {
    currentBits.filter { (bits >> $0) & 1 == 1 }.map { names[$0] ?? "bit \($0)" }
  }
}
