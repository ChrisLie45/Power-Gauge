# Tests, CI and releases: `TestModes/`, `scripts/test.sh`, `Tests/`, `.github/`

## Test modes

Test modes are flags of the app itself; `main.swift` calls `TestModes.run()` before the app
starts, right after `Usage.printIfAsked()` handles `--help`. The main ones:

| Flag | What it does |
|---|---|
| `--parse` | Reads a powermetrics sample |
| `--csv-check` | Records a sample stream to CSV |
| `--survey-check` | Replays a throttle survey |
| `--kernel-windows`, `--kernel-check` | Made-up and this Mac's kernel readings |
| `--snapshot` | The dashboard with made-up readings, to a PNG; `--light`, `--dark`, `--hover`, `--mac-pro`… |
| `--app-check` | The real `AppDelegate` offscreen, with a stand-in for powermetrics, through starting, falling back, recording, stopping and quitting |
| `--gpu-check`, `--smc`, `--report` | Live readings, for hardware work |
| `--gpu-load` | Keeps a GPU busy, to load it while watching the readings |

None needs a password, shows anything on screen, or touches saved settings. Look at UI changes
offscreen with `--snapshot`, not screenshots; there are no picture tests.

## `scripts/test.sh`

- **Runs** the test modes and compares their output with `Tests/expected/`. The script's header
  lists every test. Output goes to `build/tests/`.
- **Child checks:** the kernel, root-script and app checks must exit successfully and report
  results. A crash, an empty report or an AppKit constraint conflict fails the suite.
- **`--update`** re-records the expected output, for intended changes only.
- **Test data:** `Tests/fixtures/` holds real powermetrics samples and two throttle surveys (a
  2019 and a 2014 MacBook Pro), recorded with `scripts/throttle-survey.sh`. They are the evidence
  for the throttling rules ([throttling.md](throttling.md)).

## CI

`.github/workflows/build.yml` checks the style, builds, and runs the tests on a macOS 26 Intel
runner, then tests the same build on macOS 15. Build and test jobs have read-only repository
access; only the release job can write tags and releases.

## Releases

When a push to `main` passes CI and the version in `Resources/Info.plist`
(`CFBundleShortVersionString`) has no release yet, that version is released. The commit is
tagged `v<version>`, `Power-Gauge-<version>.zip` (made with `ditto`) is attached, and the notes
are `.github/release-notes.md` followed by GitHub's generated list of changes. To release, raise
the version and push.
