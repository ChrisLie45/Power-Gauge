// Test modes for the experimental kernel readings (see KernelStats).

import Foundation

extension TestModes {
  /// Checks each rule the kernel's readings are held to (`KernelStats.sample`), on made-up readings
  /// a second apart, and prints what each case gives: a sample, or why it can't be trusted.
  ///
  /// The base clock is fixed at 2.4 GHz so that the output is the same on any Mac.
  static func kernelWindowsMode() -> Never {
    typealias Reading = KernelStats.Reading
    let baseMHz = 2400.0
    let joule = UInt64(MadeUp.countsPerJoule)
    func reading(_ seconds: Double) -> Reading {
      MadeUp.kernelReading(
        seconds: seconds,
        nanoseconds: UInt64(seconds * Units.nanosecondsPerSecond),
        baseMHz: baseMHz
      )
    }
    let earlier = reading(10)
    let later = reading(11)
    func with(_ reading: Reading, _ change: (inout Reading) -> Void) -> Reading {
      var changed = reading
      change(&changed)
      return changed
    }
    let cases: [(String, Reading, Reading, Bool)] = [
      ("normal", earlier, later, true),
      ("a tenth of a second", earlier, reading(10.1), true),
      (
        "energy counters wrap",
        with(earlier) { $0.package = UInt64(UInt32.max) - 100_000 },
        with(later) { $0.package = 20 * joule - 100_001 },
        true
      ),
      (
        "no integrated GPU",
        with(earlier) { $0.graphics = $0.cores },
        with(later) { $0.graphics = $0.cores },
        true
      ),
      (
        "no memory counter",
        with(earlier) { $0.memory = KernelStats.absent },
        with(later) { $0.memory = KernelStats.absent },
        true
      ),
      ("Xeon", earlier, later, false),
      (
        "no limit registers",
        with(earlier) { ($0.cpuLimits, $0.gpuLimits) = (KernelStats.absent, KernelStats.absent) },
        with(later) { ($0.cpuLimits, $0.gpuLimits) = (KernelStats.absent, KernelStats.absent) },
        true
      ),
      (
        "power limited, with older limits logged",
        earlier,
        with(later) { ($0.cpuLimits, $0.gpuLimits) = (0x0003_0500, 0x0100_0100) },
        true
      ),
      (
        "counters reset by sleep",
        earlier,
        with(later) { reset in
          reset.package = 1000
          reset.cores = 800
          reset.cpus = reset.cpus.map { _ in KernelStats.CPU(aperf: 10, mperf: 10, run: 5, idle: 5)
          }
        }, true
      ),
      (
        "cores draw more than the package",
        earlier,
        with(later) { $0.cores = earlier.cores + 25 * joule },
        true
      ),
      (
        "MPERF faster than the base clock",
        earlier,
        with(later) { $0.cpus[1].mperf = earlier.cpus[1].mperf + 2_600_000_000 },
        true
      ),
      (
        "impossible frequency",
        earlier,
        with(later) { $0.cpus[2].aperf = earlier.cpus[2].aperf + 10_000_000_000 },
        true
      ),
      ("a CPU offline", earlier, with(later) { $0.cpus[3] = earlier.cpus[3] }, true),
      ("CPU count changed", earlier, with(later) { $0.cpus.removeLast() }, true),
      ("energy unit nonsense", with(earlier) { $0.unit = 0 }, with(later) { $0.unit = 0 }, true),
      (
        "run and idle times short",
        earlier,
        with(later) { short in
          for cpu in short.cpus.indices {
            (short.cpus[cpu].run, short.cpus[cpu].idle) = (
              earlier.cpus[cpu].run + 1,
              earlier.cpus[cpu].idle + UInt64(0.3e9 / KernelStats.timebase)
            )
          }
        }, true
      ),
      ("clock went backwards", later, earlier, true),
      ("an hour between readings", earlier, reading(3610), true),
    ]
    for (name, first, second, packageUnit) in cases {
      switch KernelStats.sample(
        from: first,
        to: second,
        baseMHz: baseMHz,
        memoryInPackageUnit: packageUnit
      ) {
      case .failure(let problem): print("\(name): can't be trusted: \(problem.reason)")
      case .success(let sample):
        func watts(_ value: Double?) -> String {
          value.map { String(format: "%.2f", $0) } ?? "none"
        }
        let limits = CPULimits(
          sample: sample,
          power: nil,
          cpus: sample.coreMHz.count,
          layout: .skylake
        )
        print(
          "\(name): package \(watts(sample.packageWatts)) W, cores "
            + "\(watts(sample.cpuWatts)), GPU \(watts(sample.gpuWatts)), memory "
            + "\(watts(sample.dramWatts));",
          String(
            format: "average %.0f MHz, CPUs %@;",
            sample.systemMHz ?? 0,
            sample.coreMHz.map { String(format: "%.0f", $0) }.joined(separator: " ")
          ),
          limits.summary
            + (limits.gpu.isEmpty ? "" : "; integrated GPU: " + limits.gpu.joined(separator: ", "))
        )
      }
    }

    // Each CPU's clock while active over 10 ms (`KernelStats.activeMHz`), for the bursts.
    let soon = reading(10.01)
    let hardlyRan = UInt64(KernelStats.leastActiveSeconds * baseMHz * Units.hertzPerMHz) - 1
    let bursts: [(String, Reading)] = [
      ("10 ms", soon),
      ("a burst on CPU 0", with(soon) { $0.cpus[0].aperf = earlier.cpus[0].aperf + 12_000_000 }),
      (
        "CPU 1 hardly ran",
        with(soon) {
          $0.cpus[1].mperf = earlier.cpus[1].mperf + hardlyRan
          $0.cpus[1].aperf = earlier.cpus[1].aperf + hardlyRan
        }
      ),
      ("CPU 2 stored nothing new", with(soon) { $0.cpus[2] = earlier.cpus[2] }),
      (
        "counters reset by sleep",
        with(soon) {
          $0.cpus = $0.cpus.map { _ in KernelStats.CPU(aperf: 1, mperf: 1, run: 1, idle: 1) }
        }
      ),
      ("CPU count changed", with(soon) { $0.cpus.removeLast() }),
    ]
    for (name, later) in bursts {
      let clocks = KernelStats.activeMHz(from: earlier, to: later, baseMHz: baseMHz)
      print(
        "burst, \(name): CPUs "
          + (clocks.isEmpty
            ? "none" : clocks.map { String(format: "%.0f", $0) }.joined(separator: " "))
      )
    }
    exit(0)
  }

  /// Reads this Mac's kernel statistics for a few seconds, as monitoring would, and prints "ok"
  /// with what they gave, or "FAIL" and why.
  ///
  /// Where they can't be read, as under Rosetta, or in a virtual machine, which may not pass the
  /// processor's counters through (a build server's Mac is one), that is expected and passes, with
  /// the reason.
  static func kernelCheckMode() -> Never {
    let start = Date()
    switch KernelStats.open() {
    case .failure(let problem):
      #if arch(x86_64)
        let expected =
          Sysctl.int("sysctl.proc_translated") == 1 || Sysctl.int("kern.hv_vmm_present") == 1
      #else
        let expected = true
      #endif
      print(
        expected
          ? "ok kernel (not available here: \(problem.reason))" : "FAIL kernel: \(problem.reason)"
      )
      exit(expected ? 0 : 1)
    case .success(let read):
      let opened = Date().timeIntervalSince(start)
      // A call returns what the one before had the CPUs store, so the first is from any time.
      _ = read()
      usleep(KernelStats.Reader.storeDelay)
      var previous = read()
      var samples: [Sample] = []
      for _ in 0..<3 {
        usleep(500_000)  // half a second
        guard let earlier = previous, let later = read() else {
          print("FAIL kernel: a call failed")
          exit(1)
        }
        switch KernelStats.sample(from: earlier, to: later) {
        case .success(let sample): samples.append(sample)
        case .failure(let problem):
          print("FAIL kernel: \(problem.reason)")
          exit(1)
        }
        previous = later
      }
      let last = samples.last!
      print(
        String(
          format: "ok kernel (opened in %.2f s; %d CPUs, package %.1f W, average %.0f MHz)",
          opened,
          last.coreMHz.count,
          last.packageWatts ?? 0,
          last.systemMHz ?? 0
        )
      )
      exit(0)
    }
  }
}
