// Saving the diagnostic report, from the Help menu.

import Cocoa
import UniformTypeIdentifiers

extension AppDelegate {
  /// Saves the diagnostic report (see `DiagnosticReport`) where the user says, for attaching to
  /// a bug report.
  @objc func saveReport() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
    panel.nameFieldStringValue = "Power Gauge Report \(stamp.string(from: Date())).txt"
    panel.message =
      "The report describes this Mac's processor and GPUs and what the app reads from them. "
      + "It has nothing personal in it."
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self = self, response == .OK, let url = panel.url else { return }
      let report = DiagnosticReport.make(
        gpus: self.dashboard.gpus,
        state: self.dashboard.state,
        source: self.monitor.source,
        gpuUtilization: self.dashboard.gpuUtilizationSource,
        kernelProblem: self.monitor.kernelProblem,
        powermetricsErrors: self.monitor.powermetricsErrors,
        firstSample: self.monitor.firstSample
      )
      do {
        try report.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        self.window.presentError(error)
      }
    }
  }
}
