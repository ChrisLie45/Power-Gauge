# Power Gauge

An AppKit app in Swift that plots an Intel Mac's CPU and GPU readings and shows why the CPU is
throttled. This file holds conventions and practices; `docs/` explains each part. The README
covers using and building the app.

## Commands

```bash
scripts/build.sh                 # builds build/Power Gauge.app
scripts/test.sh                  # builds, then runs every test
scripts/test.sh --update         # re-records expected output, for intended changes only
swift format --in-place --recursive Package.swift Sources Tests
swift format lint --strict --recursive Package.swift Sources Tests   # what CI checks
```

**Building and testing needs an Intel Mac** with the Command Line Tools. Elsewhere you can only
edit: say the change is untested, and leave checking to CI.

## Docs

Read an area's doc before changing it. The reading, throttling and window docs end with
**decisions, not to undo**: measured choices and workarounds for macOS or driver faults that look
like bugs until you know why.

| Doc | Covers |
|---|---|
| [docs/readings.md](docs/readings.md) | User reference: plot meanings, reading sources, GPU utilisation options and experimental readings |
| [docs/architecture.md](docs/architecture.md) | Build, startup, monitoring states and sessions, a sample's path to the window and CSV, threads, quitting, test seams |
| [docs/cpu-readings.md](docs/cpu-readings.md) | powermetrics, the root script, the experimental kernel readings, bursts, fallback |
| [docs/hardware-readings.md](docs/hardware-readings.md) | sysctl, Mach, macOS's limits, the SMC, GPU drivers and busy counters |
| [docs/throttling.md](docs/throttling.md) | Limit reasons, their kinds, bit layouts by processor generation |
| [docs/window.md](docs/window.md) | `AppDelegate`, settings, dashboard and chart rows, CSV, `--print-csv`, the report |
| [docs/testing.md](docs/testing.md) | Test modes, `scripts/test.sh`, fixtures, CI, releases |

When a change alters how an area works, update its doc in the same change. When a measurement
settles a choice, add it to that doc's decisions.

## Code conventions

- **Name numbers a reader would otherwise ask about:**
  - intervals, timeouts and history lengths (`burstInterval`, `acceptedAfterSeconds`);
  - bounds a reading must fall within (`Bounds.packageWatts`, `SMC.temperatureCeilingC`);
  - unit conversions, in `Units` (`hertzPerMHz`);
  - thresholds and tolerances, with a comment saying why (`leastActiveSeconds`, `leastCovered`);
  - margins, gaps, padding and line widths (`CardHeader.margin`, `readoutGap`);
  - any number that must agree with another.

  Leave inline: 0 and 1 as starts or steps, 2 to halve, 100 for a percentage, font sizes, and
  labelled arguments (`minTop: 100, step: 20`). Put the unit in the name unless the type
  carries it (`leastActiveSeconds`, `ceilingStepMHz`, but `interval: TimeInterval`).
- **Kernel, SMC and driver interfaces cite their source.** These values belong to xnu, Intel or
  Apple and must match exactly.
  - **Numbers:** named and grouped by what they belong to. The group's comment cites the xnu
    structure or header, SDM table or Apple symbol, and names follow the source's where it has
    one. Examples: selectors and result codes (`KernelStats.powerStatSelector`, `SMC.ABI`),
    structure offsets (`KernelStats.Offset`, after `pkg_energy_statistics_t`), shifts and masks
    (`energyUnitShift`, `energyUnitMask`), IDs (`LimitBits.CPUFamily`, from `mach/machine.h`).
  - **Bit tables:** keyed by bit number (`LimitBits.cpu`), with the layout's source and reserved
    bits in the comment above.
  - **String keys:** inline when used once (`"hw.cpufrequency"`, `"gartSizeBytes"`); named when
    reused or one of a set tried in order (`GPUBusyCounters.busy`, `KernelStats.temperatureKeys`).
  - **Byte assembly:** inline, with a comment (`<< 8`, `CDiag.c`'s `4L << 24`).
- **Google Swift style,** set up in `.swift-format`. CI fails on any `swift format lint --strict`
  finding. The formatter doesn't add the guide's blank line between a type's members (except
  one-line stored properties and cases).
- **Document declarations with `///`:** a one-sentence summary, a blank `///` line, then any
  more, with code names in backticks, and `- Parameters:` and `- Returns:` where the summary
  doesn't cover them. A comment on a group of declarations stays `//`, since `///` would attach
  to the first only.
- **No dependencies; Intel only; macOS 11 and later.** It must build with Swift 5.4, so gate
  newer SDK features with `#if compiler(>=…)` as well as `#available`.

## Practices

- **Before finishing:** run `scripts/test.sh`, then format and lint.
- **Test modes** never write the user defaults, need a password, or show anything on screen.
- **UI changes:** look at them offscreen with `--snapshot`, not screenshots. Don't add UI or
  picture tests for them: the app is small, and picture tests need re-recording after every
  macOS update.

## Ask first

- **Changing `CFBundleShortVersionString`** in `Resources/Info.plist`. Pushing a new version to
  `main` publishes a release.
- **Re-recording expected output to make a failing test pass.** Re-record only for
  intended changes, and say what changed.
- **Anything that needs an administrator password or loads the Mac:** the app or `--print-csv`
  with powermetrics chosen, `sudo scripts/throttle-survey.sh` (about 6 minutes of heavy load),
  `--gpu-load`. `scripts/test.sh` needs neither.
- **Adding a dependency, an Xcode project, or another language** beyond the one C file.
