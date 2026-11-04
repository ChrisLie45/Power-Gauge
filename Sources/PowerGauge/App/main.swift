// Power Gauge: a Power Gadget-style GUI over `powermetrics` for watching turbo and thermal
// throttling on Intel Macs. powermetrics needs root, so one long-running copy is started
// through the standard macOS admin prompt and streams plist samples to this app over a named
// pipe; it is stopped automatically when this app quits.

import Cocoa

Usage.printIfAsked()
TestModes.run()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(AppDelegate.prints ? .prohibited : .regular)
app.run()
