import Foundation

/// Reads the kernel's statistics every 10 ms, on a queue of its own, until stopped, and hands
/// each second's sample to the main thread as one from powermetrics would be.
///
/// A second's sample comes from the readings a second apart. The readings in between give the
/// lowest and highest clock the CPUs worked at (`Sample.burstMHz`): turbo boosts last
/// milliseconds, so a second's average hides them.
///
/// A call returns what the previous call had the CPUs store (see `KernelStats`), so each reading
/// lags its call by 10 ms, and the first, which may be from any time before, is dropped.
///
/// A second whose readings can't be trusted is dropped: the first after the Mac wakes may be one,
/// as sleep can reset the processor's counters. After three in a row, or three calls in a row that
/// fail, the sampler gives up and says why.
///
/// EXPERIMENTAL: see `KernelStats`.
final class KernelSampler {
  var onSample: ((Sample, _ utilization: Double?, CPUPowerStatus?) -> Void)?
  var onGiveUp: ((String) -> Void)?
  static let giveUpAfter = 3
  static let interval: TimeInterval = 1
  /// How often the CPUs' clocks are read for their bursts.
  static let burstInterval = DispatchTimeInterval.milliseconds(10)
  private static let leeway = DispatchTimeInterval.milliseconds(2)
  private let read: () -> KernelStats.Reading?
  private let queue = DispatchQueue(label: "PowerGauge.KernelSampler")
  private var timer: DispatchSourceTimer?

  /// - Parameter read: One call of the kernel's (`KernelStats.Reader.call`).
  init(read: @escaping () -> KernelStats.Reading?) { self.read = read }

  func start() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let read = self.read
    let secondNanoseconds = UInt64(KernelSampler.interval * Units.nanosecondsPerSecond)
    var primed = false
    var previous: KernelStats.Reading?
    var secondStart: (reading: KernelStats.Reading, ticks: CPUTicks?)?
    var burst: ClosedRange<Double>?
    var failedCalls = 0
    var badSeconds = 0
    // Stops, and says why on the main thread. The timer can be cancelled from any thread.
    let giveUp = { [weak self, weak timer] (reason: String) in
      timer?.cancel()
      DispatchQueue.main.async { self?.onGiveUp?(reason) }
    }
    timer.setEventHandler { [weak self] in
      guard let now = read() else {
        failedCalls += 1
        if failedCalls >= KernelSampler.giveUpAfter {
          giveUp("the kernel's call failed \(failedCalls) times in a row")
        }
        return
      }
      failedCalls = 0
      guard primed else {
        primed = true
        return
      }
      if let before = previous {
        for mhz in KernelStats.activeMHz(from: before, to: now) {
          burst = burst.map { min($0.lowerBound, mhz)...max($0.upperBound, mhz) } ?? mhz...mhz
        }
      }
      previous = now
      guard let start = secondStart else {
        secondStart = (now, CPUTicks.read())
        burst = nil
        return
      }
      guard now.nanoseconds &- start.reading.nanoseconds >= secondNanoseconds else { return }
      let ticks = CPUTicks.read()
      defer {
        secondStart = (now, ticks)
        burst = nil
      }
      switch KernelStats.sample(from: start.reading, to: now) {
      case .success(var sample):
        badSeconds = 0
        let util = ticks?.utilization(since: start.ticks)
        sample.burstMHz = burst
        sample.memory = ThisMac.memoryInUse()
        sample.arrived = ProcessInfo.processInfo.systemUptime
        let power = CPUPowerStatus.read()
        DispatchQueue.main.async { self?.onSample?(sample, util, power) }
      case .failure(let problem):
        badSeconds += 1
        if badSeconds >= KernelSampler.giveUpAfter { giveUp(problem.reason) }
      }
    }
    timer.schedule(
      deadline: .now(),
      repeating: KernelSampler.burstInterval,
      leeway: KernelSampler.leeway
    )
    self.timer = timer
    timer.resume()
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }
}
