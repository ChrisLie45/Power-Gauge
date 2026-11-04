// What is holding the CPU back: macOS's own limits on it, and the reasons the processor gives
// for running below the frequency it was asked for, sorted by what they mean for someone looking
// for why the Mac is slow.
//
// Sources:
// - Intel: the Software Developer's Manual, volume 4 (rev 093), table 2-30 (Haswell) and 2-39
//   (6th to 13th generation); the 10th and 11th generation datasheets; the 9th generation mobile
//   product brief (for TVB on the i9-9980HK).
// - Apple: IOKit's IOPM.h and IOPMLib.h; xnu's osfmk/i386/Diagnostics.c, which reads the limit
//   registers for powermetrics, and proc_reg.h; pmset's source (PowerManagement).
//
// The processor's limit register has, in its low 16 bits, the reasons limiting its frequency
// now, and in the high 16 the same reasons logged since software last cleared them by writing
// 0 (Intel). powermetrics gives the register as ia_frq_clipping_cause and gt_frq_clipping_cause,
// and names every bit set in either half in perf_limit_reasons; on some Macs it gives the bits
// without the names. When macOS clears the logged half is not documented, so it may hold limits
// from seconds or hours before, and it fills with brief limits even at idle that slow nothing a
// person would notice. So the processor is judged by its low bits alone: one reading of the
// register at the end of each sample, which can miss a limit that came and went within the
// second but never reports one that is long over. macOS's own limits (see CPUPowerStatus) are
// taken as they are: a hot Mac is often held back by them while the processor gives no reason.

import Foundation

struct Limit: Equatable {
  let name: String
  let kind: LimitKind
}

/// What a sample says about the CPU's limits.
struct CPULimits: Equatable {
  /// macOS's first, then the processor's, in the order of their bits.
  var limits: [Limit] = []
  /// Whether the processor's limits now could be read: its bits were in the sample.
  var known = true
  /// The integrated GPU's own limits now, which do not limit the CPU.
  var gpu: [String] = []

  var worst: LimitKind? { limits.map { $0.kind }.max() }

  var names: [String] { limits.map { $0.name } }

  /// What the CPU's state is called: by the worst kind of limit there is, and with none,
  /// whether the processor said so or said nothing.
  var headline: String {
    switch worst {
    case .prochot?: return "PROCHOT throttling"
    case .macOS?: return "Throttled by macOS"
    case .thermal?: return "Thermal throttling"
    case .power?: return "Power limited"
    default: return known ? "No throttling" : "Limits unknown"
    }
  }

  /// The same as a word for the recording.
  var word: String {
    switch worst {
    case .prochot?: return "prochot"
    case .macOS?: return "macOS"
    case .thermal?: return "thermal"
    case .power?: return "power"
    default: return known ? "none" : "unknown"
    }
  }

  /// Whether it calls for a warning: heat, macOS capping the CPU, or PROCHOT.
  ///
  /// Power limits are what a laptop's processor runs into under heavy load by design, so they are
  /// marked, not warned of.
  var warns: Bool { (worst ?? .normal) >= .thermal }

  /// Which band marks it behind the frequency plot: 0 none, 1 power, 2 a warning.
  var band: Int { warns ? 2 : worst == .power ? 1 : 0 }

  /// What each limit means, a line each, for the tooltip on the list of them.
  var explanation: String { limits.map { "\($0.name): \($0.meaning)" }.joined(separator: "\n") }

  /// The limits as one line: "Thermal throttling: THERMAL, PROCHOT", or "No throttling" with
  /// any limits that are part of normal turbo after it in brackets.
  var summary: String {
    guard !names.isEmpty else { return headline }
    let list = names.joined(separator: ", ")
    return (worst ?? .normal) >= .power ? headline + ": " + list : headline + " (limits: \(list))"
  }
}

extension CPULimits {
  /// Everything a sample and macOS say is limiting the CPU now.
  ///
  /// The processor's reasons are the low half of its limit bits, read by its generation's layout.
  /// Without the bits, or with a value that is no reading, its names cannot be told apart into now
  /// and before, so they are listed but none is taken for throttling, the processor's limits are
  /// unknown, and only macOS's can warn. The integrated GPU's reasons are kept apart from the
  /// cores'.
  ///
  /// - Parameters:
  ///   - sample: The sample, with the processor's limit reasons.
  ///   - power: macOS's limits on the CPU, if they could be read.
  ///   - cpus: How many CPUs the Mac has, which macOS may leave fewer of available.
  ///   - layout: How the processor lays out its limit bits.
  init(
    sample: Sample,
    power: CPUPowerStatus?,
    cpus: Int = ThisMac.cpuCount,
    layout: LimitBits.Layout = LimitBits.current
  ) {
    let cores = sample.cpuClipping.flatMap(LimitBits.reading)
    let graphics = sample.gpuClipping.flatMap(LimitBits.reading)
    self.init(known: sample.reportsLimits && cores != nil)
    if let status = power {
      if let speed = status.speedLimit, speed < CPUPowerStatus.unlimited {
        let ceiling =
          status.ceilingMHz.map { String(format: " (%.1f GHz)", $0 / Units.mhzPerGHz) } ?? ""
        limits.append(Limit(name: "macOS speed limit \(speed)%" + ceiling, kind: .macOS))
      }
      if let scheduler = status.schedulerLimit, scheduler < CPUPowerStatus.unlimited {
        limits.append(Limit(name: "macOS scheduler limit \(scheduler)%", kind: .macOS))
      }
      if let available = status.availableCPUs, available > 0, available < cpus {
        limits.append(Limit(name: "macOS allows \(available) of \(cpus) CPUs", kind: .macOS))
      }
      if status.lowPowerMode { limits.append(Limit(name: "Low Power Mode", kind: .power)) }
    }
    if let bits = cores {
      limits += LimitBits.now(bits, LimitBits.cpu(layout)).map {
        Limit(name: $0, kind: LimitKind.of($0))
      }
    } else {
      for reason in sample.limits where !reason.hasPrefix(CPULimits.gpuReasonPrefix) {
        let name =
          reason.hasPrefix(CPULimits.cpuReasonPrefix)
          ? String(reason.dropFirst(CPULimits.cpuReasonPrefix.count))
          : reason.replacingOccurrences(of: " LIMIT ", with: " ")
        limits.append(Limit(name: name, kind: .normal))
      }
    }
    if let bits = graphics {
      gpu = LimitBits.now(bits, LimitBits.gpu(layout))
    } else {
      gpu = sample.limits.filter { $0.hasPrefix(CPULimits.gpuReasonPrefix) }.map {
        String($0.dropFirst(CPULimits.gpuReasonPrefix.count))
      }
    }
  }

  // How powermetrics starts the names of the cores' limit reasons and the integrated GPU's.
  private static let cpuReasonPrefix = "CPU LIMIT "
  private static let gpuReasonPrefix = "GPU LIMIT "
}
