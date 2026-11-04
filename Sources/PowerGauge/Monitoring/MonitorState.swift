/// The state of monitoring, as the window and the menu bar item show it.
enum MonitorState: Equatable {
  /// Not started; `cancelled` once the password prompt has been turned down.
  case idle(cancelled: Bool)
  /// The password prompt is up.
  case prompting
  /// The kernel or powermetrics is being read and has yet to give a sample.
  case waiting
  /// No usable readings, though they may still come.
  case failed(String)
  /// Sampling, with whatever is limiting the CPU.
  case running(CPULimits)
  /// Monitoring has ended: nil when it was asked to stop, else why.
  case stopped(String?)

  /// Whether monitoring can be started from here, which it can again once it has stopped.
  var canStart: Bool {
    switch self {
    case .idle, .stopped: return true
    default: return false
    }
  }
}
