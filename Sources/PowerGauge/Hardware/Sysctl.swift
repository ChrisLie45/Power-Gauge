import Foundation

/// Reading sysctl values, which macOS gives any process.
enum Sysctl {
  /// A text value, or nil if the system does not have it.
  static func string(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var chars = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &chars, &size, nil, 0) == 0 else { return nil }
    return String(cString: chars)
  }

  /// A whole number, or nil if the system does not have it.
  static func int(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
  }
}
