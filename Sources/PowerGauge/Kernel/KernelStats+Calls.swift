// EXPERIMENTAL (see KernelStats): making the kernel's diagnostic call (Sources/CDiag), and
// opening it for reading, which is tried in a child process first, since a kernel without the
// call ends the process that makes it.

import Foundation

#if canImport(CDiag)
  import CDiag
#endif

extension KernelStats {
  /// Where each figure is in the call's buffer: xnu's `pkg_energy_statistics_t`, then a
  /// `core_energy_stat_t` for each CPU.
  private enum Offset {
    static let version = 0
    static let energyUnit = 120
    static let packageEnergy = 128
    static let coresEnergy = 136
    static let graphicsEnergy = 144
    static let memoryEnergy = 152
    static let cpuLimits = 176
    static let gpuLimits = 184
    static let cpuCount = 408
    // Within a CPU's record.
    static let aperf = 0
    static let mperf = 8
    static let runTime = 256
    static let idleTime = 264
  }

  // What the call returns for a selector it handled, and the version of the structure it fills.
  private static let callHandled = 1
  private static let structureVersion: UInt64 = 1

  /// Makes the calls, into a buffer for one record size.
  final class Reader {
    let recordSize: Int
    private let size: Int
    private let buffer: UnsafeMutableRawPointer

    init(recordSize: Int) {
      self.recordSize = recordSize
      // The kernel writes a record for every CPU without being told how big the buffer is,
      // so it has room for all the CPUs the Mac can have at the larger size, and more.
      let cpus = max(Sysctl.int("hw.logicalcpu_max") ?? ThisMac.cpuCount, Reader.leastCPUs)
      size = KernelStats.headerSize + cpus * KernelStats.allPMCsRecordSize + Reader.spareBytes
      buffer = .allocate(byteCount: size, alignment: 16)
    }

    deinit { buffer.deallocate() }

    private static let leastCPUs = 64
    private static let spareBytes = 4096
    /// Time for every CPU to store its counters, between the two calls of a reading.
    static let storeDelay: useconds_t = 2000

    /// One call: nil if the kernel turned it down or gave something other than version 1.
    func call() -> Reading? {
      memset(buffer, 0, size)
      guard powergauge_diag(KernelStats.powerStatSelector, buffer) == KernelStats.callHandled else {
        return nil
      }
      func field(_ offset: Int) -> UInt64 { buffer.load(fromByteOffset: offset, as: UInt64.self) }
      let count = Int(buffer.load(fromByteOffset: Offset.cpuCount, as: UInt32.self))
      guard field(Offset.version) == KernelStats.structureVersion, count > 0,
        KernelStats.headerSize + count * recordSize <= size
      else { return nil }
      let cpus = (0..<count).map { cpu -> CPU in
        let record = KernelStats.headerSize + cpu * recordSize
        return CPU(
          aperf: field(record + Offset.aperf),
          mperf: field(record + Offset.mperf),
          run: field(record + Offset.runTime),
          idle: field(record + Offset.idleTime)
        )
      }
      return Reading(
        nanoseconds: KernelStats.nanoseconds(),
        unit: field(Offset.energyUnit),
        package: field(Offset.packageEnergy),
        cores: field(Offset.coresEnergy),
        graphics: field(Offset.graphicsEnergy),
        memory: field(Offset.memoryEnergy),
        cpuLimits: field(Offset.cpuLimits),
        gpuLimits: field(Offset.gpuLimits),
        cpus: cpus
      )
    }

    /// A reading: a call that has every CPU store its counters afresh, then, 2 ms later, the
    /// call that reads them.
    func read() -> Reading? {
      _ = call()
      usleep(Reader.storeDelay)
      return call()
    }
  }

  /// The test call, made by the app in a child process of itself (`--kernel-probe`): its exit
  /// status is 0 if the call worked.
  ///
  /// On a kernel without the call the child is killed instead.
  static func probeHere() -> Int32 { Reader(recordSize: plainRecordSize).call() != nil ? 0 : 1 }

  private static let probeTimeout: TimeInterval = 5
  private static let probePoll: useconds_t = 10_000
  /// A tenth of a second, between the two readings that tell which record size is the kernel's.
  private static let layoutTestGap: useconds_t = 100_000

  /// Opens the kernel's statistics for reading, which takes a few tenths of a second, or says why
  /// they can't be read here.
  ///
  /// What it gives is one call (`Reader.call`), which returns what the previous call had the
  /// CPUs store: `KernelSampler` calls it every 10 ms, so its readings lag by that much.
  ///
  /// The call is first made in a child process, since a kernel without it would end the process
  /// that made it; then the record size is found, as the one under which every CPU's counters move
  /// as they must over a tenth of a second.
  static func open() -> Result<() -> Reading?, Unavailable> {
    func unavailable(_ reason: String) -> Result<() -> Reading?, Unavailable> {
      .failure(Unavailable(reason: reason))
    }
    #if !arch(x86_64)
      return unavailable("this Mac's processor isn't an Intel one")
    #else
      if Sysctl.int("sysctl.proc_translated") == 1 {
        return unavailable(
          "Power Gauge is running under Rosetta, which can't make the kernel's call"
        )
      }
      if baseMHz == nil {
        return unavailable(
          "macOS doesn't give the processor's base clock, which its frequencies are worked out from"
        )
      }
      let child = Process()
      child.executableURL =
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
      child.arguments = ["--kernel-probe"]
      child.standardOutput = FileHandle.nullDevice
      child.standardError = FileHandle.nullDevice
      guard (try? child.run()) != nil else {
        return unavailable("the test call couldn't be started")
      }
      let deadline = Date().addingTimeInterval(KernelStats.probeTimeout)
      while child.isRunning, Date() < deadline { usleep(KernelStats.probePoll) }
      if child.isRunning {
        child.terminate()
        return unavailable("the test call didn't finish")
      }
      if child.terminationReason == .uncaughtSignal {
        return unavailable(
          "the kernel has no power-statistics call (the test call ended with signal "
            + "\(child.terminationStatus))"
        )
      }
      guard child.terminationStatus == 0 else {
        return unavailable("the kernel's power-statistics call gave nothing usable")
      }
      for size in recordSizes {
        let reader = Reader(recordSize: size)
        guard let first = reader.read() else { continue }
        usleep(KernelStats.layoutTestGap)
        guard let second = reader.read(), case .success = sample(from: first, to: second) else {
          continue
        }
        return .success(reader.call)
      }
      return unavailable(
        "the kernel's per-CPU figures don't hold together in either layout Power Gauge knows"
      )
    #endif
  }
}
