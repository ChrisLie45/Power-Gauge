// Test modes that read this Mac's hardware: SMC keys and the GPUs, and a load to keep a GPU
// busy for the throttle survey.

import Cocoa
import Metal

extension TestModes {
  /// What an SMC key reads, or why it has nothing, as "TG0D 61.25" or "PG0R: no such key".
  static func describeSMC(_ key: String) -> String {
    switch SMC.shared.read(key) {
    case .success(let value): return String(format: "%@ %.2f", key, value)
    case .failure(let problem): return "\(key): \(problem)"
    }
  }

  /// Lists the GPUs found, then this Mac's CPU limits, then three readings of each GPU a second
  /// apart.
  ///
  /// Utilisation from the busy-time counters is followed by the driver's own figure for comparison,
  /// both from the same read of the driver's statistics.
  /// A GPU that takes readings from the SMC also gets a line with what its keys read, before any
  /// range check, and which readings came from them rather than from the driver. Needs no
  /// privileges.
  static func gpuCheckMode() -> Never {
    let gpus = GPU.findAll()
    print("Mac:", ThisMac.model ?? "unknown model")
    let status = CPUPowerStatus.read()
    func show(_ value: Int?) -> String { value.map(String.init) ?? "none recorded" }
    print(
      "CPU limits: speed \(show(status.speedLimit)) %, scheduler "
        + "\(show(status.schedulerLimit)) %, CPUs \(show(status.availableCPUs)) of "
        + "\(ThisMac.cpuCount); Low Power Mode \(status.lowPowerMode ? "on" : "off"); ceiling "
        + "\(status.ceilingMHz.map { String(format: "%.1f GHz", $0 / 1000) } ?? "unknown")"
    )
    print(
      "busy-time counters:",
      GPUBusyCounters.shared == nil
        ? "unavailable"
        : gpus.map { "\($0.short) \($0.hasBusyCounters ? "yes" : "no")" }.joined(separator: ", ")
    )
    for gpu in gpus {
      print(
        "\(gpu.short): \(gpu.name)"
          + (gpu.smcKeys.map {
            "  (temperature and power from SMC keys \($0.temperature) and \($0.power) where "
              + "the driver has none)"
          } ?? "")
      )
    }
    // The counters' first sample, which the first reading is measured from.
    _ = GPUBusyCounters.shared?.sample()
    for _ in 0..<3 {
      sleep(1)
      let busy = GPUBusyCounters.shared?.sample() ?? [:]
      for gpu in gpus {
        func show(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "n/a" }
        // Read once: a driver works its utilisation out since its statistics were last read, so a
        // second read straight after would give about 0 %.
        let stats = gpu.statistics()
        let reading =
          stats.map { gpu.reading(from: $0, busy: busy, utilization: .busyTime) }
          ?? GPUReading(poweredDown: true)
        let driver = stats.flatMap {
          gpu.reading(from: $0, busy: busy, utilization: .driver).utilization
        }
        let memory = reading.memoryGB.map { String(format: "%.2f", $0) } ?? "n/a"
        let total =
          gpu.memoryGB.map { String(format: " of %.1f GB", $0) }
          ?? (gpu.integrated ? " of the Mac's memory" : "")
        print(
          "  \(gpu.short): \(reading.poweredDown ? "powered down  " : "")utilization "
            + "\(show(reading.utilization)) % (driver's \(show(driver)) %)  power "
            + "\(show(reading.watts)) W  temperature \(show(reading.tempC)) C  core "
            + "\(show(reading.coreMHz)) MHz  memory clock \(show(reading.memoryMHz)) MHz  memory "
            + "held \(memory) GB\(total)"
        )
        if let keys = gpu.smcKeys {
          let taken =
            reading.fromSMC.isEmpty ? "nothing" : reading.fromSMC.joined(separator: " and ")
          print(
            "    SMC: \(describeSMC(keys.temperature)), \(describeSMC(keys.power));  taken "
              + "from it: \(taken)"
          )
        }
      }
    }
    exit(0)
  }

  /// Keeps a GPU busy for the seconds given, all the time, for the throttle survey: the integrated
  /// one with "integrated" after the seconds, otherwise another.
  ///
  /// Each pass of the work takes a few milliseconds, and two are kept queued so that the GPU never
  /// waits.
  static func gpuLoadMode(seconds: Double, integrated: Bool) -> Never {
    guard let device = MTLCopyAllDevices().first(where: { $0.isLowPower == integrated }) else {
      print("no \(integrated ? "integrated" : "discrete") GPU")
      exit(1)
    }
    // Each pass runs this many threads, in groups of this size, each doing that many sums.
    let threads = 1 << 20
    let threadsPerGroup = 256
    let sumsPerThread = 4000
    let inFlight = 2  // passes queued at once
    let source = """
      #include <metal_stdlib>
      using namespace metal;
      kernel void spin(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
          float a = float(id) * 1e-6;
          for (uint i = 0; i < \(sumsPerThread); i++) { a = fma(a, 1.0001, 1e-7); }
          out[id] = a;
      }
      """
    guard let library = try? device.makeLibrary(source: source, options: nil),
      let function = library.makeFunction(name: "spin"),
      let pipeline = try? device.makeComputePipelineState(function: function),
      let queue = device.makeCommandQueue(),
      let out = device.makeBuffer(
        length: threads * MemoryLayout<Float>.size,
        options: .storageModePrivate
      )
    else {
      print("could not set up the work on \(device.name)")
      exit(1)
    }
    print("loading \(device.name) for \(Int(seconds)) s")
    let end = Date().addingTimeInterval(seconds)
    var queued: [MTLCommandBuffer] = []
    while Date() < end {
      guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder()
      else { break }
      encoder.setComputePipelineState(pipeline)
      encoder.setBuffer(out, offset: 0, index: 0)
      encoder.dispatchThreads(
        MTLSize(width: threads, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
      )
      encoder.endEncoding()
      buffer.commit()
      queued.append(buffer)
      if queued.count > inFlight { queued.removeFirst().waitUntilCompleted() }
    }
    queued.forEach { $0.waitUntilCompleted() }
    exit(0)
  }
}
