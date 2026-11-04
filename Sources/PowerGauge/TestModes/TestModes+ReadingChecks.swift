// Test modes for reading powermetrics and what the app makes of it: parsing, recording, and
// replaying the throttle surveys.

import Cocoa

extension TestModes {
  /// Parses a file holding one or more powermetrics plist documents and prints what was found.
  ///
  /// The file is fed to the stream in pieces of 997 bytes, so that documents are split across reads
  /// as they are when read from powermetrics. Its limit bits are read with the layout given after
  /// `--layout`, haswell or skylake (the default), so that the output is the same on any Mac.
  static func parseMode(_ path: String) -> Never {
    let layout: LimitBits.Layout =
      CommandLine.value(after: "--layout") == "haswell" ? .haswell : .skylake
    var stream = PlistStream()
    let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    let piece = 997
    let documents = stride(from: 0, to: data.count, by: piece).flatMap {
      stream.append(data.subdata(in: $0..<min($0 + piece, data.count)))
    }
    print("documents:", documents.count)
    for document in documents {
      guard let sample = Powermetrics.parse(document) else {
        print("unparseable document")
        continue
      }
      print("system MHz:", sample.systemMHz.map { String($0) } ?? "not found")
      print("per-CPU MHz (\(sample.coreMHz.count)):", sample.coreMHz)
      print(
        "watts package/cpu/gpu/dram:",
        sample.packageWatts as Any,
        sample.cpuWatts as Any,
        sample.gpuWatts as Any,
        sample.dramWatts as Any
      )
      print("integrated GPU MHz:", sample.gpuMHz as Any)
      print(
        "temp C / fan rpm / prochots:",
        sample.cpuTempC as Any,
        sample.fanRPM as Any,
        sample.prochots as Any
      )
      print(
        "limits:",
        sample.reportsLimits
          ? (sample.limits.isEmpty ? "none named" : "\(sample.limits)") : "no package record",
        "bits:",
        sample.cpuClipping.map { String(format: "0x%08X", $0) } ?? "none",
        sample.gpuClipping.map { String(format: "0x%08X", $0) } ?? "none"
      )
      let limits = CPULimits(sample: sample, power: nil, layout: layout)
      print(
        "read as:",
        limits.summary
          + (limits.gpu.isEmpty ? "" : "; integrated GPU: " + limits.gpu.joined(separator: ", "))
      )
    }
    exit(0)
  }

  /// Records the samples in a file of powermetrics plist documents to a CSV file as the app would,
  /// with the made-up GPUs' readings beside them, and prints the file.
  ///
  /// The times are made up too, a second apart in UTC, so that the output is the same on any Mac at
  /// any time.
  static func csvCheckMode(_ path: String) -> Never {
    var stream = PlistStream()
    let samples = stream.append((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
      .compactMap { Powermetrics.parse($0) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent(
      "powergauge-csv-check-\(getpid()).csv"
    )
    defer { try? FileManager.default.removeItem(at: out) }
    do {
      let recorder = try Recorder(
        url: out,
        gpus: MadeUp.gpus(),
        cpus: 16,
        timeZone: TimeZone(identifier: "UTC")!,
        started: start
      )
      for (index, parsed) in samples.enumerated() {
        var sample = parsed
        sample.memory = (18.25, 2.5, index == 0 ? nil : 0.75)
        sample.coreTempsC = [61, 63, 72, 66]
        let power = CPUPowerStatus(
          speedLimit: CPUPowerStatus.unlimited,
          schedulerLimit: CPUPowerStatus.unlimited,
          availableCPUs: 16,
          ceilingMHz: 5000
        )
        let cpu = Recorder.CPUReadings(
          sample: sample,
          utilization: index == 0 ? nil : 42.5,
          power: power,
          limits: CPULimits(sample: sample, power: power, cpus: 16, layout: .skylake)
        )
        let gpu = [
          GPUReading(utilization: 12.5, memoryGB: 0.25),
          GPUReading(
            utilization: 40,
            watts: 21.5,
            tempC: 68,
            coreMHz: 1423,
            memoryMHz: 1472,
            memoryGB: 5.5
          ),
        ]
        recorder.write(cpu: cpu, gpu: gpu, at: start.addingTimeInterval(Double(index) + 1))
      }
      // A row whose limit registers couldn't be read, which powermetrics gives as -1.
      if var sample = samples.first {
        (sample.cpuClipping, sample.gpuClipping) = (LimitBits.unreadable, LimitBits.unreadable)
        let cpu = Recorder.CPUReadings(
          sample: sample,
          utilization: 42.5,
          power: nil,
          limits: CPULimits(sample: sample, power: nil, cpus: 16, layout: .skylake)
        )
        recorder.write(cpu: cpu, gpu: nil, at: start.addingTimeInterval(Double(samples.count) + 1))
      }
      // A row with the GPUs alone, the second powered down, as while monitoring is not running.
      recorder.write(
        cpu: nil,
        gpu: [GPUReading(utilization: 3), GPUReading(poweredDown: true)],
        at: start.addingTimeInterval(Double(samples.count) + 2)
      )
      if let failure = recorder.closeAndWait() { throw failure }
      print(try String(contentsOf: out, encoding: .utf8), terminator: "")
    } catch {
      print("error:", error)
      exit(1)
    }
    exit(0)
  }

  /// Replays a throttle survey (`scripts/throttle-survey.sh`) through the app's own reading of
  /// limits: each powermetrics sample with what macOS said in the same second (`system.tsv`), and
  /// prints, for each scenario, how many samples were read as each state, and which limits and
  /// integrated GPU limits came up.
  ///
  /// It is what the app would have said, second by second.
  static func surveyCheckMode(_ folder: String) -> Never {
    func table(_ name: String) -> [[String: String]] {
      let lines = ((try? String(contentsOfFile: folder + "/" + name, encoding: .utf8)) ?? "").split(
        separator: "\n"
      ).map { $0.components(separatedBy: "\t") }
      guard let header = lines.first else { return [] }
      return lines.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
    }
    let scenarios = table("scenarios.tsv")
    let about = (try? String(contentsOfFile: folder + "/about.txt", encoding: .utf8)) ?? ""
    let family = about.split(separator: "\n").first { $0.hasPrefix("CPU family: ") }.flatMap {
      Int($0.dropFirst("CPU family: ".count))
    }
    let layout = family.map { LimitBits.layout(cpuFamily: $0) } ?? LimitBits.current
    var system: [Int: [String: String]] = [:]
    for row in table("system.tsv") {
      if let second = row["time"].flatMap({ Int($0) }) { system[second] = row }
    }
    var stream = PlistStream()
    let documents = stream.append(
      (try? Data(contentsOf: URL(fileURLWithPath: folder + "/powermetrics.plist"))) ?? Data()
    )
    var states: [String: [String: Int]] = [:]
    var limits: [String: [String: Int]] = [:]
    var counts: [String: Int] = [:]
    for document in documents {
      guard let sample = Powermetrics.parse(document),
        let root = try? PropertyListSerialization.propertyList(
          from: document,
          options: [],
          format: nil
        ) as? [String: Any],
        let stamp = root["timestamp"] as? Date
      else { continue }
      // A sample's time stamp is the end of its second.
      let second = Int(stamp.timeIntervalSince1970) - 1
      guard
        let scenario = scenarios.first(where: {
          (Int($0["start"] ?? "") ?? .max) <= second && second < (Int($0["end"] ?? "") ?? .min)
        })?["scenario"]
      else { continue }
      // macOS's limits from the nearest second logged, within 3 s: the log may skip seconds on a
      // slow Mac. Seconds from the sample's, in the order to look.
      let nearestFirst = [0, 1, -1, 2, -2, 3, -3]
      let row = nearestFirst.lazy.compactMap { system[second + 1 + $0] }.first
      func int(_ key: String) -> Int? { row?[key].flatMap { Int($0) } }
      let power = row.map { _ in
        CPUPowerStatus(
          speedLimit: int("speed_limit"),
          schedulerLimit: int("scheduler_limit"),
          availableCPUs: int("available_cpus"),
          lowPowerMode: int("low_power_mode") == 1,
          ceilingMHz: int("hard_plimit_max_100mhz_ratio").map {
            Double($0) * CPUPowerStatus.ceilingStepMHz
          }
        )
      }
      // The surveyed Mac's own CPU count, which is every CPU in its samples, and its own layout of
      // limit bits, by the CPU family in about.txt.
      let read = CPULimits(
        sample: sample,
        power: power,
        cpus: sample.coreMHz.isEmpty ? ThisMac.cpuCount : sample.coreMHz.count,
        layout: layout
      )
      counts[scenario, default: 0] += 1
      states[scenario, default: [:]][read.headline, default: 0] += 1
      for name in read.names {
        limits[scenario, default: [:]][
          name.hasPrefix("macOS speed limit") ? "macOS speed limit" : name,
          default: 0
        ] += 1
      }
      for name in read.gpu {
        limits[scenario, default: [:]]["integrated GPU " + name, default: 0] += 1
      }
    }
    func list(_ tally: [String: Int]?) -> String {
      (tally ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map {
        "\($0.key) \($0.value)"
      }.joined(separator: ", ")
    }
    for scenario in scenarios.compactMap({ $0["scenario"] }) {
      print("\(scenario) (\(counts[scenario] ?? 0) samples): \(list(states[scenario]))")
      let named = list(limits[scenario])
      print("    limits: \(named.isEmpty ? "none" : named)")
    }
    exit(0)
  }
}
