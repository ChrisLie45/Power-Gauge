// Monitoring: one root powermetrics, started through the standard macOS admin prompt, whose
// plist samples stream to this app over a named pipe. Or, as an experiment that is off unless
// turned on (`readsKernel`), the kernel's power statistics, read by this app with no password
// (see KernelStats), with powermetrics in their place where they can't be read or give
// figures that don't hold together.

import Foundation

/// What happens to monitoring, as `Monitor` reports it, always on the main thread.
enum MonitorEvent {
  /// The password prompt is up.
  case prompting
  /// The prompt was turned down, or failed.
  case cancelled
  /// The kernel or powermetrics is being read, and samples are to follow.
  case started
  /// The kernel's statistics failed, for this reason: powermetrics is next.
  case fellBack(String)
  /// It is running but has given no usable sample yet, and this is why.
  case problem(String)
  case sample(Sample, utilization: Double?, power: CPUPowerStatus?)
  /// It has stopped: nil when it was asked to, otherwise why.
  case ended(String?)
}

/// Reads the kernel's statistics, or starts powermetrics and reads its samples, until asked to
/// stop, until powermetrics fails, or until this app quits.
///
/// It is used from the main thread only; the kernel and powermetrics' stream are read on threads of
/// their own.
final class Monitor {
  var onEvent: ((MonitorEvent) -> Void)?
  /// EXPERIMENTAL, off unless turned on: whether to read the kernel's statistics first, with no
  /// password.
  ///
  /// They come from an undocumented kernel call, and the CPU's temperature from whichever SMC key a
  /// Mac has, so the app reads powermetrics, Apple's own, unless the user chooses them in Monitor >
  /// CPU Readings; see `AppDelegate.Key.kernel`.
  var readsKernel = false
  /// Where the latest session's samples come from, once it has started.
  private(set) var source: ReadingsSource?
  /// Why the kernel's statistics are not read, once that is known: they can't be read here, or gave
  /// figures that didn't hold together.
  ///
  /// Each start after that goes to powermetrics, until the app is started again.
  private(set) var kernelProblem: String?

  /// Opens the kernel's statistics; the app check gives made-up ones instead.
  var openKernel: () -> Result<() -> KernelStats.Reading?, KernelStats.Unavailable> =
    KernelStats.open

  private var sampler: KernelSampler?

  /// Forgets why the kernel's statistics failed, so that the next start tries them again, as when
  /// the user chooses them again.
  func retryKernel() { kernelProblem = nil }

  /// Whether the next start will try the kernel first.
  var triesKernel: Bool { readsKernel && kernelProblem == nil }

  /// Which start this is.
  ///
  /// A stream from an earlier one may still be ending after it was asked to stop, and whatever it
  /// has to say then is dropped.
  private var session = 0
  /// From the start, or the password prompt, until monitoring ends.
  private(set) var isActive = false
  /// Once the kernel is being read or powermetrics has been started, until it ends.
  private(set) var isRunning = false
  /// The file whose existence asks the root side to stop.
  private var stopFile: String?
  /// Given in this session.
  private var samples = 0
  /// The root-owned folder of the latest session's stream.
  private var folder: String?
  /// The first document of the latest session that gave one, as powermetrics wrote it, for
  /// the diagnostic report.
  private(set) var firstSample: Data?

  /// What powermetrics has complained of in the latest session, for the diagnostic report.
  var powermetricsErrors: String? { folder.map(RootScript.complaints) }

  /// Whether monitoring can be stopped: the kernel's readings, or any powermetrics this app
  /// started.
  var canStop: Bool { isRunning }

  private func emit(_ event: MonitorEvent) { onEvent?(event) }

  /// Runs the root script and gives its exit status and what it printed: through the macOS admin
  /// prompt, with administrator privileges.
  ///
  /// The app check runs it as the user instead, with a stand-in for powermetrics, writing its
  /// folder where `folderPrefix` says.
  var runScript: (String) -> (status: Int32, output: String) = RootScript.runAsAdministrator
  var folderPrefix = "/tmp/powergauge."
  // How long powermetrics may run without a sample before what it complained of is shown, and
  // how many unreadable documents it may give first.
  private static let complaintDelay: TimeInterval = 6
  private static let unreadableDocuments = 3

  /// Starts one root powermetrics, through the macOS admin prompt, that streams plist samples
  /// into a named pipe in a root-owned temp directory (see `RootScript.text`).
  ///
  /// With the experiment on (`readsKernel`), the kernel's statistics come first, unless they
  /// are known not to work here: they need no password. Opening them takes a few tenths of a
  /// second, on another thread; if that fails, or once they have given three seconds in a
  /// row that can't be trusted, powermetrics is started in their place.
  func start() {
    guard !isActive else { return }
    session += 1
    let session = self.session
    isActive = true
    samples = 0
    stopFile = nil
    guard triesKernel else { return startPowermetrics(session: session) }
    (isRunning, source) = (true, .kernel)
    emit(.started)
    let open = openKernel
    DispatchQueue.global().async {
      let opened = open()
      DispatchQueue.main.async {
        guard self.session == session else { return }
        switch opened {
        case .success(let read): self.readKernel(read, session: session)
        case .failure(let problem): self.fallBack(problem.reason)
        }
      }
    }
  }

  /// Reads the kernel's statistics a second at a time until stopped, or until they give up.
  ///
  /// - Parameters:
  ///   - read: Makes one reading, or gives nil when the call fails.
  ///   - session: The start this is for; what it gives after a later start is dropped.
  private func readKernel(_ read: @escaping () -> KernelStats.Reading?, session: Int) {
    let sampler = KernelSampler(read: read)
    sampler.onSample = { [weak self] sample, util, power in
      guard let self = self, self.session == session else { return }
      var sample = sample
      KernelStats.addSMCReadings(to: &sample)
      self.samples += 1
      self.emit(.sample(sample, utilization: util, power: power))
    }
    sampler.onGiveUp = { [weak self] reason in
      guard let self = self, self.session == session else { return }
      self.fallBack(reason)
    }
    self.sampler = sampler
    sampler.start()
  }

  /// Gives up on the kernel's statistics for this run of the app, and starts powermetrics.
  ///
  /// - Parameter reason: Why the kernel's statistics can't be used, kept as `kernelProblem`.
  private func fallBack(_ reason: String) {
    sampler?.stop()
    sampler = nil
    kernelProblem = reason
    session += 1
    isRunning = false
    emit(.fellBack(reason))
    startPowermetrics(session: session)
  }

  private func startPowermetrics(session: Int) {
    source = .powermetrics
    samples = 0
    let stop = Monitor.stopFilePath(session: session)
    stopFile = stop
    emit(.prompting)
    let shell = RootScript.text(appPID: ProcessInfo.processInfo.processIdentifier, stopFile: stop)
    let (run, prefix) = (runScript, folderPrefix)
    DispatchQueue.global().async {
      let (status, out) = run(shell)
      let dir = out.trimmingCharacters(in: .whitespacesAndNewlines)
      guard status == 0, dir.hasPrefix(prefix) else {
        DispatchQueue.main.async {
          guard self.session == session else { return }
          self.isActive = false
          self.emit(.cancelled)
        }
        return
      }
      DispatchQueue.main.async {
        guard self.session == session else { return }
        self.isRunning = true
        self.folder = dir
        self.emit(.started)
        // If nothing has arrived after a few seconds, say whatever powermetrics complained about.
        DispatchQueue.main.asyncAfter(deadline: .now() + Monitor.complaintDelay) {
          guard self.session == session, self.isRunning, self.samples == 0 else { return }
          let err = RootScript.complaints(in: dir)
          self.emit(
            .problem(
              err.isEmpty ? "No samples from powermetrics yet." : "powermetrics error: " + err
            )
          )
        }
      }
      self.readStream(at: dir + "/stream", session: session, stopFile: stop)
    }
  }

  /// Reads samples from an existing file or pipe instead of starting powermetrics, for testing.
  func attach(stream path: String) {
    guard !isActive else { return }
    session += 1
    let session = self.session
    (isActive, isRunning, samples, stopFile, source) = (true, true, 0, nil, .powermetrics)
    emit(.started)
    DispatchQueue.global().async { self.readStream(at: path, session: session, stopFile: nil) }
  }

  /// Stops monitoring at once, as far as the app is concerned: the kernel's readings stop, or
  /// the root side sees the stop file within a second and stops powermetrics, which ends the
  /// stream, and anything the stream gives meanwhile is dropped.
  func stop() {
    guard canStop else { return }
    sampler?.stop()
    sampler = nil
    if let file = stopFile { FileManager.default.createFile(atPath: file, contents: nil) }
    session += 1
    (isActive, isRunning) = (false, false)
    emit(.ended(nil))
  }

  /// Where the stop file for a session goes: in this user's own temp folder, named for this
  /// process and session.
  private static func stopFilePath(session: Int) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "powergauge-stop-\(getpid())-\(session)"
    ).path
  }

  /// Removes this process's stop files when the app quits.
  ///
  /// They stay until then, since the root side may not have seen one yet, as when the Mac went to
  /// sleep just after a stop.
  func removeStopFiles() {
    let dir = FileManager.default.temporaryDirectory
    let prefix = "powergauge-stop-\(getpid())-"
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    where name.hasPrefix(prefix) {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
  }

  /// Blocks on the pipe until powermetrics stops, turning each plist document into a sample.
  ///
  /// - Parameters:
  ///   - path: The named pipe, or the file or pipe given with `--stream`.
  ///   - session: The start this is for; what the stream gives after a later start is dropped.
  ///   - stopFile: The file whose existence asks the root side to stop, or nil for `--stream`.
  private func readStream(at path: String, session: Int, stopFile: String?) {
    let dir = (path as NSString).deletingLastPathComponent
    guard let handle = FileHandle(forReadingAtPath: path) else {
      DispatchQueue.main.async {
        guard self.session == session else { return }
        (self.isActive, self.isRunning) = (false, false)
        self.emit(.ended("Could not open the powermetrics stream."))
        if let file = stopFile { FileManager.default.createFile(atPath: file, contents: nil) }
      }
      return
    }
    var stream = PlistStream()
    var lastTicks = CPUTicks.read()
    var count = 0
    // This loop never returns to a run loop, which would drain its temporaries, so each read
    // drains its own.
    while autoreleasepool(invoking: { () -> Bool in
      let chunk = handle.availableData
      if chunk.isEmpty { return false }
      for document in stream.append(chunk) {
        count += 1
        if count == 1 {
          DispatchQueue.main.async { if self.session == session { self.firstSample = document } }
        }
        guard var sample = Powermetrics.parse(document) else {
          // Say so if the first few documents cannot be read.
          if count == Monitor.unreadableDocuments {
            DispatchQueue.main.async {
              guard self.session == session, self.samples == 0 else { return }
              self.emit(.problem("powermetrics is running, but its output could not be read."))
            }
          }
          continue
        }
        let ticks = CPUTicks.read()
        let util = ticks?.utilization(since: lastTicks)
        lastTicks = ticks
        sample.memory = ThisMac.memoryInUse()
        sample.arrived = ProcessInfo.processInfo.systemUptime
        let power = CPUPowerStatus.read()
        DispatchQueue.main.async {
          guard self.session == session else { return }
          self.samples += 1
          self.emit(.sample(sample, utilization: util, power: power))
        }
      }
      return true
    }) {}
    handle.closeFile()
    DispatchQueue.main.async {
      guard self.session == session else { return }
      (self.isActive, self.isRunning) = (false, false)
      // If it went without giving one sample, say what it complained about instead.
      let err = self.samples > 0 ? "" : RootScript.complaints(in: dir)
      self.emit(.ended(err.isEmpty ? "powermetrics stopped." : "powermetrics error: " + err))
      // Its complaints have been read, so the root side may remove its folder now.
      if let file = stopFile { FileManager.default.createFile(atPath: file, contents: nil) }
    }
  }
}
