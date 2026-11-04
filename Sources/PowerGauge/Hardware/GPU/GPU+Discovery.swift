// Finding the GPUs: each one with a driver loaded, named by its make.

import Cocoa
import IOKit

extension GPU {
  /// SMC keys that stand in for what a GPU's driver leaves out, for the one NVIDIA GPU of each Mac
  /// model listed.
  ///
  /// Only models whose keys have been checked are listed: on other models the same names can belong
  /// to other sensors, or not exist.
  ///
  /// - `MacBookPro11,3`, GeForce GT 750M: `TG0D` is the GPU's die diode and `PG0R` the power it
  ///   draws, both two-byte fixed point on that model.
  static let nvidiaSMCKeys: [String: (temperature: String, power: String)] = [
    "MacBookPro11,3": (temperature: "TG0D", power: "PG0R")
  ]

  /// The GPUs with a driver loaded, integrated first.
  ///
  /// Each make has a colour of its own.
  static func findAll() -> [GPU] {
    var iterator: io_iterator_t = 0
    // IOKit's default main port, whose named constant needs macOS 12.
    let defaultMainPort: mach_port_t = 0
    guard
      IOServiceGetMatchingServices(defaultMainPort, IOServiceMatching("IOAccelerator"), &iterator)
        == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var integrated: [GPU] = []
    var others: [GPU] = []
    var seen: Set<UInt64> = []
    while true {
      let service = IOIteratorNext(iterator)  // kept for the life of the app, to read from
      guard service != 0 else { break }
      var id: UInt64 = 0
      IORegistryEntryGetRegistryEntryID(service, &id)
      guard seen.insert(id).inserted else {
        IOObjectRelease(service)
        continue
      }
      let driver = (IOObjectCopyClass(service)?.takeRetainedValue() as String?) ?? ""
      // The model name is a property of the PCI device the driver is attached to.
      let model = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        "model" as CFString,
        kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
      )
      let name =
        (model as? Data).map {
          String(decoding: $0, as: UTF8.self).trimmingCharacters(
            in: CharacterSet(charactersIn: "\0")
          )
        }
        ?? (model as? String) ?? driver
      let names = (driver + " " + name).lowercased()
      // Its own video memory, in MB, which the PCI device gives as a number or as bytes.
      // The integrated GPU's figure there is only a nominal share of the Mac's memory.
      let vram = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        "VRAM,totalMB" as CFString,
        kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
      )
      let numberSize = MemoryLayout<UInt32>.size  // as bytes, a little-endian UInt32
      let vramMB =
        (vram as? NSNumber)?.doubleValue
        ?? (vram as? Data).flatMap {
          $0.count >= numberSize
            ? Double($0.prefix(numberSize).reversed().reduce(0) { $0 << 8 | UInt32($1) }) : nil
        }
      let memoryGB = vramMB.flatMap { $0 > 0 ? $0 / Units.mbPerGB : nil }
      if names.contains("intel") {
        integrated.append(
          GPU(name: name, short: "Intel", color: .systemBlue, integrated: true, service: service)
        )
      } else if names.contains("amd") || names.contains("radeon") {
        others.append(
          GPU(name: name, short: "AMD", color: .systemRed, service: service, memoryGB: memoryGB)
        )
      } else if names.contains("nvidia") || names.contains("geforce")
        || driver.lowercased().hasPrefix("nv")
      {
        others.append(
          GPU(
            name: name,
            short: "NVIDIA",
            color: .systemGreen,
            service: service,
            smcKeys: ThisMac.model.flatMap { nvidiaSMCKeys[$0] },
            memoryGB: memoryGB
          )
        )
      } else {
        others.append(
          GPU(name: name, short: "GPU", color: .systemOrange, service: service, memoryGB: memoryGB)
        )
      }
    }
    return numbered(integrated + others)
  }

  /// Tells two GPUs of one make apart by number: "AMD", then "AMD 2".
  ///
  /// The SMC keys are for a model's only NVIDIA GPU, so a second one has none.
  static func numbered(_ gpus: [GPU]) -> [GPU] {
    var count: [String: Int] = [:]
    return gpus.map { gpu in
      count[gpu.short, default: 0] += 1
      let nth = count[gpu.short]!
      return nth == 1
        ? gpu
        : GPU(
          name: gpu.name,
          short: "\(gpu.short) \(nth)",
          color: gpu.color,
          integrated: gpu.integrated,
          service: gpu.service,
          nth: nth,
          memoryGB: gpu.memoryGB
        )
    }
  }
}
