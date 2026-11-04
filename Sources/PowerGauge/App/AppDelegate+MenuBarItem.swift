// The menu bar item: the fastest core's frequency while monitoring runs, and a menu with the
// latest readings and the commands that matter without the window.

import Cocoa

extension AppDelegate: NSMenuDelegate {
  /// The space between the warning mark and the reading.
  private static let statusMarkGap: CGFloat = 3

  /// Throttling by heat or by macOS gets a warning mark; a power limit doesn't, since it is
  /// expected under heavy load.
  func updateStatusItem() {
    refreshOpenStatusMenu()
    guard let button = statusItem?.button else { return }
    var limits: CPULimits?
    if case .running(let reported) = dashboard.state { limits = reported }
    let peak = latest?.sample.peakMHz
    let reading =
      limits != nil
      ? peak.map { String(format: "%.1f GHz", $0 / Units.mhzPerGHz) } ?? "CPU —" : "CPU —"
    let warns = limits?.warns == true
    button.image = AppDelegate.statusImage(
      reading,
      mark: warns ? NSImage.symbol("exclamationmark.triangle.fill", size: 11) : nil
    )
    button.imagePosition = .imageOnly
    button.toolTip = limits.map { "Power Gauge: " + $0.summary } ?? "Power Gauge"
  }

  /// The menu bar item's reading, after the warning mark if there is one, as a template image
  /// whose middle is the digits' middle.
  ///
  /// AppKit centres a status item's image in the menu bar, as it does an icon's, but places a
  /// title by its own reckoning, which left the reading off the bar's middle. The digits are all
  /// of one width, as in the dashboard, so that the item keeps its width from one reading to the
  /// next instead of shifting itself, and the menu bar's other items, sideways.
  static func statusImage(_ reading: String, mark: NSImage?) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(
      ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
      weight: .regular
    )
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let readingSize = (reading as NSString).size(withAttributes: attributes)
    let markSize = mark?.size ?? .zero
    let readingX = mark == nil ? 0 : markSize.width + statusMarkGap
    let size = NSSize(
      width: ceil(readingX + readingSize.width),
      height: ceil(max(readingSize.height, markSize.height))
    )
    let image = NSImage(size: size, flipped: false) { rect in
      // On the display's pixels, so that neither is blurred across two rows.
      let scale = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 1
      func snapped(_ y: CGFloat) -> CGFloat { (y * scale).rounded() / scale }
      mark?.draw(
        in: NSRect(
          x: 0,
          y: snapped(rect.midY - markSize.height / 2),
          width: markSize.width,
          height: markSize.height
        )
      )
      // Digits stand on the baseline and reach the cap height.
      let baseline = snapped(rect.midY - font.capHeight / 2)
      (reading as NSString).draw(
        at: NSPoint(x: readingX, y: baseline + font.descender),
        withAttributes: attributes
      )
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = mark == nil ? reading : "Warning, " + reading
    return image
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === statusMenu else { return }
    buildStatusMenu()
  }

  func menuWillOpen(_ menu: NSMenu) { if menu === statusMenu { statusMenuOpen = true } }

  func menuDidClose(_ menu: NSMenu) { if menu === statusMenu { statusMenuOpen = false } }

  /// Brings the menu bar menu up to date while it is open.
  ///
  /// AppKit asks for the menu's items only as it opens, so while it stays open each new reading
  /// sets its lines' titles in place, which leaves the highlighted command as it is. A change in
  /// how many lines there are, or in which commands apply, builds the menu afresh.
  private func refreshOpenStatusMenu() {
    guard statusMenuOpen else { return }
    let lines = statusLines()
    guard lines.count == statusLineItems.count,
      statusCommands().map({ $0.title }) == statusCommandTitles
    else {
      buildStatusMenu()
      return
    }
    for (item, line) in zip(statusLineItems, lines) where item.title != line { item.title = line }
  }

  private func buildStatusMenu() {
    let menu = statusMenu
    menu.removeAllItems()
    // Greyed out here, not left to AppKit: it greys out items with no action only as the menu
    // opens, so lines built afresh while it is open would otherwise look as if they could be
    // chosen.
    statusLineItems = statusLines().map { line in
      let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
      item.isEnabled = false
      return item
    }
    statusLineItems.forEach { menu.addItem($0) }
    menu.addItem(.separator())
    let commands = statusCommands()
    for (title, action) in commands {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
    statusCommandTitles = commands.map { $0.title }
    menu.addItem(.separator())
    let quit = NSMenuItem(
      title: "Quit Power Gauge",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: ""
    )
    quit.target = NSApp
    menu.addItem(quit)
  }

  /// The menu's lines about monitoring: the latest readings, or why there are none.
  private func statusLines() -> [String] {
    var lines: [String] = []
    switch dashboard.state {
    case .running(let limits):
      if let sample = latest?.sample, let average = sample.systemMHz {
        let fastest = sample.peakMHz ?? average
        lines.append(
          String(
            format: "Fastest core %.2f GHz, average %.2f GHz",
            fastest / Units.mhzPerGHz,
            average / Units.mhzPerGHz
          )
        )
        var heat: [String] = []
        if let celsius = sample.cpuTempC { heat.append(String(format: "CPU die %.0f °C", celsius)) }
        if let fan = sample.fanRPM { heat.append(String(format: "fan %.0f rpm", fan)) }
        if !heat.isEmpty { lines.append(heat.joined(separator: ", ")) }
        if let watts = sample.packageWatts { lines.append(String(format: "Package %.1f W", watts)) }
      }
      lines.append(limits.summary)
      if !limits.gpu.isEmpty {
        lines.append("Intel GPU limited: " + limits.gpu.joined(separator: ", "))
      }
    case .prompting: lines.append("Waiting for administrator password…")
    case .waiting: lines.append("Waiting for first sample…")
    case .failed(let text): lines.append(text)
    case .stopped(let text): lines.append(text ?? "Monitoring stopped")
    case .idle: lines.append("Not monitoring")
    }
    if let recorder = recorder { lines.append("Recording to \(recorder.url.lastPathComponent)") }
    return lines
  }

  /// The commands that apply now, besides Quit.
  private func statusCommands() -> [(title: String, action: Selector)] {
    var commands: [(title: String, action: Selector)] = [("Show Window", #selector(showWindow))]
    if monitor.canStop {
      commands.append(("Stop Monitoring", #selector(stopMonitoring)))
    } else if dashboard.state.canStart && !monitor.isActive {
      commands.append(("Start Monitoring…", #selector(start)))
    }
    if recorder != nil { commands.append(("Stop Recording", #selector(toggleRecording))) }
    return commands
  }
}
