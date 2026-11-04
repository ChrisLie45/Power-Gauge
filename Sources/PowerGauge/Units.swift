/// Unit conversions, so that a figure read in one unit and shown in another says how they relate.
enum Units {
  static let hertzPerMHz = 1e6
  static let mhzPerGHz = 1000.0
  static let nanosecondsPerSecond = 1e9
  static let microsecondsPerSecond = 1e6
  static let secondsPerMinute = 60
  /// 2^20.
  static let bytesPerMB = 1_048_576.0
  /// 2^30, as macOS counts memory.
  static let bytesPerGB = 1_073_741_824.0
  static let mbPerGB = 1024.0
}
