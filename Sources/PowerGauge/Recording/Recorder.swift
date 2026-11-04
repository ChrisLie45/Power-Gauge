import Foundation

/// Writes the readings to a CSV file that a spreadsheet can open: a header row, then one row for
/// each CPU sample, from the kernel or powermetrics, while monitoring runs, or for each GPU reading
/// while it does not.
///
/// A reading with no value leaves its cell empty. Numbers have a full stop for their decimal point
/// whatever the language, and times are ISO 8601 with their offset from UTC. The file is plain
/// ASCII, so that a spreadsheet reads it right whatever encoding it guesses: Excel takes a file
/// with no byte-order mark for its legacy encoding, where "°C" is "Â°C".
///
/// Each row is forced onto the disk itself (`F_FULLFSYNC`) before the next, so that a recording
/// keeps everything up to the moment of a kernel panic or a power cut: written and left to
/// macOS, a row can wait some seconds in its cache, and those are the seconds a recording is
/// often for. That takes milliseconds, or seconds on a network share or an external disk that
/// has gone to sleep, so rows are written on a queue of their own and the window never waits.
/// Rows written to standard output (`--print-csv`) go straight to whatever reads it instead.
final class Recorder {
  let url: URL
  // What is written to, and how, belongs to the queue once the header is written.
  private let queue = DispatchQueue(label: "PowerGauge.Recorder")
  private let handle: FileHandle
  /// Whether each row is forced onto the disk, which a pipe or terminal has no use for.
  private let syncs: Bool
  private let gpuCount: Int
  private let cpus: Int
  private let started: Date
  private let time = ISO8601DateFormatter()
  /// The first write that failed, after which nothing more is written.
  private var failure: Error?
  /// Called on the main thread when a write fails.
  ///
  /// Recording is over by then: the rows already written are kept, and no more are written.
  var onError: ((Error) -> Void)?

  /// The columns for a CPU sample, and for each GPU's reading, in the order `row(cpu:gpu:at:)`
  /// fills them.
  private static let cpuColumns = [
    "Package (W)",
    "IA cores (W)",
    "GT (W)",
    "DRAM (W)",
    "Core max (GHz)",
    "Core avg (GHz)",
    "Core min (GHz)",
    "CPU die (C)",
    "Core temp max (C)",
    "Core temp avg (C)",
    "Core temp min (C)",
    "Fan (rpm)",
    "Prochots",
    "Speed limit (%)",
    "Scheduler limit (%)",
    "CPUs available",
    "Low Power Mode",
    "Frequency ceiling (GHz)",
    "CPU utilization (%)",
    "Memory used (GB)",
    "Memory compressed (GB)",
    "Swap (GB)",
    "Throttling",
    "Limits",
    "Integrated GPU limits",
    "CPU limit bits",
    "GPU limit bits",
    "CPU readings from",
  ]

  private static let gpuColumns = [
    "utilization (%)",
    "power (W)",
    "temperature (C)",
    "core clock (MHz)",
    "memory clock (MHz)",
    "memory (GB)",
    "powered down",
  ]

  /// A CPU sample with what goes with it.
  struct CPUReadings {
    let sample: Sample
    let utilization: Double?
    let power: CPUPowerStatus?
    let limits: CPULimits
  }

  /// Creates the file, replacing one already there, and writes the header row.
  ///
  /// - Parameters:
  ///   - url: Where the file goes.
  ///   - gpus: The GPUs to have columns for.
  ///   - cpus: How many per-CPU frequency columns to have, which are last.
  ///   - timeZone: The time zone the rows' times are written in.
  ///   - started: When recording started, which each row's elapsed seconds count from.
  /// - Throws: The error from creating or writing the file.
  convenience init(
    url: URL,
    gpus: [GPU],
    cpus: Int = ThisMac.cpuCount,
    timeZone: TimeZone = .current,
    started: Date = Date()
  ) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    try self.init(
      url: url,
      handle: FileHandle(forWritingTo: url),
      syncs: true,
      gpus: gpus,
      cpus: cpus,
      timeZone: timeZone,
      started: started
    )
  }

  /// Writes the header row to standard output, where the rows will follow.
  ///
  /// - Parameter gpus: The GPUs to have columns for.
  /// - Throws: The error from writing the header.
  convenience init(standardOutputFor gpus: [GPU]) throws {
    try self.init(
      url: URL(fileURLWithPath: "/dev/stdout"),
      handle: .standardOutput,
      syncs: false,
      gpus: gpus,
      cpus: ThisMac.cpuCount,
      timeZone: .current,
      started: Date()
    )
  }

  private init(
    url: URL,
    handle: FileHandle,
    syncs: Bool,
    gpus: [GPU],
    cpus: Int,
    timeZone: TimeZone,
    started: Date
  ) throws {
    self.url = url
    self.handle = handle
    self.syncs = syncs
    self.gpuCount = gpus.count
    self.cpus = cpus
    self.started = started
    time.timeZone = timeZone
    var columns = ["Time", "Elapsed (s)"] + Recorder.cpuColumns
    for gpu in gpus { columns += Recorder.gpuColumns.map { "\(gpu.short) \($0)" } }
    columns += (0..<cpus).map { "CPU \($0) (MHz)" }
    try append(columns)
  }

  /// Adds a row, in the background: the CPU's readings, if there is a sample, and each GPU's, if
  /// they are fresh.
  ///
  /// - Parameters:
  ///   - cpu: The CPU's readings, or nil without a sample.
  ///   - gpu: Each GPU's readings, or nil if they are not fresh.
  ///   - date: When they were read.
  func write(cpu: CPUReadings?, gpu: [GPUReading]?, at date: Date = Date()) {
    queue.async { [self] in
      guard failure == nil else { return }
      do {
        try append(row(cpu: cpu, gpu: gpu, at: date))
      } catch {
        failure = error
        DispatchQueue.main.async { self.onError?(error) }
      }
    }
  }

  /// Closes the file once the rows already given are written, without waiting for that.
  func close() {
    queue.async { [self] in try? handle.close() }
  }

  /// Waits for the rows already given to be written, then closes the file, as when the app quits.
  ///
  /// Returns the first write that failed, if one did.
  @discardableResult
  func closeAndWait() -> Error? {
    queue.sync {
      try? handle.close()
      return failure
    }
  }

  private func row(cpu: CPUReadings?, gpu: [GPUReading]?, at date: Date) -> [String] {
    func number(_ value: Double?, places: Int) -> String {
      value.map { String(format: "%.\(places)f", $0) } ?? ""
    }
    func whole(_ value: Int?) -> String { value.map(String.init) ?? "" }
    func flag(_ on: Bool) -> String { on ? "1" : "0" }
    func ghz(_ mhz: Double?) -> Double? { mhz.map { $0 / Units.mhzPerGHz } }
    var cells = [time.string(from: date), number(date.timeIntervalSince(started), places: 1)]
    if let cpu = cpu {
      let sample = cpu.sample
      let cores = sample.coreTempsC
      cells += [
        number(sample.packageWatts, places: 2),
        number(sample.cpuWatts, places: 2),
        number(sample.gpuWatts, places: 2),
        number(sample.dramWatts, places: 2),
        number(ghz(sample.peakMHz), places: 3),
        number(ghz(sample.systemMHz), places: 3),
        number(ghz(sample.lowMHz), places: 3),
        number(sample.cpuTempC, places: 1),
        number(cores.max(), places: 1),
        number(cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count), places: 1),
        number(cores.min(), places: 1),
        number(sample.fanRPM, places: 0),
        whole(sample.prochots),
        whole(cpu.power?.speedLimit),
        whole(cpu.power?.schedulerLimit),
        whole(cpu.power?.availableCPUs),
        cpu.power.map { flag($0.lowPowerMode) } ?? "",
        number(ghz(cpu.power?.ceilingMHz), places: 1),
        number(cpu.utilization, places: 1),
        number(sample.memory?.used, places: 3),
        number(sample.memory?.compressed, places: 3),
        number(sample.memory?.swap ?? nil, places: 3),
        cpu.limits.word,
        cpu.limits.names.joined(separator: "; "),
        cpu.limits.gpu.joined(separator: "; "),
        Recorder.bits(sample.cpuClipping),
        Recorder.bits(sample.gpuClipping),
        sample.source.rawValue,
      ]
    } else {
      cells += Array(repeating: "", count: Recorder.cpuColumns.count)
    }
    for index in 0..<gpuCount {
      guard let reading = gpu.flatMap({ index < $0.count ? $0[index] : nil }) else {
        cells += Array(repeating: "", count: Recorder.gpuColumns.count)
        continue
      }
      cells += [
        number(reading.utilization, places: 1),
        number(reading.watts, places: 2),
        number(reading.tempC, places: 1),
        number(reading.coreMHz, places: 0),
        number(reading.memoryMHz, places: 0),
        number(reading.memoryGB, places: 3),
        flag(reading.poweredDown),
      ]
    }
    let perCPU = cpu?.sample.coreMHz ?? []
    cells += (0..<cpus).map { $0 < perCPU.count ? number(perCPU[$0], places: 0) : "" }
    return cells
  }

  /// A limit register as written: its 32 bits in hex; "unreadable" for one the processor
  /// doesn't have, which powermetrics gives as -1 and would otherwise read as every bit set;
  /// empty for a sample with none.
  private static func bits(_ raw: Int?) -> String {
    raw.map { LimitBits.reading($0).map { String(format: "0x%08X", $0) } ?? "unreadable" } ?? ""
  }

  /// Writes a line and, unless it goes to standard output, forces it onto the disk.
  ///
  /// A cell with a comma, quote or line break in it goes between quotes, its quotes doubled. Where
  /// the file system cannot force the disk's own cache to empty (`F_FULLFSYNC`), as on some network
  /// shares, the line is at least handed to the disk (fsync).
  private func append(_ cells: [String]) throws {
    let line =
      cells.map { cell in
        cell.contains { ",\"\n\r".contains($0) }
          ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
      }.joined(separator: ",") + "\n"
    try handle.write(contentsOf: Data(line.utf8))
    guard syncs else { return }
    let descriptor = handle.fileDescriptor
    if fcntl(descriptor, F_FULLFSYNC) == -1, fsync(descriptor) == -1 {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
