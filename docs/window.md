# App and window: `App/`, `Views/`, `Recording/`, `Report/`

## App

- **`AppDelegate`:** the lifecycle, with one extension per part: window, menus, monitoring, menu
  bar item, recording, printing, report.
  - Settings, in the user defaults: `OpenCards`, `SelectedGPU`, `HistoryMinutes`,
    `PerCoreFrequencies`, `ExperimentalKernelReadings`, `BusyTimeGPUUtilization`, and a
    `WindowFrame.<cards>` for each set of open cards.
  - Only the app proper writes them (`persists`); test modes never do.

## Window

- **`Dashboard`:** two `Card`s, CPU and GPU, each a `CardHeader` over `ChartPanel` rows. All open
  rows, in both cards, have the same number of header lines, so the plots line up.
- **`ChartPanel`:** one row.
  - **History:** stores 601 samples (10 minutes) and shows the latest 2, 5 or 10 minutes.
  - **Drawing:** draws its header and plot itself in `draw(_:)`. Each reading has a colour bar
    under its name and value, as in Power Gadget.
  - **Hidden windows:** new readings request a redraw only while the window is visible
    (`occlusionState`). AppKit draws layer-backed views even in a closed or covered window, so
    without this check a closed window redraws every second.
  - **Header lines:** `headerChanged` marks when a header may need a different number of lines.
    After a sample, text is measured again only then; a layout pass, as when the window is
    resized, measures every open row.

## Output

- **`Recorder`:** a CSV row a second, in plain ASCII with `.` decimals and ISO 8601 times, so any
  spreadsheet reads it.
- **`--print-csv`** (`AppDelegate+Printing`): no window, menu bar item or Dock icon. Writes a
  `Recorder`'s rows to standard output, for scripts and agents. It uses the user's sources
  (`loadSources()`), writes no settings, sends monitoring events to standard error, and exits
  when monitoring ends. With `--stream <file>` it prints a sample file, which `scripts/test.sh`
  checks.
- **`DiagnosticReport`:** the Mac, its processor, macOS's limits, the GPUs, what the app reads,
  and the first powermetrics sample. Nothing personal.

## Decisions, not to undo

- **No drawing while the window is hidden,** and header text is measured only when it can
  change. Together these cut a closed window's CPU use several times over.
