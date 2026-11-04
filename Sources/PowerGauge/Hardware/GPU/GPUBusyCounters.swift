import Foundation

/// The counters of time busy that the Intel and AMD drivers keep for IOReport, the library
/// powermetrics reads its GPU figures through: "Overall GPU Busy" and "Overall GPU total time",
/// which only ever count up.
///
/// A GPU's utilisation is how much the first went up by between two samples over how much the
/// second did, so it is the true share of that time, whoever else reads them and however often.
///
/// IOReport is a private library, so it is found when the app starts, and with any part of it
/// missing there are no counters and the drivers' own percentages stand in. A sample costs
/// about 0.2 ms. It is used from the main thread only.
///
/// A GPU kept busy all the time reads about 90 %, since the driver does not count the moments
/// between one piece of work and the next. The count covers every engine, copies and display
/// work included, so a GPU that drives the screen is somewhat busy with nothing else running.
final class GPUBusyCounters {
  static let shared = GPUBusyCounters()

  private typealias CopyChannels =
    @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?

  private typealias CreateSubscription =
    @convention(c) (
      UnsafeMutableRawPointer?,
      CFMutableDictionary,
      UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
      UInt64,
      CFTypeRef?
    ) -> OpaquePointer?

  private typealias CreateSamples =
    @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?

  private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

  private static let busy = "Overall GPU Busy"
  private static let total = "Overall GPU total time"

  private let createSamples: CreateSamples
  private let integerValue: IntegerValue
  /// Kept for the life of the app.
  private let subscription: OpaquePointer
  private let channels: CFMutableDictionary
  /// The registry IDs of the drivers whose counters are read.
  private let drivers: Set<UInt64>
  private var last: [UInt64: (busy: Int64, total: Int64)] = [:]

  private init?() {
    guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
      let copy = dlsym(library, "IOReportCopyChannelsInGroup"),
      let subscribe = dlsym(library, "IOReportCreateSubscription"),
      let samples = dlsym(library, "IOReportCreateSamples"),
      let integer = dlsym(library, "IOReportSimpleGetIntegerValue"),
      let group = unsafeBitCast(copy, to: CopyChannels.self)(
        "Internal Statistics" as CFString,
        nil,
        0,
        0,
        0
      )?.takeRetainedValue() as NSDictionary?,
      let all = group["IOReportChannels"] as? [[String: Any]]
    else { return nil }
    // Only the two counters are subscribed to, out of about 70 per GPU.
    let wanted = all.filter {
      let name = ($0["LegendChannel"] as? [Any])?.last as? String
      return name == GPUBusyCounters.busy || name == GPUBusyCounters.total
    }
    let drivers = Set(wanted.compactMap { ($0["DriverID"] as? NSNumber)?.uint64Value })
    guard !drivers.isEmpty else { return nil }
    let request = NSMutableDictionary(dictionary: group)
    request["IOReportChannels"] = wanted
    var subscribed: Unmanaged<CFMutableDictionary>?
    guard
      let subscription = unsafeBitCast(subscribe, to: CreateSubscription.self)(
        nil,
        request as CFMutableDictionary,
        &subscribed,
        0,
        nil
      ),
      let channels = subscribed?.takeRetainedValue()
    else { return nil }
    self.createSamples = unsafeBitCast(samples, to: CreateSamples.self)
    self.integerValue = unsafeBitCast(integer, to: IntegerValue.self)
    self.subscription = subscription
    self.channels = channels
    self.drivers = drivers
  }

  /// Whether there are counters for the driver with this registry ID.
  func covers(_ registryID: UInt64) -> Bool { drivers.contains(registryID) }

  /// Each GPU's share of the time busy since the last sample, as a percentage, by its driver's
  /// registry ID.
  ///
  /// A GPU is left out of the first sample, and of any in which its counters went backwards or did
  /// not move, as they may when its driver restarts or it powers down.
  func sample() -> [UInt64: Double] {
    guard
      let samples = createSamples(subscription, channels, nil)?.takeRetainedValue()
        as NSDictionary?,
      let items = samples["IOReportChannels"] as? [NSDictionary]
    else { return [:] }
    var now: [UInt64: (busy: Int64, total: Int64)] = [:]
    for item in items {
      guard let id = (item["DriverID"] as? NSNumber)?.uint64Value,
        let name = (item["LegendChannel"] as? [Any])?.last as? String
      else { continue }
      let value = integerValue(item as CFDictionary, 0)
      var counts = now[id] ?? (0, 0)
      if name == GPUBusyCounters.busy {
        counts.busy = value
      } else if name == GPUBusyCounters.total {
        counts.total = value
      }
      now[id] = counts
    }
    var shares: [UInt64: Double] = [:]
    for (id, counts) in now {
      guard let before = last[id] else { continue }
      let busy = counts.busy - before.busy
      let total = counts.total - before.total
      if total > 0, busy >= 0 { shares[id] = min(100, 100 * Double(busy) / Double(total)) }
    }
    last = now
    return shares
  }
}
