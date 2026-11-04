// The readings the cards plot: the CPU's samples while monitoring runs, and every GPU's.

import Cocoa

extension Dashboard {
  /// A wait this long or longer for the next CPU sample shows as a gap in the plots.
  static let gapAfter: TimeInterval = 2.5
  /// Turbo is active when the fastest core is over the base clock by more than 2 %.
  static let turboAbove = 1.02
  /// How long the integrated GPU's power and clock from the CPU's readings stand for it.
  static let integratedReadingsLast: TimeInterval = 3

  /// Plots a CPU sample in the CPU card's rows, and shows what is limiting the CPU.
  ///
  /// - Parameters:
  ///   - sample: The sample to plot.
  ///   - cpuUtilization: The CPUs' utilization in that second, as a percentage, if known.
  ///   - powerStatus: macOS's limits on the CPU in that second, if they could be read.
  /// - Returns: The fastest core's frequency in MHz, or nil if the sample had no frequency data.
  @discardableResult
  func apply(
    _ sample: Sample,
    utilization cpuUtilization: Double?,
    power powerStatus: CPUPowerStatus?
  ) -> Double? {
    guard let average = sample.systemMHz else {
      show(state: .failed("Got powermetrics output but found no frequency data."))
      return nil
    }
    let limits = CPULimits(sample: sample, power: powerStatus, layout: limitLayout)
    readingsSource = sample.source
    // Samples come a second apart, so the seconds without one while monitoring was stopped
    // are empty slots, and the plots keep to time with a gap. A sample that is merely late,
    // as one can be with the Mac busy, makes no gap: only a wait of 2.5 s or more does. The
    // clock is uptime, which stands still while the Mac sleeps, as the GPU readings do.
    if let now = sample.arrived {
      if let last = lastArrival, now - last >= Dashboard.gapAfter {
        let missing = min(ChartPanel.storage, Int((now - last).rounded()) - 1)
        cpuPanels.forEach { panel in (0..<missing).forEach { _ in panel.push([]) } }
      }
      lastArrival = now
    }
    let peak = sample.peakMHz ?? average
    let low = sample.lowMHz ?? average
    power.push([sample.packageWatts, sample.cpuWatts, sample.gpuWatts, sample.dramWatts])
    integratedGPU = (Date(), sample.gpuMHz, sample.gpuWatts)
    frequency.push(
      [peak / Units.mhzPerGHz, average / Units.mhzPerGHz, low / Units.mhzPerGHz],
      band: limits.band,
      each: sample.coreMHz.map { $0 / Units.mhzPerGHz }
    )
    let cores = sample.coreTempsC
    temperature.push([
      sample.cpuTempC,
      cores.max(),
      cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count),
      cores.min(),
    ])
    utilization.push([cpuUtilization])
    memory.push([sample.memory?.used, sample.memory?.compressed, sample.memory?.swap ?? nil])

    // Notes are in plain text unless they report something wrong, which is in red.
    let turbo = machine.baseMHz.map { peak > $0 * Dashboard.turboAbove }
    // The ceiling is the kernel's: the highest frequency its power management now allows,
    // which is macOS's speed limit as a frequency, and red while that is below 100 %.
    let capped = (powerStatus?.speedLimit ?? CPUPowerStatus.unlimited) < CPUPowerStatus.unlimited
    frequency.notes =
      [baseNote]
      + (powerStatus?.ceilingMHz.map {
        [
          Note(
            name: "Ceiling",
            value: String(format: "%.2f", $0 / Units.mhzPerGHz),
            color: capped ? .systemRed : .labelColor
          )
        ]
      } ?? [])
      + [
        Note(
          name: "Turbo",
          value: turbo.map { $0 ? "Active" : "Off" } ?? ChartPanel.noValue,
          color: turbo == true ? .labelColor : .secondaryLabelColor
        )
      ]
    var thermal: [Note] = []
    if let fan = sample.fanRPM {
      thermal.append(Note(name: "Fan", value: String(format: "%.0f rpm", fan)))
    }
    // macOS's speed limit isn't repeated here: the Frequency row's Ceiling is the same limit
    // as a frequency, red while it is below 100%, and the card's header names it then.
    // The SMC's count of prochots, which powermetrics does not document: whether per sample
    // or a running total is not known, so it is red only when it has gone up, and it is not
    // the processor's PROCHOT limit reason.
    if let prochots = sample.prochots {
      thermal.append(
        Note(
          name: "Prochots",
          value: "\(prochots)",
          color: prochots > (lastProchots ?? prochots) ? .systemRed : .labelColor
        )
      )
      lastProchots = prochots
    }
    temperature.notes = thermal

    if !hasSamples {
      hasSamples = true
      refresh()
    }
    show(state: .running(limits))
    updateRowsIfHeadersChanged()  // a value may have grown past what one header line holds
    return peak
  }

  /// Plots the GPUs' readings in the GPU card's rows.
  ///
  /// The integrated GPU's power comes with the CPU's readings while monitoring runs, and its clock
  /// with powermetrics', since its driver reports neither.
  ///
  /// - Parameter readings: One reading per GPU, in the order of `gpus`.
  /// - Returns: The readings as plotted, with those filled in.
  @discardableResult
  func apply(gpu readings: [GPUReading]) -> [GPUReading] {
    var readings = readings
    if let integrated = gpus.firstIndex(where: { $0.integrated }), integrated < readings.count,
      let latest = integratedGPU,
      Date().timeIntervalSince(latest.at) < Dashboard.integratedReadingsLast
    {
      readings[integrated].coreMHz = readings[integrated].coreMHz ?? latest.mhz
      readings[integrated].watts = readings[integrated].watts ?? latest.watts
    }
    gpuPower.push(readings.map { $0.watts })
    gpuClock.push(readings.flatMap { [$0.coreMHz, $0.memoryMHz] })
    gpuTemperature.push(readings.map { $0.tempC })
    gpuUtilization.push(readings.map { $0.utilization })
    gpuMemory.push(readings.map { $0.memoryGB })
    gpusOff = Set(readings.indices.filter { readings[$0].poweredDown })
    gpusSeenOn.formUnion(readings.indices.filter { !readings[$0].poweredDown })
    describeGPURows()
    updateRowsIfHeadersChanged()
    return readings
  }
}
