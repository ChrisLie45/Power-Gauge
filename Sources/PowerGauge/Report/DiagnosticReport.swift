import Cocoa

/// The diagnostic report: what someone on another Mac can attach to a problem or hardware
/// report, so that its hardware can be supported without access to it.
enum DiagnosticReport {
  /// A plain-text report of this Mac as the app sees it: its model, macOS version, processor and
  /// memory, macOS's limits on the CPU, where the CPU's readings and the GPUs' utilisation come
  /// from, each GPU with every figure its driver publishes, and, when powermetrics has run, what it
  /// complained of and the first sample it gave.
  ///
  /// There is nothing personal in it: no names, accounts, files or processes.
  ///
  /// - Parameters:
  ///   - gpus: The GPUs found.
  ///   - machine: This Mac's model, processor and memory.
  ///   - state: The state of monitoring, or nil to leave it out.
  ///   - source: Where the CPU's readings come from, if that is known.
  ///   - gpuUtilization: Where the GPUs' utilisation comes from.
  ///   - kernelProblem: Why the kernel's statistics are not read, if they aren't.
  ///   - powermetricsErrors: What powermetrics complained of, if it has run.
  ///   - firstSample: The first sample powermetrics gave, as it wrote it.
  static func make(
    gpus: [GPU],
    machine: MachineInfo = .current,
    state: MonitorState?,
    source: ReadingsSource?,
    gpuUtilization: GPU.UtilizationSource,
    kernelProblem: String?,
    powermetricsErrors: String?,
    firstSample: Data?
  ) -> String {
    var lines: [String] = []
    let info = Bundle.main.infoDictionary ?? [:]
    let version =
      "\(info["CFBundleShortVersionString"] as? String ?? "?") "
      + "(\(info["CFBundleVersion"] as? String ?? "?"))"
    let made = ISO8601DateFormatter().string(from: Date())
    lines.append("Power Gauge diagnostic report, version \(version), made \(made)")
    lines.append(
      "Mac: \(ThisMac.model ?? "unknown model"), macOS "
        + "\(ProcessInfo.processInfo.operatingSystemVersionString)"
    )
    lines.append(
      "Processor: \(machine.processor ?? "unknown"), base "
        + (machine.baseMHz.map { String(format: "%.2f GHz", $0 / Units.mhzPerGHz) } ?? "unknown")
        + String(format: ", %d CPUs; memory %.1f GB", ThisMac.cpuCount, machine.memoryGB)
    )
    let power = CPUPowerStatus.read()
    func show(_ value: Int?) -> String { value.map(String.init) ?? "none recorded" }
    let ceiling = power.ceilingMHz.map { String(format: "%.1f GHz", $0 / Units.mhzPerGHz) }
    lines.append(
      "CPU limits from macOS: speed \(show(power.speedLimit)) %, scheduler "
        + "\(show(power.schedulerLimit)) %, CPUs \(show(power.availableCPUs)); Low Power Mode "
        + "\(power.lowPowerMode ? "on" : "off"); frequency ceiling \(ceiling ?? "unknown")"
    )
    let xcpm = [
      "hard_plimit_max_100mhz_ratio",
      "soft_plimit_max_100mhz_ratio",
      "lpm_plimit_max_100mhz_ratio",
      "cpu_thermal_level",
      "gpu_thermal_level",
      "lpm_enabled",
    ]
    lines.append(
      "Kernel power management: "
        + xcpm.map { "\($0) \(Sysctl.int("machdep.xcpm." + $0).map(String.init) ?? "?")" }.joined(
          separator: ", "
        )
    )
    lines.append(
      "GPU busy-time counters (IOReport): "
        + "\(GPUBusyCounters.shared == nil ? "unavailable" : "available")"
    )
    lines.append(
      "GPU utilization from: "
        + (gpuUtilization == .driver ? "the drivers' Device Utilization %" : "busy-time counters")
    )
    if let state = state { lines.append("Monitoring: \(state)") }
    lines.append(
      "CPU readings from: "
        + (source.map { $0 == .kernel ? "the kernel's power statistics" : "powermetrics" }
          ?? "not started yet")
    )
    lines.append(
      "Kernel's power statistics: "
        + (kernelProblem.map { "not used, because \($0)" }
          ?? (source == .kernel ? "in use" : "not tried yet"))
        + "; base clock "
        + (KernelStats.baseMHz.map { String(format: "%.0f MHz", $0) } ?? "unknown")
        + "; SMC CPU temperature "
        + (KernelStats.temperatureKeys.first { SMC.shared.value($0) != nil }.map { "from \($0)" }
          ?? "under none of \(KernelStats.temperatureKeys.joined(separator: ", "))")
        + ", fan "
        + (KernelStats.fanKeys.first { SMC.shared.value($0) != nil }.map { "from \($0)" }
          ?? "under neither of \(KernelStats.fanKeys.joined(separator: ", "))")
    )
    if let errors = powermetricsErrors, !errors.isEmpty {
      lines.append("powermetrics said: \(errors)")
    }

    lines.append("")
    lines.append("GPUs: \(gpus.count)")
    for gpu in gpus {
      let driver =
        gpu.service != 0
        ? (IOObjectCopyClass(gpu.service)?.takeRetainedValue() as String? ?? "?") : "none"
      var about = [
        "driver \(driver)",
        gpu.integrated
          ? "integrated"
          : gpu.memoryGB.map { String(format: "%.1f GB of its own", $0) } ?? "no memory size found",
      ]
      about.append("busy-time counters \(gpu.hasBusyCounters ? "yes" : "no")")
      if let keys = gpu.smcKeys {
        let smcTemperature = SMC.shared.value(keys.temperature).map { String(format: "%.2f", $0) }
        let smcPower = SMC.shared.value(keys.power).map { String(format: "%.2f", $0) }
        about.append(
          "SMC \(keys.temperature) \(smcTemperature ?? "no reading"), "
            + "\(keys.power) \(smcPower ?? "no reading")"
        )
      }
      lines.append("\(gpu.short): \(gpu.name); " + about.joined(separator: "; "))
      // Everything the driver publishes, which is where support for another GPU starts.
      for key in ["PerformanceStatistics", "AGCInfo"] {
        guard gpu.service != 0,
          let values = IORegistryEntryCreateCFProperty(
            gpu.service,
            key as CFString,
            kCFAllocatorDefault,
            0
          )?
          .takeRetainedValue() as? [String: Any]
        else { continue }
        lines.append("  \(key):")
        for name in values.keys.sorted() { lines.append("    \(name) = \(values[name]!)") }
      }
    }

    lines.append("")
    if let sample = firstSample, let text = String(data: sample, encoding: .utf8) {
      lines.append("First powermetrics sample:")
      lines.append(text)
    } else {
      lines.append("No powermetrics sample: monitoring has not run since the app started.")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
