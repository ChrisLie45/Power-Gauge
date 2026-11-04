// The command-line help (`--help`, `-h`): the options for running the app from a terminal, and the
// test modes for working on it.

import Foundation

enum Usage {
  /// The arguments that ask for the help, as command-line tools take them.
  static let flags: Set<String> = ["--help", "-h"]

  /// Prints the help to standard output and exits, if it was asked for.
  static func printIfAsked() {
    guard CommandLine.arguments.dropFirst().contains(where: flags.contains) else { return }
    print(text, terminator: "")
    exit(0)
  }

  /// The help, with the executable's name as it was run.
  static var text: String {
    let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    return """
      Usage: \(name) [--print-csv] [--stream <file or pipe>]

      Plots an Intel Mac's CPU and GPU readings and shows why the CPU is throttled.
      With no options, opens the window.

      Options:
        --print-csv           Print a CSV row of readings a second to standard output,
                              with no window, from the sources chosen in the app, until
                              Ctrl-C or monitoring ends. Asks for an administrator
                              password when reading powermetrics.
        --stream <path>       Read powermetrics samples from a file or pipe instead of
                              starting powermetrics. With --print-csv, exits when the
                              file ends.
        -h, --help            Show this help.

      For development:
        --parse <file> [--layout haswell]  Print what powermetrics samples read as
        --csv-check <file>                 Print the CSV a sample stream records
        --survey-check <folder>            Replay a throttle survey
        --classify <reason>...             Print each limit reason's kind
        --kernel-windows                   Check made-up kernel readings
        --kernel-check                     Read this Mac's kernel for a few seconds
        --gpu-check                        Print this Mac's GPU readings
        --smc <key>...                     Print what SMC keys read
        --report [sample file]             Print the diagnostic report
        --gpu-load <seconds> [integrated]  Keep a GPU busy
        --snapshot <png> [options]         Draw the dashboard with made-up readings;
                                           options in TestModes+SnapshotMode.swift
        --app-check <sample file>          Run the whole app offscreen
        --root-script <pid> <stop file>    Print the script monitoring runs as root
        --memlog <file>                    Open the app, and log its memory and CPU
                                           use every 5 s

      """
  }
}
