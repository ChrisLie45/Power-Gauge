// Monitoring as the app runs it: starting and stopping, choosing where the CPU's readings come
// from, and passing the readings on to the dashboard, the menu bar item and the recording.

import Cocoa

extension AppDelegate {
  @objc func start() {
    guard dashboard.state.canStart, !monitor.isActive else { return }
    monitor.start()
  }

  @objc func stopMonitoring() { monitor.stop() }

  /// Reads the CPU with powermetrics (tag 0) or the experimental kernel readings (tag 1), the
  /// latter only once the user has confirmed the warning.
  ///
  /// Choosing the kernel again after it failed tries it afresh. Monitoring under way starts again
  /// with the new source.
  @objc func pickSource(_ sender: NSMenuItem) {
    let kernel = sender.tag == SourceTag.kernel
    guard kernel != monitor.readsKernel || (kernel && monitor.kernelProblem != nil) else { return }
    if kernel, !confirmKernel() { return }
    monitor.readsKernel = kernel
    if kernel { monitor.retryKernel() }
    if persists { UserDefaults.standard.set(kernel, forKey: Key.kernel) }
    sourceChanged()
    if monitor.canStop {
      monitor.stop()
      start()
    }
  }

  /// Brings what depends on where the CPU's readings will come from into line with it: the
  /// dashboard's wording, and what starting is said to do.
  func sourceChanged() {
    dashboard.triesKernel = monitor.triesKernel
    dashboard.fallbackReason = monitor.readsKernel ? monitor.kernelProblem : nil
    let tip =
      monitor.triesKernel
      ? "Start monitoring. If the CPU can't be read without a password, asks for one to start "
        + "powermetrics"
      : "Start powermetrics; asks for an administrator password"
    dashboard.startButton.toolTip = tip
    for link in [dashboard.cpuStartLink, dashboard.gpuStartLink] { link.toolTip = tip }
  }

  /// The CPU card's button, which stops monitoring instead while it has started but given no
  /// sample yet, so that a start that hangs can be called off.
  @objc func startOrStop() {
    if dashboard.state.canStart { start() } else { stopMonitoring() }
  }

  func handle(_ event: MonitorEvent) {
    sourceChanged()
    switch event {
    // The prompt for powermetrics follows; sourceChanged gave the dashboard the reason.
    case .fellBack: break
    case .prompting: dashboard.show(state: .prompting)
    case .cancelled: dashboard.show(state: .idle(cancelled: true))
    case .started: dashboard.show(state: .waiting)
    case .problem(let text): dashboard.show(state: .failed(text))
    case .sample(let given, let utilization, let power):
      // Each core's temperature is added here rather than where the sample is read, since the
      // SMC is used from the main thread only.
      var sample = given
      sample.coreTempsC = SMC.shared.coreTemperatures()
      latest = Recorder.CPUReadings(
        sample: sample,
        utilization: utilization,
        power: power,
        limits: CPULimits(sample: sample, power: power)
      )
      latestArrival = sample.arrived ?? ProcessInfo.processInfo.systemUptime
      dashboard.apply(sample, utilization: utilization, power: power)
      record(cpu: latest)
    case .ended(let error):
      (latest, latestArrival) = (nil, nil)
      dashboard.show(state: .stopped(error))
    }
    // Return presses the button only while it starts monitoring, never to stop it.
    dashboard.startButton.keyEquivalent = dashboard.state.canStart ? "\r" : ""
    updateStatusItem()
    updateActivity()
  }

  func updateActivity() {
    let busy = monitor.isActive || recorder != nil
    if busy, activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Monitoring or recording"
      )
    } else if !busy, let token = activity {
      ProcessInfo.processInfo.endActivity(token)
      activity = nil
    }
  }

  private static let gpuReadingInterval: TimeInterval = 1
  private static let gpuReadingTolerance: TimeInterval = 0.1

  /// Reads every GPU once a second from the first time the GPU card is opened or a recording
  /// starts.
  ///
  /// It waits until then because reading a driver's statistics can disturb the figures that other
  /// GPU monitors read from them; after that it keeps going, so the rows have no holes when the
  /// card is reopened. The slack lets macOS run the timer alongside other wake-ups rather than
  /// waking the processor for it alone.
  func startGPUReadings() {
    guard gpuTimer == nil, dashboard.showsGPU || recorder != nil, !dashboard.gpus.isEmpty else {
      return
    }
    let read = { [weak self] in
      guard let self = self else { return }
      let readings = self.dashboard.apply(
        gpu: GPU.readAll(self.dashboard.gpus, utilization: self.dashboard.gpuUtilizationSource)
      )
      self.latestGPU = (Date(), readings)
      // While samples come, rows are written with them instead.
      if self.latestArrival.map({
        ProcessInfo.processInfo.systemUptime - $0 > AppDelegate.readingsStaleAfter
      }) ?? true {
        self.record(cpu: nil)
      }
    }
    read()
    let timer = Timer(timeInterval: AppDelegate.gpuReadingInterval, repeats: true) { _ in read() }
    timer.tolerance = AppDelegate.gpuReadingTolerance
    RunLoop.main.add(timer, forMode: .common)
    gpuTimer = timer
  }
}
