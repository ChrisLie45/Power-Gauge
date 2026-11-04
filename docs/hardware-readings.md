# Other readings: `Hardware/`

## macOS and the SMC

- **`ThisMac`, `Sysctl`:**
  - the model, processor and memory;
  - CPU utilisation (`HOST_CPU_LOAD_INFO`) and memory use (`HOST_VM_INFO64`, `vm.swapusage`);
  - the base clock (`ThisMac.nominalMHz`): `hw.cpufrequency`, else the brand string's
    "@ x.xxGHz", else the TSC, else n/a. The kernel readings' frequencies use the TSC first
    (`KernelStats.baseMHz`), since MPERF counts at its rate.
- **`CPUPowerStatus`:** macOS's speed and scheduler limits and the CPUs available
  (`IOPMCopyCPUPowerStatus`), the frequency ceiling (`machdep.xcpm`), and Low Power Mode.
- **`SMC`:** read-only, main thread only.
  - Core temperatures: TC0C, TC1C… (Macs number them from 0 or from 1), continuing in capital
    letters from TCAC, up to index `hw.physicalcpu`.
  - An NVIDIA GPU's temperature and power, where its driver has none, on the models listed in
    `GPU.nvidiaSMCKeys` (now only MacBookPro11,3).

## GPUs: `GPU/`

- **`GPU+Discovery`** finds each GPU whose driver is loaded.
- **`GPU.statistics()`** reads the driver's `PerformanceStatistics` from the I/O Registry, and
  `GPU.reading(from:…)` takes from it whichever of these the driver gives: power, temperature,
  clocks, utilisation, and the memory the GPU holds, the driver's cache included. NVIDIA's
  driver gives only utilisation. The Intel GPU's power and clock come from the CPU sample
  ([architecture.md](architecture.md)).
- **`GPUBusyCounters`** reads the busy-time counters the Intel and AMD drivers keep, through
  IOReport, a private library opened on first use. They are sampled with every reading, whichever
  source is shown, and used for GPUs that have them when the counters are chosen, except where
  the Intel driver provides its unscaled figure (below).
- **Utilisation source** (Monitor > GPU Utilization, `GPU.UtilizationSource`): the driver's
  "Device Utilization %" by default, or the busy-time counters. A driver computes that figure
  over the time since any process last read its statistics, so a second read straight after
  gives about 0%. Read the statistics once per reading (`GPU.statistics()`, then
  `reading(from:busy:utilization:)`).
- **Readings start** when the GPU card first opens or a recording starts, then continue
  ([architecture.md](architecture.md)).

## Decisions, not to undo

- **GPU utilisation defaults to the driver's "Device Utilization %"** to match other GPU
  monitors, though it reads low: well under 100% for a GPU busy all the time, and Intel's is
  scaled by its clock. The busy-time counters are more accurate, though slightly low under heavy
  load, and remain a choice in Monitor > GPU Utilization.
- **With the counters chosen, the Intel GPU uses "Device Utilization % at cur p-state".** Its
  busy counter can stick at 100% while idle.
- **The Intel GPU's memory is `gartSizeBytes − gartFreeBytes`.** `gartUsedBytes` is a 32-bit
  count that wraps every 2 GB.
- **macOS's speed limit comes from `IOPMCopyCPUPowerStatus`,** not `pmset`.
- **Per-core SMC keys stop at `hw.physicalcpu`.** Keys past that, such as TCGC and TCXC on some
  models, are other sensors.
