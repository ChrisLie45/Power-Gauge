// Why a row, or one of its values, is empty: what a row's plot says while it has nothing to
// show, and what the tooltip on each "n/a" says.

import Cocoa

extension Dashboard {
  /// Why a CPU reading can be missing once monitoring runs, which depends on where the readings
  /// come from.
  ///
  /// From powermetrics: it turned down the options the app asked for first, and fell back to fewer
  /// (see `RootScript.text`). From the kernel: the processor has no such counter, or the SMC no
  /// such key (see `KernelStats`).
  func describeCPURows() {
    let keys = SMC.coreTemperatureKeys
    let noCores =
      "This Mac's SMC has no per-core temperature sensors (keys \(keys[0]) to "
      + "\(keys[keys.count - 1]))."
    let coreReasons = [
      TemperatureSeries.hottestCore: noCores,
      TemperatureSeries.averageCore: noCores,
      TemperatureSeries.coolestCore: noCores,
    ]
    let kernel = (readingsSource ?? (triesKernel ? .kernel : .powermetrics)) == .kernel
    for panel in cpuPanels where panel !== memory {
      panel.emptyCaption = kernel ? "Not available" : "Not reported by powermetrics"
    }
    memory.emptyCaption = "Not available"
    if kernel {
      power.reasons = [
        PowerSeries.graphics: "This processor has no graphics energy counter.",
        PowerSeries.memory: KernelStats.memoryInPackageUnit
          ? "This processor has no memory energy counter."
          : "A Xeon counts its memory's energy in a unit of its own, which the kernel doesn't "
            + "give, so its memory power isn't shown.",
      ]
      temperature.reasons = [
        TemperatureSeries.die:
          "The SMC has none of the keys powermetrics takes the CPU's temperature from "
          + "(\(KernelStats.temperatureKeys.joined(separator: ", ")))."
      ]
      temperature.reasons.merge(coreReasons) { $1 }
    } else {
      let split =
        "powermetrics on this Mac turned down --show-extra-power-info, which it needs to "
        + "split the package's power into cores, graphics and memory."
      power.reasons = [
        PowerSeries.cores: split,
        PowerSeries.graphics: split,
        PowerSeries.memory: split,
      ]
      temperature.reasons = [
        TemperatureSeries.die:
          "powermetrics on this Mac turned down its smc sampler, which reads the CPU's "
          + "temperature and the fan."
      ]
      temperature.reasons.merge(coreReasons) { $1 }
    }
  }

  /// Marks the series of powered-down GPUs and gives each GPU row its reason for being
  /// empty, should it be.
  func describeGPURows() {
    let shown = gpus.indices.filter { selectedGPU == nil || $0 == selectedGPU }
    var running = false
    if case .running = state { running = true }
    // Whether the integrated GPU's clock is out of reach: the kernel's readings don't have it,
    // and they are being read, or will be at the next start.
    let clockNeedsPowermetrics = running ? readingsSource == .kernel : triesKernel
    for panel in gpuPanels {
      // A powered-down GPU says "Off" in the rows it is known to fill, which is all of
      // them until it has been seen running.
      let seriesPerGPU = panel === gpuClock ? Dashboard.clockSeriesPerGPU : 1
      panel.offSeries = Set(
        gpusOff.flatMap { gpu in (gpu * seriesPerGPU..<(gpu + 1) * seriesPerGPU) }
          .filter { !gpusSeenOn.contains($0 / seriesPerGPU) || panel.hasReported($0) }
      )
      // A row is empty because a GPU it would show is powered down, which its header
      // then says too; or because the integrated GPU's power and clock come with the CPU's
      // readings, its clock only with powermetrics'; or because the driver does not report
      // that reading at all. While monitoring, powermetrics may still not give one of them,
      // if it had to be started with fewer arguments; `given` is what its latest sample had.
      let viaCPU =
        (panel === gpuPower || panel === gpuClock) && shown.contains { gpus[$0].integrated }
      let given = panel === gpuPower ? integratedGPU?.watts : integratedGPU?.mhz
      panel.emptyCaption =
        shown.contains { gpusOff.contains($0) }
        ? "Powered down"
        : viaCPU && panel === gpuClock && clockNeedsPowermetrics && shown.count == 1
          ? "Needs powermetrics"
          : viaCPU && (!running || given != nil)
            ? "Available while monitoring"
            : viaCPU && shown.count == 1
              ? (readingsSource == .kernel ? "Not available" : "Not reported by powermetrics")
              : shown.count == 1 ? "Not reported by this GPU" : "Not reported by these GPUs"
    }
    // The memory row's notes give how much video memory each GPU shown has of its own.
    gpuMemory.notes = shown.compactMap { index in
      gpus[index].memoryGB.map {
        Note(name: gpus[index].short + " total", value: String(format: "%.1f", $0))
      }
    }

    // Why a GPU has no value in a row, for its "n/a" tooltip.
    for (index, gpu) in gpus.enumerated() {
      // "AMD 2" is an AMD.
      let make = gpu.short.split(separator: " ").first.map(String.init) ?? gpu.short
      let driver = make + "'s driver doesn't report"
      func fromPowermetrics(_ what: String) -> String {
        running
          ? "powermetrics doesn't include the Intel GPU's \(what) in its samples on this Mac."
          : "The Intel GPU's \(what) comes from powermetrics. Start monitoring to see it."
      }
      let power =
        clockNeedsPowermetrics
        ? (running
          ? "The processor has no graphics energy counter."
          : "The Intel GPU's power comes with the CPU's readings. Start monitoring to see it.")
        : fromPowermetrics("power")
      let clock =
        clockNeedsPowermetrics
        ? "The Intel GPU's clock comes only from powermetrics. Choose Monitor > CPU Readings "
          + "> powermetrics to see it."
        : fromPowermetrics("clock")
      func fromSMC(_ key: String?, _ what: String) -> String {
        if let key = key {
          return "The SMC gave no reading for \(key), where this Mac keeps the GPU's \(what)."
        }
        return make == "NVIDIA"
          ? "NVIDIA's driver doesn't report its \(what). Power Gauge reads it from the SMC "
            + "instead, but only on Macs whose sensors it knows (MacBookPro11,3)."
          : "\(driver) its \(what)."
      }
      gpuPower.reasons[index] = gpu.integrated ? power : fromSMC(gpu.smcKeys?.power, "power")
      gpuClock.reasons[Dashboard.coreClockSeries(ofGPU: index)] =
        gpu.integrated ? clock : "\(driver) its core clock."
      if gpu.integrated {
        gpuClock.gapReasons[Dashboard.coreClockSeries(ofGPU: index)] =
          "The Intel GPU was idle for the whole second, so it had no clock to give: "
          + "powermetrics gives its average clock while active."
      }
      gpuClock.reasons[Dashboard.memoryClockSeries(ofGPU: index)] =
        gpu.integrated
        ? "The Intel GPU has no memory of its own. It uses the Mac's, so it has no memory clock."
        : "\(driver) its memory clock."
      gpuTemperature.reasons[index] =
        gpu.integrated
        ? "The Intel GPU is part of the CPU chip and has no temperature sensor of its own: "
          + "see CPU die in the CPU card."
        : fromSMC(gpu.smcKeys?.temperature, "temperature")
      gpuUtilization.reasons[index] =
        gpu.hasBusyCounters && gpuUtilizationSource == .busyTime
        ? "Worked out from \(make)'s busy-time counters between one reading and the next, so "
          + "the first reading has none."
        : "\(driver) its utilization."
      gpuMemory.reasons[index] = "\(driver) the memory it uses."
    }
  }
}
