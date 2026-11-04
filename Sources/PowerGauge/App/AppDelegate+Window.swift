// The window: the dashboard under a compact toolbar, and the window's size for each set of
// open cards, kept from one launch to the next.

import Cocoa

extension AppDelegate: NSWindowDelegate, NSToolbarDelegate {
  private static let panesID = NSToolbarItem.Identifier("panes")
  static let recordingID = NSToolbarItem.Identifier("recording")
  /// The content's least height; its least width is the dashboard's, for the cards open.
  static let minimumContentHeight: CGFloat = 340
  private static let cardMoveDuration: TimeInterval = 0.25

  /// The window: a compact toolbar over the dashboard, holding the picker of which cards are open,
  /// and while recording a button to stop it.
  ///
  /// The toolbar is the window's one layer of controls, so it is where macOS 26 puts its glass;
  /// nothing here asks for any, and on earlier systems it is an ordinary toolbar.
  func buildWindow() {
    // Start Monitoring is the CPU card's button, the window's default one, and in the
    // Monitor menu (Cmd-R). Once the card has plotted samples, or while it is closed, a
    // link in a card's header starts it again.
    dashboard.startButton.target = self
    dashboard.startButton.action = #selector(startOrStop)
    dashboard.startButton.keyEquivalent = "\r"
    for link in [dashboard.cpuStartLink, dashboard.gpuStartLink] {
      link.target = self
      link.action = #selector(start)
    }
    sourceChanged()

    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Dashboard.windowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = dashboard
    window.isReleasedWhenClosed = false  // it is kept, to be shown again
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.toolbarStyle = .unifiedCompact
    // The title would only crowd the picker, so it is left to the Window menu and Mission Control.
    window.titleVisibility = .hidden
    window.setContentSize(Dashboard.windowSize)
    // The rows' minimum heights set the real floor, which depends on their header lines.
    window.contentMinSize = NSSize(
      width: dashboard.minimumWidth,
      height: AppDelegate.minimumContentHeight
    )
    window.center()
    dashboard.onViewChange = { [weak self] in self?.viewChanged() }
    nameWindow()
  }

  private func nameWindow() {
    window.title =
      dashboard.showsCPU && dashboard.showsGPU ? "CPU and GPU" : dashboard.showsGPU ? "GPU" : "CPU"
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [AppDelegate.panesID, .flexibleSpace, AppDelegate.recordingID]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [AppDelegate.panesID]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: id)
    switch id {
    case AppDelegate.panesID:
      item.view = dashboard.viewPicker
      item.label = "Panels"
      item.visibilityPriority = .high
    case AppDelegate.recordingID:
      item.image = AppDelegate.recordingMark
      item.title = "Recording"
      item.label = "Recording"
      item.isBordered = true
      item.target = self
      item.action = #selector(toggleRecording)
      item.toolTip = recorder.map { "Recording to \($0.url.lastPathComponent). Click to stop." }
      item.visibilityPriority = .high
    default:
      return nil
    }
    return item
  }

  /// A red record mark.
  ///
  /// Toolbar images are drawn in one colour unless they are not templates, so this one draws the
  /// symbol and colours it itself, again for each appearance.
  private static let recordingMark: NSImage? = {
    guard let mark = NSImage.symbol("record.circle.fill", size: 13) else { return nil }
    let image = NSImage(size: mark.size, flipped: false) { rect in
      mark.draw(in: rect)
      NSColor.systemRed.set()
      rect.fill(using: .sourceAtop)
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = "Recording"
    return image
  }()

  /// Which cards are open, as the name the window's frame for them is kept under.
  private var cardsKey: String {
    dashboard.showsCPU && dashboard.showsGPU ? "both" : dashboard.showsGPU ? "gpu" : "cpu"
  }

  /// Opens the window as it was left: the same cards, GPU, history and frequency plot.
  ///
  /// The cards are opened before the window has its frame, so with nothing to animate.
  func restoreViewOptions() {
    let defaults = UserDefaults.standard
    if Dashboard.historyChoices.contains(defaults.integer(forKey: Key.history)) {
      dashboard.historyMinutes = defaults.integer(forKey: Key.history)
    }
    dashboard.showsPerCoreFrequencies = defaults.bool(forKey: Key.perCore)
    if let short = defaults.string(forKey: Key.gpu),
      let index = dashboard.gpus.firstIndex(where: { $0.short == short })
    {
      dashboard.select(gpu: index)
    }
    let cards = defaults.string(forKey: Key.cards)
    let follow = dashboard.onViewChange
    dashboard.onViewChange = nil
    dashboard.open(cpu: cards != "gpu", gpu: cards == "gpu" || cards == "both")
    dashboard.onViewChange = follow
    window.contentMinSize = NSSize(
      width: dashboard.minimumWidth,
      height: AppDelegate.minimumContentHeight
    )
    nameWindow()
  }

  /// Takes the frames kept from earlier launches, and opens the window at the frame for the
  /// cards now open if that is still on a screen.
  func restoreFrames() {
    for key in ["cpu", "gpu", "both"] {
      if let text = UserDefaults.standard.string(forKey: "WindowFrame." + key) {
        let frame = NSRectFromString(text)
        if frame.width > 0, frame.height > 0 { frames[key] = frame }
      }
    }
    if var frame = frames[cardsKey],
      NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) })
    {
      frame.size = fitted(frame.size)
      window.setFrame(frame, display: false)
    }
  }

  /// A kept window size, made at least as big as the cards now open need, in case their
  /// minimum has grown since it was kept.
  private func fitted(_ size: NSSize) -> NSSize {
    let least = window.frameRect(
      forContentRect: NSRect(
        x: 0,
        y: 0,
        width: dashboard.minimumWidth,
        height: AppDelegate.minimumContentHeight
      )
    ).size
    return NSSize(width: max(size.width, least.width), height: max(size.height, least.height))
  }

  /// Keeps the window's frame for the cards now open whenever the user resizes or moves it, and
  /// once a change of cards has finished moving it, though not a full-screen one.
  ///
  /// Nothing is kept from the moment the cards change until they have finished moving: not the
  /// frames the window passes through, which a change cut short by another, as when a card's button
  /// is clicked again and again, would leave as a half-way size, nor the few points the window may
  /// grow by to fit the new cards' rows before it starts to move, which would be the old cards'
  /// frame kept for the new ones.
  private func rememberFrame() {
    guard !fullScreen, dashboard.moveGeneration == nil else { return }
    frames[cardsKey] = window.frame
    if persists {
      UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "WindowFrame." + cardsKey)
    }
  }

  func windowDidResize(_ notification: Notification) { rememberFrame() }

  func windowDidMove(_ notification: Notification) { rememberFrame() }

  func windowWillEnterFullScreen(_ notification: Notification) { fullScreen = true }

  func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreen = false }

  func windowDidExitFullScreen(_ notification: Notification) { fullScreen = false }

  /// Fits the window to the cards now open.
  ///
  /// Each set of open cards has its own window size. Going back to one gives the window the size it
  /// was last left at; the first time, the window grows or shrinks by a card, so each card keeps
  /// its width. The window keeps its top-left corner, where the picker is, unless that would put it
  /// off its screen; a full-screen window keeps its size and the cards share it. The window and the
  /// cards move in one animation, none with Reduce Motion on.
  private func viewChanged() {
    nameWindow()
    if persists { UserDefaults.standard.set(cardsKey, forKey: Key.cards) }
    defer { startGPUReadings() }
    var frame = window.frame
    if !fullScreen {
      // A change made while the last one is still moving the window starts from where
      // that one was taking it.
      let current = heading ?? window.frame
      let both = dashboard.showsCPU && dashboard.showsGPU
      var size = frames[cardsKey]?.size ?? current.size
      if frames[cardsKey] == nil {
        size.width = both ? current.width * 2 - Dashboard.gap : (current.width + Dashboard.gap) / 2
      }
      size = fitted(size)
      var corner = NSPoint(x: current.minX, y: current.maxY)
      if let nudge = nudge, abs(nudge.placed.x - corner.x) < 1, abs(nudge.placed.y - corner.y) < 1 {
        corner = nudge.wanted
      }
      frame = NSRect(x: corner.x, y: corner.y - size.height, width: size.width, height: size.height)
      if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
      }
      let placed = NSPoint(x: frame.minX, y: frame.maxY)
      nudge = placed == corner ? nil : (corner, placed)
    }
    // While it moves the window may be as narrow as either the old or the new cards allow.
    window.contentMinSize = NSSize(
      width: min(window.contentMinSize.width, dashboard.minimumWidth),
      height: AppDelegate.minimumContentHeight
    )
    dashboard.prepareMove(toWidth: window.contentRect(forFrameRect: frame).width)
    let generation = dashboard.moveGeneration
    let target = frame
    // While an earlier change may still be moving the window, it is sent to the new target
    // even if it is there already, as it may be when the earlier change has yet to move it:
    // otherwise the earlier animation would carry on and take it to the earlier target.
    let earlierMoving = heading != nil
    heading = target
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration =
          NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
          ? 0 : AppDelegate.cardMoveDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if target != window.frame || earlierMoving {
          window.animator().setFrame(target, display: true)
        }
        dashboard.animateMove()
      },
      completionHandler: { [weak self] in
        guard let self = self, self.dashboard.moveGeneration == generation else { return }
        self.heading = nil
        self.dashboard.endMove(generation: generation)
        self.window.contentMinSize = NSSize(
          width: self.dashboard.minimumWidth,
          height: AppDelegate.minimumContentHeight
        )
        self.rememberFrame()
      }
    )
  }
}
