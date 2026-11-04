// What a chart row plots, and the notes in its header.

import Cocoa

/// One line of a chart row, and its value in the row's header.
struct Series {
  let name: String
  let color: NSColor
  let format: String
  /// Empty for a solid line.
  var dash: [CGFloat] = []
  /// One slot per sample; nil where there was no reading.
  var values: [Double?] = []
  /// The widest its value has been as header text, shown or not.
  var widestValue: CGFloat = 0
  /// Whether it has ever had a reading.
  var reported = false

  var hasData: Bool { values.contains { $0 != nil } }
}

/// A reading in a row's header that has no line in its plot, such as the base frequency.
struct Note {
  let name: String
  let value: String
  var color: NSColor = .labelColor
  /// Keyed with the swatch of the dashed line that marks it in the plot.
  var dashed = false
}
