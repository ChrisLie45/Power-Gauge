// Printing the readings to standard output with no window (`--print-csv`), for scripts and
// agents to read live.

import Cocoa

extension AppDelegate {
  /// The launch argument that prints the readings instead of showing the window.
  static let printFlag = "--print-csv"

  /// Whether this launch prints the readings to standard output rather than showing the window.
  static var prints: Bool { CommandLine.arguments.contains(printFlag) }

  /// The signals that end printing: Ctrl-C, `kill`, and the terminal closing.
  private static let quitSignals = [SIGINT, SIGTERM, SIGHUP]

  /// Starts monitoring with the sources chosen in the app, and writes a row of the readings to
  /// standard output every second, as a recording does, until monitoring ends or whatever reads
  /// them goes away.
  ///
  /// There is no window, menu bar item or Dock icon, and no settings are written. With
  /// powermetrics chosen, its password prompt still appears. Notes on how monitoring is going go
  /// to standard error. The signals that end it quit the app as its menu would, so the prompt
  /// closes and the last row is written.
  func startPrinting() {
    for number in AppDelegate.quitSignals {
      signal(number, SIG_IGN)  // so that the source below gets the signal instead
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { NSApp.terminate(nil) }
      source.resume()
      signalSources.append(source)
    }
    loadSources()
    monitor.onEvent = { [weak self] in
      self?.handle($0)
      self?.report($0)
    }
    let printer: Recorder
    do {
      printer = try Recorder(standardOutputFor: dashboard.gpus)
    } catch {
      AppDelegate.quit("Power Gauge: could not write to standard output: \(error)", status: 1)
    }
    // A write fails once nothing reads the rows any more, so there is no one left to print for.
    printer.onError = { _ in exit(1) }
    recorder = printer
    startGPUReadings()
    if let path = CommandLine.value(after: "--stream") {
      monitor.attach(stream: path)
    } else {
      start()
    }
    updateActivity()
  }

  /// Passes on to standard error what the window would have said about monitoring, and ends
  /// the process when monitoring does.
  private func report(_ event: MonitorEvent) {
    switch event {
    case .fellBack(let reason):
      AppDelegate.note("the kernel readings failed (\(reason)); starting powermetrics")
    case .prompting: AppDelegate.note("asking for an administrator password for powermetrics")
    case .cancelled: AppDelegate.quit("Power Gauge: the password prompt was cancelled", status: 1)
    case .problem(let text): AppDelegate.note(text)
    case .ended(let reason):
      recorder?.closeAndWait()
      // A `--stream` file ends once it has been read, which is no failure.
      let failed = reason != nil && CommandLine.value(after: "--stream") == nil
      if let reason = reason { AppDelegate.note(reason) }
      exit(failed ? 1 : 0)
    case .started, .sample: break
    }
  }

  private static func note(_ text: String) {
    FileHandle.standardError.write(Data("Power Gauge: \(text)\n".utf8))
  }

  private static func quit(_ text: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("\(text)\n".utf8))
    exit(status)
  }
}
