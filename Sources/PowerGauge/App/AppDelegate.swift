import Cocoa

/// The app: its lifecycle, and the state its parts share.
///
/// Each part is an extension in a file of its own: the window and its toolbar
/// (`AppDelegate+Window`), the menus (`+Menus`), monitoring (`+Monitoring`), the menu bar item
/// (`+MenuBarItem`), recording (`+Recording`), printing the readings with no window (`+Printing`)
/// and the diagnostic report (`+Report`).
final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var statusItem: NSStatusItem?
  let statusMenu = NSMenu()
  // While the menu bar menu is open: its lines of readings, and the titles of its commands,
  // as last shown (see refreshOpenStatusMenu).
  var statusMenuOpen = false
  var statusLineItems: [NSMenuItem] = []
  var statusCommandTitles: [String] = []
  let dashboard = Dashboard(gpus: GPU.findAll())
  let toolbar = NSToolbar(identifier: "main")
  let monitor = Monitor()
  // The latest CPU sample while monitoring runs, and the latest GPU readings as plotted.
  var latest: Recorder.CPUReadings?
  var latestGPU: (at: Date, readings: [GPUReading])?
  var recorder: Recorder?
  /// When the latest CPU sample arrived, in seconds of uptime.
  var latestArrival: TimeInterval?
  /// Held while monitoring or recording, so that App Nap does not slow the samples down
  /// while the window is hidden; idle sleep is still allowed.
  var activity: NSObjectProtocol?
  /// The window's frame for each set of open cards as it was last left, so that going back to a set
  /// gives the window that size again.
  ///
  /// Kept in the user defaults from one launch to the next.
  var frames: [String: NSRect] = [:]
  /// Where the last change of cards would have put the window's top-left corner, and where it
  /// put it instead to keep the window on its screen; the next change starts from the first
  /// if the window has not been moved since.
  var nudge: (wanted: NSPoint, placed: NSPoint)?
  /// In full screen, or on the way in or out.
  var fullScreen = false
  /// Where the window is being animated to, until it gets there.
  var heading: NSRect?
  var gpuTimer: Timer?
  /// What hears the signals that end `--print-csv`, kept for as long as the app runs.
  var signalSources: [DispatchSourceSignal] = []
  /// Whether what the window is left like is kept in the user defaults: only in the app
  /// proper, not in the test modes that build its window.
  var persists = false
  /// GPU readings older than this are left out of a recording's row; and once the latest CPU
  /// sample is older than this, the GPU readings are recorded in rows of their own.
  static let readingsStaleAfter: TimeInterval = 2
  private static let memoryLogInterval: TimeInterval = 5

  /// What is kept in the user defaults besides the window's frames.
  enum Key {
    /// "cpu", "gpu" or "both".
    static let cards = "OpenCards"
    /// The short name of the one GPU the GPU card shows.
    static let gpu = "SelectedGPU"
    /// 2, 5 or 10.
    static let history = "HistoryMinutes"
    /// Whether the frequency row has a line for every CPU.
    static let perCore = "PerCoreFrequencies"
    /// EXPERIMENTAL: whether to read the CPU from the kernel, with no password, rather than with
    /// powermetrics (see `Monitor.readsKernel`).
    ///
    /// Chosen in Monitor > CPU Readings, after a warning.
    static let kernel = "ExperimentalKernelReadings"
    /// Whether the GPUs' utilisation comes from their busy-time counters rather than their
    /// drivers' own figure (see `GPU.UtilizationSource`).
    ///
    /// Chosen in Monitor > GPU Utilization.
    static let busyTimeUtilization = "BusyTimeGPUUtilization"
  }

  /// Asks the user to confirm choosing the experimental kernel readings; the app check answers
  /// for itself, since an alert would wait for a click.
  var confirmKernel: () -> Bool = {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Kernel readings are experimental"
    alert.informativeText =
      "They need no password but may be wrong or not work on your Mac. If they fail, Power "
      + "Gauge switches back to powermetrics. They don't include the Intel GPU's clock."
    alert.addButton(withTitle: "Use Kernel")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if AppDelegate.prints { return startPrinting() }
    persists = true
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Digits all of one width, as in the dashboard and the item's own reading (see
    // `statusImage`), since the menu's readings change in place while it is open.
    statusMenu.font = .monospacedDigitSystemFont(
      ofSize: NSFont.menuFont(ofSize: 0).pointSize,
      weight: .regular
    )
    statusMenu.delegate = self
    statusItem?.menu = statusMenu
    updateStatusItem()
    NSWindow.allowsAutomaticWindowTabbing = false  // one window, so no tab items in the View menu
    buildMenu()
    buildWindow()
    restoreViewOptions()
    restoreFrames()
    // Only now, so that setting the window up is not taken for the user's sizing.
    window.delegate = self
    dashboard.onGPUSelect = { [weak self] in self?.rememberGPU() }
    loadSources()
    monitor.onEvent = { [weak self] in self?.handle($0) }
    sourceChanged()
    startGPUReadings()

    // Test hooks: `--stream <path>` reads samples from an existing file or pipe instead of
    // starting powermetrics, and `--memlog <path>` appends memory and CPU figures every 5 s.
    if let path = CommandLine.value(after: "--memlog") {
      FileManager.default.createFile(atPath: path, contents: nil)
      Timer.scheduledTimer(withTimeInterval: AppDelegate.memoryLogInterval, repeats: true) { _ in
        guard let log = FileHandle(forWritingAtPath: path) else { return }
        log.seekToEndOfFile()
        log.write(Data((TestModes.memoryLine() + "\n").utf8))
        log.closeFile()
      }
    }
    if let path = CommandLine.value(after: "--stream") {
      monitor.attach(stream: path)
      window.orderFront(nil)
      return
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Takes where the CPU's readings and the GPUs' utilisation come from as the user chose them.
  func loadSources() {
    monitor.readsKernel = UserDefaults.standard.bool(forKey: Key.kernel)
    dashboard.gpuUtilizationSource =
      UserDefaults.standard.bool(forKey: Key.busyTimeUtilization) ? .busyTime : .driver
  }

  /// Closing the window leaves the app running, with monitoring, any recording and the menu
  /// bar item carrying on; the menu bar item's Show Window, or the Dock icon, brings it back.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { showWindow() }
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    RootScript.closePrompts()
    recorder?.closeAndWait()
    monitor.removeStopFiles()
  }

  @objc func showWindow() {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
