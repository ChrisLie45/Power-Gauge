// Recording to a CSV file, with a button in the toolbar to stop it.

import Cocoa
import UniformTypeIdentifiers

extension AppDelegate {
  /// Asks where to record to and starts, or stops a recording under way.
  @objc func toggleRecording() {
    if recorder != nil { return stopRecording() }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
    panel.nameFieldStringValue = "Power Gauge \(stamp.string(from: Date())).csv"
    panel.message = "A row of readings is added every second until you stop recording."
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self = self, response == .OK, let url = panel.url else { return }
      self.startRecording(to: url)
    }
  }

  /// Starts recording to the file at `url`, replacing it, with a button in the toolbar to stop.
  func startRecording(to url: URL) {
    guard recorder == nil else { return }
    let started: Recorder
    do {
      started = try Recorder(url: url, gpus: dashboard.gpus)
    } catch {
      window.presentError(error)
      return
    }
    // A write that fails ends the recording, unless another has been started since.
    started.onError = { [weak self, weak started] error in
      guard let self = self, let failed = started, self.recorder === failed else { return }
      self.stopRecording()
      self.window.presentError(error)
    }
    recorder = started
    toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: toolbar.items.count)
    toolbar.insertItem(withItemIdentifier: AppDelegate.recordingID, at: toolbar.items.count)
    startGPUReadings()
    updateActivity()
  }

  func stopRecording() {
    recorder?.close()
    recorder = nil
    for (index, item) in toolbar.items.enumerated().reversed()
    where [AppDelegate.recordingID, .flexibleSpace].contains(item.itemIdentifier) {
      toolbar.removeItem(at: index)
    }
    updateActivity()
  }

  /// Adds a row to the recording, if there is one: the CPU's latest sample, if one has just
  /// come, and the GPUs' latest readings, if they are no more than two seconds old.
  func record(cpu: Recorder.CPUReadings?) {
    guard let recorder = recorder else { return }
    let gpu = latestGPU.flatMap {
      Date().timeIntervalSince($0.at) <= AppDelegate.readingsStaleAfter ? $0.readings : nil
    }
    guard cpu != nil || gpu != nil else { return }
    recorder.write(cpu: cpu, gpu: gpu)
  }
}
