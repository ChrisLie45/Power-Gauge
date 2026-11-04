// The menu bar's menus, which of their commands can be chosen when, and the View menu's
// commands.

import Cocoa

extension AppDelegate: NSMenuItemValidation {
  /// The tags of the CPU Readings menu's items.
  enum SourceTag { static let powermetrics = 0, kernel = 1 }
  /// The tags of the GPU Utilization menu's items.
  enum UtilizationTag { static let busyTime = 0, driver = 1 }

  /// The menu bar: the standard menus as far as they apply.
  ///
  /// Monitor stands where File would be, since the app handles no files of its own.
  func buildMenu() {
    let name = "Power Gauge"
    func item(
      _ title: String,
      _ action: Selector?,
      _ key: String = "",
      modifiers: NSEvent.ModifierFlags = .command,
      tag: Int = 0
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.tag = tag
      return item
    }
    let bar = NSMenu()
    @discardableResult func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
      let menu = NSMenu(title: title)
      items.forEach { menu.addItem($0) }
      let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      top.submenu = menu
      bar.addItem(top)
      return menu
    }
    add(
      name,
      [
        item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        .separator(),
        item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
        item(
          "Hide Others",
          #selector(NSApplication.hideOtherApplications(_:)),
          "h",
          modifiers: [.command, .option]
        ),
        item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
      ]
    )
    let source = NSMenuItem(title: "CPU Readings", action: nil, keyEquivalent: "")
    source.submenu = NSMenu(title: "CPU Readings")
    source.submenu?.addItem(
      item("powermetrics (Needs Password)", #selector(pickSource), tag: SourceTag.powermetrics)
    )
    source.submenu?.addItem(
      item("Kernel, No Password (Experimental)…", #selector(pickSource), tag: SourceTag.kernel)
    )
    let busyTime = item(
      "Busy-Time Counters",
      #selector(pickUtilization),
      tag: UtilizationTag.busyTime
    )
    busyTime.toolTip =
      "The share of each second each GPU was busy, from the counters its driver keeps. The "
      + "Intel GPU's is its driver's figure at its current clock, since its counter can stick "
      + "at 100%."
    let driver = item(
      "Drivers' Device Utilization %",
      #selector(pickUtilization),
      tag: UtilizationTag.driver
    )
    driver.toolTip =
      "Each driver's own figure, as other GPU monitors show it. AMD's reads about 76% for a GPU "
      + "busy all the time, and Intel's is scaled down by its clock. A driver works it out since "
      + "it was last read, so another GPU monitor running at the same time disturbs it."
    let utilization = NSMenuItem(title: "GPU Utilization", action: nil, keyEquivalent: "")
    utilization.submenu = NSMenu(title: "GPU Utilization")
    utilization.submenu?.addItem(driver)
    utilization.submenu?.addItem(busyTime)
    add(
      "Monitor",
      [
        item("Start Monitoring…", #selector(start), "r"),
        item("Stop Monitoring", #selector(stopMonitoring), "."),
        .separator(),
        source,
        utilization,
        .separator(),
        item("Record to CSV…", #selector(toggleRecording), "r", modifiers: [.command, .shift]),
        .separator(),
        item("Close", #selector(NSWindow.performClose(_:)), "w"),
      ]
    )
    // For the text that can be selected: the limits, and an error in the blank state.
    add(
      "Edit",
      [
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
      ]
    )
    let history = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
    history.submenu = NSMenu(title: "History")
    for minutes in Dashboard.historyChoices {
      history.submenu?.addItem(item("\(minutes) Minutes", #selector(pickHistory), tag: minutes))
    }
    var view = [
      item("CPU", #selector(toggleCPU), "1"),
      item("GPU", #selector(toggleGPU), "2"),
      .separator(),
      item("Per-Core Frequencies", #selector(togglePerCore), "3"),
      history,
    ]
    if dashboard.gpus.count > 1 {
      // As in the GPU card's pop-up: an item's tag is its GPU's place plus one, and the first has
      // none.
      view += [
        .separator(),
        item(Dashboard.allGPUsTitle(count: dashboard.gpus.count), #selector(pickGPU)),
      ]
      view += dashboard.gpus.enumerated().map {
        item($1.name, #selector(pickGPU), tag: Dashboard.tag(forGPU: $0))
      }
    }
    add("View", view)
    NSApp.windowsMenu = add(
      "Window",
      [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Zoom", #selector(NSWindow.performZoom(_:))),
      ]
    )
    NSApp.helpMenu = add("Help", [item("Save Diagnostic Report…", #selector(saveReport))])
    NSApp.mainMenu = bar
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(start):
      return dashboard.state.canStart && !monitor.isActive
    case #selector(stopMonitoring):
      return monitor.canStop
    case #selector(pickSource):
      item.state = (item.tag == SourceTag.kernel) == monitor.readsKernel ? .on : .off
      item.toolTip =
        item.tag == SourceTag.kernel
        ? monitor.kernelProblem.map {
          "The kernel readings failed in this run, so powermetrics is used until Power "
            + "Gauge is started again or this is chosen again: \($0)."
        } : nil
      return true
    case #selector(pickUtilization):
      let driver = dashboard.gpuUtilizationSource == .driver
      item.state = (item.tag == UtilizationTag.driver) == driver ? .on : .off
      return !dashboard.gpus.isEmpty
    case #selector(toggleRecording):
      item.title = recorder == nil ? "Record to CSV…" : "Stop Recording"
      return true
    case #selector(toggleCPU):
      item.state = dashboard.showsCPU ? .on : .off
      return dashboard.showsGPU  // one card is always open, so the only one cannot be closed
    case #selector(toggleGPU):
      item.state = dashboard.showsGPU ? .on : .off
      return !dashboard.gpus.isEmpty
    case #selector(togglePerCore):
      item.state = dashboard.showsPerCoreFrequencies ? .on : .off
      return true
    case #selector(pickHistory):
      item.state = item.tag == dashboard.historyMinutes ? .on : .off
      return true
    case #selector(pickGPU):
      item.state = dashboard.selectedGPU == Dashboard.gpu(forTag: item.tag) ? .on : .off
      return dashboard.showsGPU
    default:
      return true
    }
  }

  @objc private func toggleCPU() {
    dashboard.open(cpu: !dashboard.showsCPU, gpu: dashboard.showsGPU)
  }

  @objc private func toggleGPU() {
    dashboard.open(cpu: dashboard.showsCPU, gpu: !dashboard.showsGPU)
  }

  @objc private func pickGPU(_ sender: NSMenuItem) {
    dashboard.select(gpu: Dashboard.gpu(forTag: sender.tag))
  }

  @objc private func togglePerCore() {
    dashboard.showsPerCoreFrequencies.toggle()
    if persists {
      UserDefaults.standard.set(dashboard.showsPerCoreFrequencies, forKey: Key.perCore)
    }
  }

  /// Takes the GPUs' utilisation from their drivers' own figures (tag 1) or their busy-time
  /// counters (tag 0), from the next reading on.
  ///
  /// The plot keeps what it has, so the two can be compared where it changes.
  @objc func pickUtilization(_ sender: NSMenuItem) {
    let busyTime = sender.tag == UtilizationTag.busyTime
    dashboard.gpuUtilizationSource = busyTime ? .busyTime : .driver
    if persists { UserDefaults.standard.set(busyTime, forKey: Key.busyTimeUtilization) }
  }

  @objc private func pickHistory(_ sender: NSMenuItem) {
    dashboard.historyMinutes = sender.tag
    if persists { UserDefaults.standard.set(sender.tag, forKey: Key.history) }
  }

  func rememberGPU() {
    let short = dashboard.selectedGPU.map { dashboard.gpus[$0].short }
    if persists { UserDefaults.standard.set(short, forKey: Key.gpu) }
  }
}
