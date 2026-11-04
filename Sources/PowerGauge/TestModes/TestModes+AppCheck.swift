// The app check: the real app, offscreen and without a password.

import Cocoa

extension TestModes {
  /// Runs the real app without showing anything and without a password: its window, menus, menu bar
  /// menu, monitoring and recording.
  ///
  /// The root script runs as the user, with a stand-in for powermetrics that writes the sample file
  /// given (an absolute path) twice a second until it is stopped, or until it is told to fail.
  /// Steps: check that powermetrics is the default; choose the GPUs' utilisation from their
  /// busy-time counters and back, and check which of a driver's figures each source takes; with the experimental
  /// kernel readings turned on, monitor from this Mac's kernel where it can be read, then from
  /// made-up statistics (`MadeUpKernel`);
  /// start again and have the kernel's readings stop holding together, so that powermetrics takes
  /// over; check the menus and the menu bar menu, record for a few seconds, stop, start again, have
  /// powermetrics fail, and quit. Prints `ok <step>` or `FAIL <step>: <why>` for each, and
  /// exits 1 if any failed. Writes nothing to the user defaults, and cleans up after itself.
  static func appCheckMode(_ fixture: String) -> Never {
    _ = NSApplication.shared
    let files = FileManager.default
    let work =
      files.temporaryDirectory.appendingPathComponent("powergauge-app-check-\(getpid())").path
    let fake = work + "/powermetrics"
    let die = work + "/die"
    let starts = work + "/starts"
    try? files.createDirectory(atPath: work, withIntermediateDirectories: true)
    files.createFile(
      atPath: fake,
      contents: Data(
        """
        #!/bin/bash
        # Stands in for powermetrics: notes that it started, then writes the sample twice a
        # second until it is stopped, or until the file "die" appears beside it.
        echo started >> '\(starts)'
        while [ ! -e '\(die)' ]; do /bin/cat '\(fixture)'; /bin/sleep 0.5; done
        """.utf8
      ),
      attributes: [.posixPermissions: 0o755]
    )

    let app = AppDelegate()
    app.buildWindow()
    app.monitor.onEvent = { [weak app] in app?.handle($0) }
    app.monitor.folderPrefix = work + "/powergauge."
    app.monitor.runScript = { script in
      let local = script.replacingOccurrences(of: "/usr/bin/powermetrics", with: fake)
        .replacingOccurrences(of: "/tmp/powergauge.", with: work + "/powergauge.")
      let task = Process()
      let pipe = Pipe()
      task.executableURL = URL(fileURLWithPath: "/bin/sh")
      task.arguments = ["-c", local]
      task.standardOutput = pipe
      task.standardError = FileHandle.nullDevice
      guard (try? task.run()) != nil else { return (-1, "") }
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      task.waitUntilExit()
      return (task.terminationStatus, out)
    }

    var failed = false
    func check(_ step: String, _ ok: Bool, _ why: @autoclosure () -> String) {
      print(ok ? "ok \(step)" : "FAIL \(step): \(why())")
      failed = failed || !ok
    }
    // Lets the app run until `done` is true, for up to `seconds`.
    func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
      let end = Date().addingTimeInterval(seconds)
      while !done() {
        if Date() > end { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))  // a look every 50 ms
      }
      return true
    }
    var state: MonitorState { app.dashboard.state }
    var running: Bool {
      if case .running = state { return true }
      return false
    }
    func enabled(_ action: Selector) -> Bool {
      app.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }
    func fakeRunning() -> Bool {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
      task.arguments = ["-f", fake]
      task.standardOutput = FileHandle.nullDevice
      try? task.run()
      task.waitUntilExit()
      return task.terminationStatus == 0
    }
    func folders() -> [String] {
      ((try? files.contentsOfDirectory(atPath: work)) ?? []).filter { $0.hasPrefix("powergauge.") }
    }
    func startCount() -> Int {
      ((try? String(contentsOfFile: starts, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    // powermetrics by default: the kernel's statistics are an experiment, off until turned on.
    check(
      "powermetrics by default",
      !Monitor().triesKernel && !app.monitor.triesKernel && !app.dashboard.triesKernel,
      "a new monitor would \(Monitor().triesKernel ? "" : "not ")try the kernel, this one "
        + "would \(app.monitor.triesKernel ? "" : "not ")"
    )
    // Choosing the kernel readings in Monitor > CPU Readings: nothing changes if the warning is
    // turned down, and they are on once it is accepted.
    func pick(_ tag: Int) {
      let item = NSMenuItem(
        title: "",
        action: #selector(AppDelegate.pickSource(_:)),
        keyEquivalent: ""
      )
      item.tag = tag
      app.pickSource(item)
    }
    func ticked(_ tag: Int, in action: Selector = #selector(AppDelegate.pickSource(_:))) -> Bool {
      let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
      item.tag = tag
      _ = app.validateMenuItem(item)
      return item.state == .on
    }
    var warned = 0
    app.confirmKernel = {
      warned += 1
      return false
    }
    pick(AppDelegate.SourceTag.kernel)
    let declined =
      !app.monitor.readsKernel && ticked(AppDelegate.SourceTag.powermetrics)
      && !ticked(AppDelegate.SourceTag.kernel)
    app.confirmKernel = {
      warned += 1
      return true
    }
    pick(AppDelegate.SourceTag.kernel)
    check(
      "choosing the kernel readings",
      declined && warned == 2 && app.monitor.readsKernel && app.dashboard.triesKernel
        && ticked(AppDelegate.SourceTag.kernel) && !ticked(AppDelegate.SourceTag.powermetrics),
      "the warning was shown \(warned) times; the kernel readings are "
        + "\(app.monitor.readsKernel ? "on" : "off")"
    )

    // Choosing the GPUs' utilisation in Monitor > GPU Utilization, which the test mode leaves out
    // of the user defaults.
    let utilizationMenu = #selector(AppDelegate.pickUtilization(_:))
    func pickUtilization(_ tag: Int) {
      let item = NSMenuItem(title: "", action: utilizationMenu, keyEquivalent: "")
      item.tag = tag
      app.pickUtilization(item)
    }
    let defaults = UserDefaults.standard
    let savedUtilization = defaults.object(forKey: AppDelegate.Key.busyTimeUtilization) as? Bool
    let byDriver =
      app.dashboard.gpuUtilizationSource == .driver
      && ticked(AppDelegate.UtilizationTag.driver, in: utilizationMenu)
    pickUtilization(AppDelegate.UtilizationTag.busyTime)
    let byCounters =
      app.dashboard.gpuUtilizationSource == .busyTime
      && ticked(AppDelegate.UtilizationTag.busyTime, in: utilizationMenu)
      && !ticked(AppDelegate.UtilizationTag.driver, in: utilizationMenu)
    pickUtilization(AppDelegate.UtilizationTag.driver)
    check(
      "choosing the GPU utilization",
      byDriver && byCounters && app.dashboard.gpuUtilizationSource == .driver
        && defaults.object(forKey: AppDelegate.Key.busyTimeUtilization) as? Bool == savedUtilization
        && enabled(utilizationMenu) == !app.dashboard.gpus.isEmpty,
      "the drivers' figures were \(byDriver ? "" : "not ")the default; the counters were "
        + "\(byCounters ? "" : "not ")chosen; the source is now \(app.dashboard.gpuUtilizationSource)"
    )
    // Which of a driver's figures each source takes, from made-up statistics with all of them:
    // Intel's plain figure is scaled by its clock, and NVIDIA's core figure is in ten-millionths.
    let intel: [String: Any] = ["Device Utilization %": 20, GPU.unscaledUtilization: 49]
    let nvidia: [String: Any] = ["Device Utilization %": 30, "GPU Core Utilization": 60_000_000]
    func figure(
      _ stats: [String: Any],
      nvidia: Bool = false,
      integrated: Bool = false,
      _ source: GPU.UtilizationSource
    ) -> Double? {
      GPU.reading(from: stats, nvidia: nvidia, integrated: integrated, utilization: source)
        .utilization
    }
    let figures = [
      figure(intel, integrated: true, .busyTime),
      figure(intel, integrated: true, .driver),
      figure(nvidia, nvidia: true, .busyTime),
      figure(nvidia, nvidia: true, .driver),
      figure([GPU.unscaledUtilization: 49], integrated: true, .driver),
    ]
    check(
      "GPU utilization figures",
      figures == [49, 20, 6, 30, 49],
      "Intel's, NVIDIA's and Intel's without a plain figure were \(figures)"
    )

    // This Mac's own kernel statistics through the whole app, where they can be read: checked
    // first, since monitoring that couldn't read them would go to powermetrics for the rest of the
    // run.
    switch KernelStats.open() {
    case .failure(let problem):
      print("ok this Mac's kernel (not available here: \(problem.reason))")
    case .success:
      app.start()
      check(
        "this Mac's kernel",
        wait(6) { running && app.monitor.source == .kernel } && startCount() == 0,
        "the state is \(state), the source \(String(describing: app.monitor.source)), the "
          + "kernel's problem \(app.monitor.kernelProblem ?? "none")"
      )
      app.menuNeedsUpdate(app.statusMenu)
      let lines = app.statusMenu.items.map { $0.title }
      // The temperature comes from the SMC, under a key this Mac may not have.
      let hasTemperature = KernelStats.temperatureKeys.contains { SMC.shared.value($0) != nil }
      check(
        "this Mac's kernel readings",
        lines.contains { $0.hasPrefix("Fastest core ") }
          && lines.contains { $0.hasPrefix("Package ") }
          && (!hasTemperature || lines.contains { $0.hasPrefix("CPU die ") }),
        "the menu bar menu's items are \(lines)"
      )
      app.stopMonitoring()
    }

    // From made-up kernel statistics: samples with no password, so with powermetrics never started.
    let kernel = MadeUpKernel()
    app.monitor.openKernel = { .success(kernel.read) }
    app.start()
    check(
      "kernel start",
      wait(6) { running && app.dashboard.hasSamples } && app.monitor.source == .kernel
        && app.dashboard.readingsSource == .kernel && startCount() == 0,
      "the state is \(state), the source \(String(describing: app.monitor.source)); "
        + "powermetrics started \(startCount()) times"
    )
    app.menuNeedsUpdate(app.statusMenu)
    check(
      "kernel readings",
      app.statusMenu.items.contains { $0.title == "Package 20.0 W" },
      "the menu bar menu's items are \(app.statusMenu.items.map { $0.title })"
    )
    app.stopMonitoring()
    check(
      "kernel stop",
      state == .stopped(nil) && !app.monitor.canStop && enabled(#selector(AppDelegate.start)),
      "the state is \(state)"
    )

    // Readings that stop holding together: after three seconds of them, powermetrics takes over.
    app.start()
    _ = wait(6) { running && app.monitor.source == .kernel }
    kernel.breakReadings()
    check(
      "falls back to powermetrics",
      wait(10) { running && app.monitor.source == .powermetrics && startCount() == 1 }
        && app.monitor.kernelProblem?.contains("went backwards") == true
        && app.dashboard.fallbackReason == app.monitor.kernelProblem,
      "the state is \(state), the source \(String(describing: app.monitor.source)), the "
        + "reason \(app.monitor.kernelProblem ?? "none"); powermetrics started \(startCount()) "
        + "times"
    )
    check(
      "menus while monitoring",
      !enabled(#selector(AppDelegate.start)) && enabled(#selector(AppDelegate.stopMonitoring)),
      "Start Monitoring is \(enabled(#selector(AppDelegate.start)) ? "on" : "off"), Stop "
        + "Monitoring \(enabled(#selector(AppDelegate.stopMonitoring)) ? "on" : "off")"
    )

    app.menuNeedsUpdate(app.statusMenu)
    let titles = app.statusMenu.items.map { $0.title }
    // What the menu should say, worked out from the sample the stand-in writes: its readings, and
    // its limits as the app reads them, after macOS's own should this Mac be capped just now.
    var stream = PlistStream()
    guard
      let given = stream.append((try? Data(contentsOf: URL(fileURLWithPath: fixture))) ?? Data())
        .first.flatMap({ Powermetrics.parse($0) }),
      let average = given.systemMHz,
      let watts = given.packageWatts,
      let dieC = given.cpuTempC,
      let fan = given.fanRPM
    else {
      print("FAIL setup: \(fixture) has no frequency, package power, temperature or fan reading")
      exit(1)
    }
    let reasons = CPULimits(sample: given, power: nil)
    let expected = [
      String(
        format: "Fastest core %.2f GHz, average %.2f GHz",
        (given.peakMHz ?? average) / 1000,
        average / 1000
      ),
      String(format: "CPU die %.0f °C, fan %.0f rpm", dieC, fan),
      String(format: "Package %.1f W", watts),
      "Show Window",
      "Stop Monitoring",
      "Quit Power Gauge",
    ]
    let commands = app.statusMenu.items.filter { $0.action != nil }
    check(
      "menu bar menu",
      expected.allSatisfy(titles.contains)
        && titles.contains { line in
          reasons.names.allSatisfy(line.contains)
            && (line.hasPrefix(reasons.headline) || line.hasPrefix("Throttled by macOS"))
        }
        && (reasons.gpu.isEmpty
          || titles.contains("Intel GPU limited: " + reasons.gpu.joined(separator: ", ")))
        && commands.allSatisfy { $0.target != nil },
      "its items are \(titles)"
    )

    let csv = URL(fileURLWithPath: work + "/recording.csv")
    app.startRecording(to: csv)
    _ = wait(2.6) { false }
    app.stopRecording()
    // The file is closed in the background once its last rows are on the disk.
    var rows: [Substring] = []
    _ = wait(3) {
      rows = ((try? String(contentsOf: csv, encoding: .utf8)) ?? "").split(separator: "\n")
      return rows.count >= 3
    }
    check(
      "recording",
      rows.count >= 3
        && rows.dropFirst().allSatisfy { $0.contains(String(format: ",%.2f,", watts)) },
      "\(rows.count) lines were written"
    )

    app.stopMonitoring()
    let stoppedAtOnce = state == .stopped(nil)
    check(
      "stop",
      stoppedAtOnce && wait(4) { !fakeRunning() } && wait(3) { folders().isEmpty }
        && enabled(#selector(AppDelegate.start)) && !enabled(#selector(AppDelegate.stopMonitoring)),
      "the state is \(state), powermetrics is "
        + "\(fakeRunning() ? "still running" : "stopped"), folders left: \(folders())"
    )

    app.start()
    check(
      "restart",
      wait(6) { running } && startCount() == 2,
      "the state is \(state); powermetrics started \(startCount()) times"
    )

    // Running for more than 3 s before failing, it is not taken for having turned its arguments
    // down.
    _ = wait(3.5) { false }
    files.createFile(atPath: die, contents: nil)
    check(
      "powermetrics fails",
      wait(6) { state == .stopped("powermetrics stopped.") } && startCount() == 2,
      "the state is \(state); powermetrics started \(startCount()) times"
    )

    // After the kernel failed: choosing it again tries it afresh, after the warning again; then
    // back to powermetrics. Nothing is running, so nothing starts.
    let failedBefore = app.monitor.kernelProblem != nil && !app.monitor.triesKernel
    warned = 0
    pick(AppDelegate.SourceTag.kernel)
    let retried = warned == 1 && app.monitor.kernelProblem == nil && app.monitor.triesKernel
    pick(AppDelegate.SourceTag.powermetrics)
    check(
      "switching sources",
      failedBefore && retried && !app.monitor.readsKernel
        && ticked(AppDelegate.SourceTag.powermetrics) && !app.dashboard.triesKernel
        && startCount() == 2,
      "failed before: \(failedBefore), retried: \(retried); the kernel readings are "
        + "\(app.monitor.readsKernel ? "on" : "off"); powermetrics started \(startCount()) times"
    )

    app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    let stopFiles = ((try? files.contentsOfDirectory(atPath: files.temporaryDirectory.path)) ?? [])
      .filter { $0.hasPrefix("powergauge-stop-\(getpid())-") }
    check("quitting", stopFiles.isEmpty, "stop files left: \(stopFiles)")

    _ = wait(2) { folders().isEmpty }
    try? files.removeItem(atPath: work)
    exit(failed ? 1 : 0)
  }
}
