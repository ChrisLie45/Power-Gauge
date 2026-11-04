// Command-line test modes, for checking parsing, readings and layout without a screen.
// scripts/test.sh runs the ones whose output does not depend on this Mac's readings. Each mode is
// in the file for what it checks: TestModes+ReadingChecks, +HardwareChecks, +KernelChecks,
// +SnapshotMode and +AppCheck. MadeUp has the made-up hardware and readings they
// share.

import Cocoa

enum TestModes {
  /// Runs the test mode asked for on the command line, if any, and exits once it is done.
  static func run() {
    let arguments = CommandLine.arguments
    // The kernel's test call, which the app makes in a child process of itself (see
    // KernelStats.open).
    if arguments.contains("--kernel-probe") { exit(KernelStats.probeHere()) }
    if arguments.contains("--kernel-check") { kernelCheckMode() }
    if arguments.contains("--kernel-windows") { kernelWindowsMode() }
    if let path = CommandLine.value(after: "--parse") { parseMode(path) }
    if arguments.contains("--gpu-check") { gpuCheckMode() }
    if let index = arguments.firstIndex(of: "--smc") {
      for key in arguments.dropFirst(index + 1) { print(describeSMC(key)) }
      exit(0)
    }
    if let path = CommandLine.value(after: "--csv-check") { csvCheckMode(path) }
    if let folder = CommandLine.value(after: "--survey-check") { surveyCheckMode(folder) }
    // Prints the diagnostic report, with the powermetrics sample in the file given, if any.
    if let index = arguments.firstIndex(of: "--report") {
      let sample =
        arguments.count > index + 1
        ? try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])) : nil
      print(
        DiagnosticReport.make(
          gpus: GPU.findAll(),
          state: nil,
          source: nil,
          gpuUtilization: .driver,
          kernelProblem: nil,
          powermetricsErrors: nil,
          firstSample: sample
        ),
        terminator: ""
      )
      exit(0)
    }
    if let path = CommandLine.value(after: "--snapshot") { snapshotMode(path) }
    // Prints what kind of limit each reason given after --classify is (see LimitKind.of).
    if let index = arguments.firstIndex(of: "--classify") {
      for name in arguments.dropFirst(index + 1) { print("\(name): \(LimitKind.of(name))") }
      exit(0)
    }
    if let seconds = CommandLine.value(after: "--gpu-load").flatMap(Double.init) {
      gpuLoadMode(seconds: seconds, integrated: arguments.contains("integrated"))
    }
    if let path = CommandLine.value(after: "--app-check") { appCheckMode(path) }
    // Prints the script that monitoring runs as root, for the process ID and stop file given.
    if let index = arguments.firstIndex(of: "--root-script"), arguments.count > index + 2,
      let pid = Int32(arguments[index + 1])
    {
      print(RootScript.text(appPID: pid, stopFile: arguments[index + 2]))
      exit(0)
    }
  }

  /// Memory footprint (what Activity Monitor shows), live heap, and CPU time used so far.
  static func memoryLine() -> String {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    _ = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    var heap = malloc_statistics_t()
    malloc_zone_statistics(nil, &heap)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpu =
      Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
        usage.ru_utime.tv_usec + usage.ru_stime.tv_usec
      ) / Units.microsecondsPerSecond
    return String(
      format: "footprint_mb=%.1f heap_in_use_mb=%.1f heap_reserved_mb=%.1f cpu_s=%.2f",
      Double(info.phys_footprint) / Units.bytesPerMB,
      Double(heap.size_in_use) / Units.bytesPerMB,
      Double(heap.size_allocated) / Units.bytesPerMB,
      cpu
    )
  }
}

extension CommandLine {
  /// The argument after `flag`, or nil if there is none.
  static func value(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
      CommandLine.arguments.count > index + 1
    else { return nil }
    return CommandLine.arguments[index + 1]
  }
}
