# CPU readings: `Monitoring/`, `Powermetrics/`, `Kernel/`

## powermetrics (default)

`Monitor.start()` runs `RootScript.text` through `osascript`'s administrator prompt, once per
start.

- **Pipe:** the script creates a root-owned `/tmp/powergauge.XXXXXX` folder with a named pipe in
  it, and starts one `powermetrics -f plist -i 1000` writing to the pipe.
- **Arguments:** if powermetrics rejects its arguments (exits within 3 s), the script retries
  with plainer ones.
- **Stopping:** a watcher stops powermetrics and removes the folder when the app's process ends
  or its stop file appears.
- **Reading:** `Monitor` reads the pipe on its own thread. `PlistStream` splits the stream after
  each `</plist>`, dropping the NULs and newlines between documents, and `Powermetrics.parse`
  turns each document into a `Sample`.
- **Malformed numbers:** non-finite readings are left out. PROCHOT counts must fit in an `Int`
  exactly, so a malformed count cannot crash the parser during conversion.
- **Errors:** powermetrics' complaints go to `error.txt` in the folder, and are shown if no
  sample arrives within 6 s.

`--stream <file or pipe>` reads samples from there instead of starting powermetrics, for testing
and with `--print-csv`.

## Kernel readings (experimental, off by default)

Monitor > CPU Readings; user default `ExperimentalKernelReadings`. The same counters as
powermetrics, with no password.

- **Probe:** the first call runs in a child process (`--kernel-probe`), since an unknown
  diagnostic selector ends the calling process.
- **Call:** `CDiag.c` makes xnu's diagnostic system call (`dgPowerStat`), which returns the
  package energy counters, the limit registers, and each CPU's APERF/MPERF. Each call returns
  the per-CPU counters that the previous one had the CPUs store; package energy and limit
  registers are read during the call.
- **Power:** `KernelStats.sample` converts energy-counter differences to watts using the
  reported energy unit and elapsed time. DRAM power is omitted on Xeon, whose memory energy
  uses a different unit that the call doesn't report.
- **Sampling:** `KernelSampler` makes a call every 10 ms on its own queue, so readings lag by
  10 ms. Each second's sample spans readings a second apart, and `KernelStats` checks it against
  what the hardware can do. Only opening, which has no previous call to rely on, takes a reading
  as two calls 2 ms apart (`Reader.read()`).
- **Bursts:** each CPU's active clock per 10 ms (`KernelStats.activeMHz`) gives the second's
  highest and lowest clock (`Sample.burstMHz`). The frequency row and the CSV show both as max
  and min; the menu bar item shows the max. With powermetrics, max and min are the fastest and
  slowest CPU's averages.
- **Fallback:** a single bad second, such as the first after sleep, is dropped. `Monitor` falls
  back to powermetrics after three bad seconds in a row or three failed calls in a row, or at
  once when the readings can't be opened: under Rosetta, with no base clock, or when the probe
  fails or neither record layout holds together. Every start then uses powermetrics until the
  app is relaunched or the kernel is chosen again.
- **Temperature and fan** come from the SMC. There is no Intel GPU clock or prochot count.

## Decisions, not to undo

- **Kernel-reading frequencies (APERF/MPERF) read a few percent above the work done** with one
  CPU busy. powermetrics reports the same figures, so it's not a bug.
- **Kernel-reading max and min are 10 ms bursts.** Turbo boosts last milliseconds. At light load
  the cores reach full turbo every second while one-second averages sit well below it, which
  misleads users. 20 ms and 50 ms intervals read noticeably under the true peak; 10 ms costs
  only a small fraction of a core.
- **powermetrics gives no bursts,** and the kernel isn't read alongside it to add them. That was
  a choice, not an oversight.
