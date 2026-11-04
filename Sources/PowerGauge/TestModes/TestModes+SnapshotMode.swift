// The snapshot test mode: the dashboard drawn with made-up readings, to a PNG.

import Cocoa

/// The window's background, behind the dashboard in a snapshot.
private final class Backdrop: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
  }
}

extension TestModes {
  /// Renders the dashboard with made-up data to a PNG, for checking the layout without a screen.
  ///
  /// It shows the window's content; the toolbar above it is not part of the picture. Its flags:
  ///
  /// ```
  /// --size 900x600      asks for that content size (the layout may need more)
  /// --light, --dark     the appearance, which is otherwise the system's
  /// --view cpu|gpu|both which cards are open
  /// --gpu 0|1           limits the GPU card to the first or second of two made-up GPUs
  /// --gpus <list>       which made-up GPUs there are, such as intel,amd (the default),
  ///                     intel, amd,amd or intel,nvidia; --one-gpu is --gpus intel
  /// --gpu-off <n>       has the second GPU powered down for the latest n seconds
  /// --idle              leaves the CPU card as it is before monitoring starts
  /// --state prompting|waiting|cancelled|failed|stopped|stopped-by-user   then puts it in
  ///                     that state, failed and stopped with --message <text> for what went wrong
  /// --throttled         makes the latest 15 samples carry thermal limit reasons, and those
  ///                     from 80 to 60 seconds back power ones; --power-limited makes every
  ///                     sample carry power ones, --unknown-limits gives none at all, --capped
  ///                     gives macOS a speed cap throughout, and --low-power turns on Low
  ///                     Power Mode
  /// --hover <n>         has the pointer on the moment n seconds back
  /// --history 2|5|10    how many minutes back the plots go
  /// --per-core          plots a line for each CPU's frequency, under the average
  /// --base-unknown      as on a Mac that doesn't give its base clock
  /// --mac-pro           as on a Mac Pro of 2019: a 28-core Xeon W, with 56 CPUs; with
  ///                     --gpus amd,amd,amd,amd for two Radeon Pro Vega II Duo cards
  /// --increase-contrast, --differentiate   draw as with those display accommodations on
  /// ```
  static func snapshotMode(_ path: String) -> Never {
    let flags = CommandLine.arguments
    _ = NSApplication.shared
    if flags.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
    if flags.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
    let macPro = flags.contains("--mac-pro")
    var machine = macPro ? MadeUp.macPro : MadeUp.machine
    if flags.contains("--base-unknown") { machine.baseMHz = nil }
    let dashboard = Dashboard(
      gpus: MadeUp.gpus(
        CommandLine.value(after: "--gpus") ?? (flags.contains("--one-gpu") ? "intel" : "intel,amd")
      ),
      machine: machine
    )
    dashboard.limitLayout = .skylake
    dashboard.triesKernel = flags.contains("--kernel-first")
    if flags.contains("--fallback") {
      dashboard.fallbackReason = "the kernel's call failed 3 times in a row"
    }
    if let minutes = CommandLine.value(after: "--history").flatMap({ Int($0) }) {
      dashboard.historyMinutes = minutes
    }
    dashboard.showsPerCoreFrequencies = flags.contains("--per-core")
    if let view = CommandLine.value(after: "--view") {
      dashboard.open(cpu: view != "gpu", gpu: view != "cpu")
    }
    if let gpu = CommandLine.value(after: "--gpu").flatMap({ Int($0) }) {
      dashboard.select(gpu: gpu)
    }
    var size = Dashboard.windowSize
    if let parts = CommandLine.value(after: "--size")?.split(separator: "x").compactMap({
      Double($0)
    }), parts.count == 2 {
      size = NSSize(width: parts[0], height: parts[1])
    }
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let backdrop = Backdrop()
    window.contentView = backdrop
    dashboard.translatesAutoresizingMaskIntoConstraints = false
    backdrop.addSubview(dashboard)
    NSLayoutConstraint.activate([
      dashboard.topAnchor.constraint(equalTo: backdrop.topAnchor),
      dashboard.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
      dashboard.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
      dashboard.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
    ])
    let offFor = CommandLine.value(after: "--gpu-off").flatMap { Int($0) } ?? 0
    let count = ChartPanel.capacity
    let cores = macPro ? MadeUp.macProCores : MadeUp.cores
    let cpus = cores * MadeUp.cpusPerCore
    // A processor with no integrated GPU, such as a Xeon, gives no graphics readings.
    let hasIntegratedGPU = dashboard.gpus.contains { $0.integrated }
    for slot in 0..<count {
      let phase = Double(slot) / 10
      if !flags.contains("--idle") {
        var sample = Sample()
        sample.coreMHz = (0..<cpus).map {
          2400 + 1300 * sin(phase + Double($0) / 3) + 900 * sin(phase / 3)
        }
        sample.systemMHz = sample.coreMHz.reduce(0, +) / Double(cpus)
        sample.packageWatts = 35 + 25 * sin(phase / 2)
        sample.cpuWatts = 28 + 22 * sin(phase / 2)
        if hasIntegratedGPU { (sample.gpuWatts, sample.gpuMHz) = (2, 500 + 150 * sin(phase / 2)) }
        sample.dramWatts = 1.5
        sample.cpuTempC = 70 + 18 * sin(phase / 4)
        sample.coreTempsC = (0..<cores).map { 66 + 16 * sin(phase / 4 + Double($0) / 5) }
        sample.fanRPM = 2600
        sample.prochots = 0
        if flags.contains("--kernel") {
          (sample.source, sample.gpuMHz, sample.prochots) = (.kernel, nil, nil)
        }
        sample.memory = (18 + 2 * sin(phase / 5), 3 + 0.5 * sin(phase / 3), 0.4)
        let age = count - 1 - slot
        // The processor's limits as its bits: THERMAL (1), VR_TDC (7), ICCMAX/PL4/OTHER (8) and
        // PL1 (10) limiting now, with the integrated GPU's ICCMAX/PL4/OTHER, and as names.
        sample.reportsLimits = !flags.contains("--unknown-limits")
        (sample.cpuClipping, sample.gpuClipping) = sample.reportsLimits ? (0, 0) : (nil, nil)
        if flags.contains("--throttled"), age < 15 {
          (sample.cpuClipping, sample.gpuClipping) = (1 << 1 | 1 << 7 | 1 << 8, 1 << 8)
        } else if flags.contains("--power-limited")
          || (flags.contains("--throttled") && (60...80).contains(age))
        {
          (sample.cpuClipping, sample.gpuClipping) = (1 << 8 | 1 << 10, 1 << 8)
        }
        sample.limits =
          LimitBits.now(sample.cpuClipping ?? 0, LimitBits.cpu(.skylake)).map { "CPU LIMIT " + $0 }
          + LimitBits.now(sample.gpuClipping ?? 0, LimitBits.gpu(.skylake)).map {
            "GPU LIMIT " + $0
          }
        let power = CPUPowerStatus(
          speedLimit: flags.contains("--capped") ? 80 : CPUPowerStatus.unlimited,
          lowPowerMode: flags.contains("--low-power"),
          ceilingMHz: 5000
        )
        dashboard.apply(sample, utilization: 45 + 40 * sin(phase / 1.5), power: power)
      }
      dashboard.apply(
        gpu: dashboard.gpus.enumerated().map { index, gpu in
          index == 1 && slot >= count - offFor
            ? GPUReading(poweredDown: true) : MadeUp.reading(gpu, at: phase)
        }
      )
    }
    let message = CommandLine.value(after: "--message")
    switch CommandLine.value(after: "--state") {
    case "prompting": dashboard.show(state: .prompting)
    case "waiting": dashboard.show(state: .waiting)
    case "cancelled": dashboard.show(state: .idle(cancelled: true))
    case "failed": dashboard.show(state: .failed(message ?? "No samples from powermetrics yet."))
    case "stopped": dashboard.show(state: .stopped(message ?? "powermetrics stopped."))
    case "stopped-by-user": dashboard.show(state: .stopped(nil))
    default: break
    }
    if let hover = CommandLine.value(after: "--hover").flatMap({ Int($0) }) {
      for panel in dashboard.panels { panel.hoverAge = hover }
    }
    window.layoutIfNeeded()
    backdrop.layoutSubtreeIfNeeded()
    guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { exit(1) }
    backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    exit(0)
  }
}
