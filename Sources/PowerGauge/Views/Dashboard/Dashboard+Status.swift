// What the cards say about monitoring: the CPU card's blank state until the first sample and
// its header after it, and the GPU card's one remark.

import Cocoa

extension Dashboard {
  private var fallbackText: String? {
    fallbackReason.map { "Couldn't read the CPU without a password: \($0)." }
  }

  /// Brings everything that depends on the monitoring state, on which cards are open or on
  /// the GPUs chosen into line with them.
  func refresh() {
    var limits = CPULimits()
    var running = false
    if case .running(let reported) = state {
      limits = reported
      running = true
    }

    // Until there is a sample to plot, the CPU card explains itself where its rows will be.
    cpuCard.rows.isHidden = !hasSamples
    blank.isHidden = hasSamples
    // Its button starts monitoring, or stops it while powermetrics runs without a sample.
    var picture = "cpu"
    var title = "Not Monitoring"
    var message = ""
    var busy = false
    var offersStart = false
    var offersStop = false
    if !hasSamples {
      switch state {
      case .idle(let cancelled):
        message =
          cancelled
          ? [
            fallbackText,
            "The password prompt was cancelled or failed. powermetrics needs an "
              + "administrator password.",
          ].compactMap { $0 }.joined(separator: " ")
          : triesKernel
            ? "CPU readings come from macOS's kernel and need no password. If they can't be "
              + "read, Power Gauge asks for one to use powermetrics instead."
            : "CPU readings come from powermetrics, which needs an administrator password. It "
              + "stops when you quit Power\u{00A0}Gauge."
        offersStart = true
      case .prompting:
        message =
          fallbackText.map {
            $0 + " Waiting for an administrator password to use powermetrics instead…"
          } ?? "Waiting for administrator password…"
        (busy, offersStart) = (true, true)
      case .waiting:
        (title, message, busy, offersStop) = ("Starting", "Waiting for first sample…", true, true)
      case .failed(let text):
        (picture, title, message, offersStop) = (
          "exclamationmark.circle",
          "No Readings Yet",
          text,
          true
        )
      case .stopped(let text):
        (picture, title, message, offersStart) = (
          "exclamationmark.circle",
          "Monitoring Stopped",
          text ?? "Monitoring was stopped before the first sample.",
          true
        )
      case .running: break
      }
    }
    blankSymbol.image = NSImage.symbol(picture, size: 28, weight: .regular)
    blankSymbol.isHidden = blankSymbol.image == nil
    blankTitle.stringValue = title
    blankMessage.stringValue = message
    blankSpinner.isHidden = !busy
    if busy { blankSpinner.startAnimation(nil) } else { blankSpinner.stopAnimation(nil) }
    startButton.isHidden = !(offersStart || offersStop)
    startButton.isEnabled = state.canStart || offersStop
    startButton.title = offersStop ? "Stop Monitoring" : "Start Monitoring…"

    // The CPU card's header says nothing until the first sample. After it: what is limiting
    // the CPU, by its worst kind (see CPULimits), and every limit by name; or what has gone
    // wrong since. Heat and macOS's caps get a red warning, the power budget an amber mark,
    // and limits that are part of normal turbo none. A sample that gave no limit reasons
    // says so, rather than that nothing limits the CPU. Trouble with the readings gets a
    // mark of another shape.
    var mark: (name: String, color: NSColor)?
    var word = ""
    var detail = ""
    if hasSamples {
      switch state {
      case .running:
        mark =
          limits.warns
          ? ("exclamationmark.triangle.fill", NSColor.systemRed)
          : limits.worst == .power
            ? ("bolt.circle.fill", NSColor.systemOrange)
            : limits.known
              ? ("checkmark.circle.fill", NSColor.systemGreen)
              : ("questionmark.circle.fill", NSColor.secondaryLabelColor)
        word = limits.headline
        detail =
          !limits.names.isEmpty
          ? limits.names.joined(separator: ", ")
          : limits.known
            ? "none"
            : readingsSource == .kernel
              ? "this processor doesn't report what is limiting it"
              : "powermetrics did not say what is limiting the processor"
      case .failed(let text):
        mark = ("exclamationmark.circle.fill", NSColor.secondaryLabelColor)
        (word, detail) = ("Reading problem", text)
      case .stopped(let text):
        mark = (
          text == nil ? "stop.circle.fill" : "exclamationmark.circle.fill",
          NSColor.secondaryLabelColor
        )
        (word, detail) = ("Monitoring stopped", text ?? "")
      case .idle(cancelled: true):
        mark = ("exclamationmark.circle.fill", NSColor.secondaryLabelColor)
        (word, detail) = ("Not monitoring", "The password prompt was cancelled or failed.")
      case .prompting: (word, detail) = ("Waiting for administrator password…", fallbackText ?? "")
      case .waiting: word = "Waiting for first sample…"
      default: break
      }
    }
    cpuStartLink.isHidden = !(hasSamples && state.canStart)
    cpuMark.image = mark.flatMap { NSImage.symbol($0.name, size: 12) }
    cpuMark.contentTintColor = mark?.color
    cpuMark.isHidden = cpuMark.image == nil
    cpuState.stringValue = word
    cpuState.isHidden = word.isEmpty
    limitsCaption.isHidden = !(hasSamples && running)
    limitsValue.stringValue = detail
    // Resting the pointer on the list explains each limit in it; otherwise it shows the
    // text cut short, should it be.
    limitsValue.toolTip = running && !limits.names.isEmpty ? limits.explanation : nil
    limitsValue.allowsExpansionToolTips = limitsValue.toolTip == nil
    limitsValue.textColor =
      running && (limits.worst ?? .normal) < .power ? .secondaryLabelColor : .labelColor
    limitsValue.isHidden = detail.isEmpty

    // The GPU card's header has one remark to make at most. While the CPU card is closed
    // it is the CPU's news, throttling before anything else; failing that, why the
    // integrated GPU is missing from two of the rows.
    var remark: (text: String, tip: String?, warns: Bool)?
    if !showsCPU {
      switch state {
      case .running where (limits.worst ?? .normal) >= .power:
        remark = (
          "CPU " + limits.headline.prefix(1).lowercased() + limits.headline.dropFirst(),
          limits.names.joined(separator: ", "),
          limits.warns
        )
      case .prompting: remark = ("Waiting for administrator password…", fallbackText, false)
      case .waiting: remark = ("Waiting for first sample…", nil, false)
      case .failed(let text):
        remark = (hasSamples ? "CPU reading problem" : "No CPU readings yet", text, false)
      case .stopped(let text): remark = ("CPU monitoring stopped", text, false)
      case .idle(cancelled: true):
        remark = (
          "Monitoring was not started",
          "The password prompt was cancelled or failed.",
          false
        )
      default: break
      }
    }
    let integrated = gpus.indices.filter({ selectedGPU == nil || $0 == selectedGPU }).map({
      gpus[$0]
    }).first(where: { $0.integrated })
    if remark == nil, !running, let gpu = integrated {
      remark = (
        triesKernel
          ? "\(gpu.short) power needs monitoring" : "\(gpu.short) power and clock need monitoring",
        nil,
        false
      )
    }
    // The integrated GPU's own limit reasons, which the processor gives beside the cores'.
    if remark == nil, running, !limits.gpu.isEmpty, let gpu = integrated {
      remark = (
        "\(gpu.short) GPU limited: " + limits.gpu.joined(separator: ", "),
        "What the processor reports as limiting the \(gpu.short) GPU's clock.",
        false
      )
    }
    let warns = remark?.warns == true
    gpuMark.image = warns ? NSImage.symbol("exclamationmark.triangle.fill", size: 12) : nil
    gpuMark.isHidden = gpuMark.image == nil
    gpuRemark.stringValue = remark?.text ?? ""
    gpuRemark.font = .systemFont(ofSize: 11, weight: warns ? .medium : .regular)
    gpuRemark.textColor = warns ? .labelColor : .secondaryLabelColor
    gpuRemark.toolTip = remark?.tip
    gpuRemark.isHidden = remark == nil
    // Monitoring can be started from here while the CPU card, where it otherwise is, is closed.
    gpuStartLink.isHidden = !(showsCPU == false && state.canStart && remark != nil)
    gpuStartLink.setText(hasSamples ? "Restart…" : "Start Monitoring…")
    describeGPURows()
  }
}
