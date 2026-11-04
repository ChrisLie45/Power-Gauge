# Understanding the readings

[Back to the README](../README.md)

## CPU frequency

Frequency is averaged over the time a CPU was active, leaving idle time out. An almost idle Mac
can therefore show a high frequency: its brief wake-ups often run at turbo.

With powermetrics, max and min are the fastest and slowest CPU's averages for the second. The
experimental kernel source catches shorter bursts, so its max can be higher at the same load.

## Throttling

The CPU card's header shows what is limiting the CPU, by its worst kind, and bands behind the
frequency plot mark when:

- **PROCHOT throttling** (red): a PROCHOT signal telling the processor to slow down.
- **Thermal throttling** (red): the processor's thermal limit or a hot voltage regulator.
- **Throttled by macOS** (red): macOS's speed or scheduler limit, or CPUs taken offline.
- **Power limited** (amber): PL1, PL2, ICCMAX and the like, or Low Power Mode. Expected under
  heavy load.
- **No throttling:** only limits that are part of normal turbo, or that Power Gauge doesn't know.
- **Limits unknown:** the sample has no readable CPU limit bits, as on processors older than
  Haswell (2013). macOS's own limits can still show throttling.

A reason counts only while the processor says it is limiting it now; powermetrics' list of names
also includes recent ones, which would show "power limited" at idle. This was checked against
throttle surveys of both Macs, which the tests replay. `sudo scripts/throttle-survey.sh` records
another Mac's (about six minutes of heavy load).

## GPU utilisation

**Monitor > GPU Utilization** chooses the driver's own percentage (the default, matching other
GPU monitors) or busy-time counters. The driver's figure can read low: about 76% for an AMD GPU
busy all the time, and Intel's is scaled down by its clock. The counters follow the load more
closely; Intel uses its driver's unscaled figure because its counter can stick at 100%.

Reading a driver's statistics resets its measurement interval. Running Power Gauge alongside
another GPU monitor can therefore disturb utilisation readings, including with `--print-csv`.

## Experimental: no password

**Monitor > CPU Readings > Kernel, No Password (Experimental)** reads the counters powermetrics
reads straight from the kernel, with the temperature and fan from the SMC. It has only been
checked on my two Macs, so on others readings may be wrong or missing.

- If the counters can't be read, or don't hold together for three seconds, it switches to
  powermetrics and its password prompt.
- It has no Intel GPU clock and no SMC prochot count.
- It reads the counters every 10 ms, so the frequency row's max shows turbo bursts that
  powermetrics' one-second averages hide. This costs about 2% of one core.

## Where the readings come from

| CPU stats | Default (asks for a password) | Kernel readings (experimental, no password) |
|---|---|---|
| Power: package, cores, GT, DRAM | powermetrics | Energy counters from the kernel's diagnostic call; DRAM omitted on Xeon |
| Each CPU's frequency, averaged while it was active (so an idle Mac reads high) | powermetrics | The kernel's diagnostic call |
| The frequency row's max and min: the highest and lowest clock in each second | The fastest and slowest CPU's average while active, which smooths away turbo bursts of a few ms | Each CPU's clock while active over 10 ms, which catches them |
| The processor's limit reasons | powermetrics | The kernel's diagnostic call |
| CPU die temperature, fan | powermetrics | SMC |
| Each core's temperature | SMC | SMC |
| Utilisation, memory, swap | macOS (Mach, sysctl) | macOS (Mach, sysctl) |
| Base clock, frequency ceiling | sysctl | sysctl |
| macOS's speed limit, Low Power Mode | macOS (IOPM, sysctl) | macOS (IOPM, sysctl) |

| GPU stats | Default (asks for a password) | Kernel readings (experimental, no password) |
|---|---|---|
| Intel GPU power | powermetrics | Energy counter from the kernel's diagnostic call |
| Intel GPU clock | powermetrics | Not available |
| Other GPUs' power, temperature and clocks, where available | GPU driver | GPU driver |
| Memory held, including the driver's cache | GPU driver | GPU driver |
| Utilisation | GPU driver ("Device Utilization %") | GPU driver |
| Utilisation with busy-time counters chosen | AMD: IOReport busy counters; Intel: GPU driver ("Device Utilization % at cur p-state") | The same |
| NVIDIA temperature and power, where its driver has none | SMC on supported models (currently MacBookPro11,3) | The same |

Implementation details: [CPU readings](cpu-readings.md), [hardware readings](hardware-readings.md)
and [throttling](throttling.md).
