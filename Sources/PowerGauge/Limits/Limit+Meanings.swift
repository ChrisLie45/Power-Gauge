// What each limit means, for the tooltip on the list of them.

import Foundation

extension Limit {
  /// What it means, in a sentence or two.
  var meaning: String {
    // macOS's limits are as IOPM.h describes them: limits that keep the CPU "within allowable
    // thermal and power constraints", which the Mac's SMC works out and the kernel applies. So a
    // cap can be for heat or for power, such as an adapter or a battery that cannot supply enough.
    if name.hasPrefix("macOS speed limit") {
      return
        "macOS is capping the CPU at this share of its top frequency, to keep the Mac "
        + "within its thermal or power limits: usually heat, or a power adapter or battery "
        + "that cannot supply enough."
    }
    if name.hasPrefix("macOS scheduler limit") {
      return
        "macOS is giving the CPU only this share of the time, idling it for the rest, to "
        + "keep the Mac within its thermal or power limits."
    }
    if name.hasPrefix("macOS allows") {
      return
        "macOS has taken some CPUs offline, to keep the Mac within its thermal or power limits."
    }
    switch name {
    // Apple described Low Power Mode on Intel Macs as reducing "the system clock speed" (2021,
    // macOS 12); by how much it has not said.
    case "Low Power Mode":
      return "Low Power Mode is on, which lowers the CPU's speed to save energy."
    // Intel: PROCHOT asserted from outside the processor drops it to its lowest speed at once.
    // powermetrics has "SMC asserting prochot" among its strings.
    // That a failing battery or a weak charger can be behind it is known from repair reports, not
    // from Apple, whose only note on it (HT2332, 2008, since retired) was about MacBooks run
    // without their battery.
    case "PROCHOT":
      return
        "Something outside the processor (on a Mac, its SMC) has told it to slow down hard, "
        + "which drops it to its lowest speed. That is rare on a Mac: a part running too hot, "
        + "or a power fault, which repair reports tie to failing batteries and to chargers "
        + "that cannot supply enough."
    // Intel: thermal control acts when the processor reaches its maximum temperature (TjMax,
    // 100 °C on most Intel Mac processors), or earlier if the firmware sets an offset.
    case "THERMAL":
      return
        "The processor is at its temperature limit (100 °C on most Intel Mac processors) "
        + "and is slowing down to stay below it."
    case "RATL": return "The processor's running average temperature limit."
    case "VR_THERMALERT": return "A voltage regulator feeding the processor is too hot."
    case "VR_TDC":
      return
        "A voltage regulator feeding the processor is at the current it can carry for long periods."
    // Intel: "Other", the electrical design point: IccMax, PL4 and voltage limits.
    case "ICCMAX/PL4/OTHER", "VR_ICCMAX":
      return
        "The processor is at the limit of the current or power it may draw (its maximum "
        + "current, PL4 and like electrical limits). Expected under heavy load."
    case "RAPL": return "The cores' (or the graphics') own power limit. Expected under heavy load."
    case "PL1":
      return
        "The package's long-term power limit, about its rated power, averaged over a time "
        + "window. Expected under sustained load."
    case "PL2", "PL2_PL3":
      return
        "The package's power limit for turbo, above its long-term limit (PL1), or its PL3 "
        + "peak limit. Expected in bursts of heavy load."
    case "MAX_TURBO_LIMIT":
      return
        "The processor is at the highest turbo frequency allowed for the number of busy "
        + "cores. Normal."
    case "TURBO_ATTENUATION":
      return "The processor is holding back from changing its turbo frequency too often. Normal."
    // Intel: TVB adds up to 200 MHz on the i9-9980HK at 50 °C or below, with power to spare.
    case "TVB":
      return
        "Thermal Velocity Boost withheld: the processor does not get the extra turbo it "
        + "gets while cool (50 °C or below on the i9-9980HK), because it is warmer. Normal. "
        + "Apple's name: Intel's documents list this bit as reserved."
    case "RSR", "RSR_LIMIT":
      return "Residency state regulation, an Intel power-saving limit. Normal."
    case "DDR_RAPL": return "The memory's power limit."
    case "PECI_LIMIT":
      return
        "A power limit set from outside the processor by the platform, over its PECI interface."
    case "GTDRIVER": return "The graphics driver has asked for a lower frequency. Normal."
    case "IA_UTILIZATION", "GT_UTILIZATION":
      return "The processor lowered its frequency because it is lightly used. Normal."
    case "INEFFICIENT_OP":
      return
        "The integrated GPU is running below its target frequency because a higher one "
        + "would not help. Normal."
    case let spare where spare.hasPrefix("SPARE_"):
      return "A bit Intel's documents list as reserved, with no meaning given."
    default: return "A limit Power Gauge does not know, so it is not counted as throttling."
    }
  }
}
