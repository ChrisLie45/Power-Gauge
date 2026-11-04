import Foundation

/// The part of monitoring that runs as root: the script that starts powermetrics and stops it
/// again, run through the macOS admin prompt, and what powermetrics complains of.
enum RootScript {
  /// The admin prompts up now, which `closePrompts()` closes; used from any thread under
  /// `promptsLock`.
  private static var prompts: [Process] = []
  private static let promptsLock = NSLock()

  /// Runs `script` through the macOS admin prompt, with administrator privileges, and gives its
  /// exit status and what it printed.
  static func runAsAdministrator(_ script: String) -> (status: Int32, output: String) {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = [
      "-e",
      "on run argv",
      "-e",
      "do shell script (item 1 of argv) with prompt \"Power Gauge wants to run powermetrics "
        + "to read CPU frequency.\" with administrator privileges",
      "-e",
      "end run",
      script,
    ]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return (-1, "") }
    promptsLock.lock()
    prompts.append(task)
    promptsLock.unlock()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    task.waitUntilExit()
    promptsLock.lock()
    prompts.removeAll { $0 === task }
    promptsLock.unlock()
    return (task.terminationStatus, out)
  }

  /// Closes any admin prompt still up, as when the app quits.
  ///
  /// The prompt belongs to `osascript`, which goes on running once the app has gone, so without
  /// this the prompt would stay on screen for an app that no longer exists.
  static func closePrompts() {
    promptsLock.lock()
    let open = prompts
    promptsLock.unlock()
    for task in open where task.isRunning { task.terminate() }
  }

  /// The script `Monitor.start()` runs as root, which prints the root-owned temp folder it made.
  ///
  /// It starts one powermetrics that streams plist samples into a named pipe there. A watcher stops
  /// it and removes the folder once the app is gone, or as soon as the stop file exists.
  /// powermetrics is asked for as much as it may give and as little as it must: `gpu_power` adds
  /// the integrated GPU, smc adds temperature and fan speed, `--show-extra-power-info` splits the
  /// package's power into cores, graphics and memory, and `--hide-cpu-duty-cycle` leaves out
  /// per-CPU tables this app never reads, which are most of each sample. If powermetrics rejects a
  /// set of arguments and exits, the loop goes on to the next, plainer set, giving up the GPU
  /// sampler before the two options and those before the temperature sampler. One that had been
  /// running for 3 s or more before it exited did not reject its arguments, so the loop ends there
  /// and the stream with it, instead of carrying on with fewer readings. When stopped, the loop's
  /// shell stops whichever powermetrics it last started, and any it has just started too.
  ///
  /// The password prompt can be answered after the app has gone, and then nothing would ever open
  /// the pipe to read it. Opening it to write waits for a reader, and a shell waiting there leaves
  /// a signal pending, so it would wait as root for good. So the script does nothing once the app
  /// has gone, and the watcher follows its TERM with a KILL a second later: by then the loop's
  /// shell has stopped powermetrics if it was running, and otherwise never started it.
  ///
  /// - Parameters:
  ///   - appPID: The app's process ID; powermetrics stops when that process ends.
  ///   - stopFile: The file whose existence stops powermetrics.
  static func text(appPID: Int32, stopFile: String) -> String {
    let sampleIntervalMS = 1000
    let acceptedAfterSeconds = 3
    // The stop file is the user's own, so the root side only ever asks whether it exists.
    // Its path goes between single quotes, with any quote in it written as '\''.
    let notStopped = "[ ! -e '\(stopFile.replacingOccurrences(of: "'", with: "'\\''"))' ]"
    return """
      /bin/kill -0 \(appPID) 2>/dev/null || exit 1; \
      D=$(/usr/bin/mktemp -d /tmp/powergauge.XXXXXX) || exit 1; /bin/chmod 755 "$D"; \
      /usr/bin/mkfifo -m 644 "$D/stream" || exit 1; \
      ( ( trap 'kill $C $(jobs -p) 2>/dev/null; exit 0' TERM; exec > "$D/stream"; \
      for A in "cpu_power,gpu_power,smc --show-extra-power-info --hide-cpu-duty-cycle" \
      "cpu_power,gpu_power,smc --hide-cpu-duty-cycle" \
      "cpu_power,smc --show-extra-power-info --hide-cpu-duty-cycle" \
      "cpu_power,smc --hide-cpu-duty-cycle" "cpu_power,smc" "cpu_power"; do \
      \(notStopped) || break; S=$(/bin/date +%s); \
      /usr/bin/nice -n 10 /usr/bin/powermetrics --samplers $A -f plist -b 1 \
      -i \(sampleIntervalMS) 2>> "$D/error.txt" & C=$!; wait $C; \
      [ $(( $(/bin/date +%s) - S )) -lt \(acceptedAfterSeconds) ] || break; \
      done ) & PM=$!; \
      while /bin/kill -0 \(appPID) 2>/dev/null && /bin/kill -0 $PM 2>/dev/null \
      && \(notStopped); do /bin/sleep 1; done; \
      /bin/kill $PM 2>/dev/null; /bin/sleep 1; /bin/kill -9 $PM 2>/dev/null; \
      while /bin/kill -0 \(appPID) 2>/dev/null && \(notStopped); do /bin/sleep 1; done; \
      /bin/rm -rf "$D" ) > /dev/null 2>&1 & echo "$D"
      """
  }

  /// What powermetrics has written to the error file beside its stream, as one line.
  ///
  /// Each set of arguments tried adds its complaint to the file, often the same one, so each is
  /// said once.
  static func complaints(in dir: String) -> String {
    var seen = Set<Substring>()
    return (try? String(contentsOfFile: dir + "/error.txt", encoding: .utf8))?.split(
      whereSeparator: \.isNewline
    )
    .filter { seen.insert($0).inserted }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
      ?? ""
  }
}
