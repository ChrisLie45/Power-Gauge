import Cocoa

/// One row of a card, arranged like Intel Power Gadget's strips: a header with the title, its unit
/// and each series' value, and under it a scrolling plot drawn straight onto the card, with its
/// value axis in a gutter at the right.
///
/// The rows of a card share one time axis, which only the bottom row labels. Hovering marks the
/// time under the pointer; the values then show each series at that time instead of the latest
/// sample.
///
/// The plot is drawn in `ChartPanel+Plot.swift` and the header in `ChartPanel+Header.swift`, which
/// share the state here.
final class ChartPanel: NSView {
  // Samples come one a second. Each row keeps the last ten minutes of them, and its plot
  // shows the latest `span` seconds, which the View menu sets.
  static let shortestSpan = Units.secondsPerMinute
  static let longestSpan = 10 * Units.secondsPerMinute
  static let storage = longestSpan + 1

  static var span = 2 * Units.secondsPerMinute {
    didSet { span = min(max(span, shortestSpan), longestSpan) }
  }

  /// The samples a plot shows.
  static var capacity: Int { span + 1 }

  /// From the card's edge to the title and the plot.
  static let inset: CGFloat = 12
  /// Right of the plot, for the value axis labels.
  static let axisGutter: CGFloat = 30
  /// What labelling the time axis adds below the plot.
  static let timeAxisHeight: CGFloat = 16
  /// A line of text over the bars that key its readings.
  static let headerRowHeight: CGFloat = 21
  static let headerGap: CGFloat = 2
  static let minPlotHeight: CGFloat = 40

  static func headerHeight(rows: Int) -> CGFloat { CGFloat(rows) * headerRowHeight + headerGap }

  static func minHeight(headerRows: Int) -> CGFloat {
    headerHeight(rows: headerRows) + minPlotHeight
  }

  static let nameAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11),
    .foregroundColor: NSColor.secondaryLabelColor,
  ]

  // What stands for a value where there is none, and where the GPU it belongs to is powered down.
  static let noValue = "n/a"
  static let off = "Off"
  /// The dashes of a reference line, such as the base frequency's, in the plot and under its note.
  static let referenceDash: [CGFloat] = [4, 4]
  /// A plot smaller than this either way has no room to show anything.
  private static let smallestChart: CGFloat = 20

  private static let minusSign = "\u{2212}"

  private static let enDash = "\u{2013}"

  /// Line patterns that tell lines of one colour apart: the series of a row, when the system asks
  /// for that to be done without colour, the first listed solid, the second taking the next
  /// pattern, and so on; and GPUs of one make, which share its colour.
  static let patterns: [[CGFloat]] = [[], [4, 3], [1, 3], [6, 2, 1, 2], [8, 3], [2, 2]]

  private static let spokenUnits = [
    "W": "watts",
    "GHz": "gigahertz",
    "MHz": "megahertz",
    "°C": "degrees Celsius",
    "%": "percent",
    "GB": "gigabytes",
  ]

  let title: String
  let unit: String
  private(set) var series: [Series]
  private let minTop: Double
  private let step: Double

  /// A value marked across the plot with a dashed line, such as the base frequency.
  var reference: Double? { didSet { needsDisplay = true } }

  /// Bands of colour behind the plot for the moments pushed with one, such as when the CPU was
  /// being throttled: a sample pushed with band n has the nth, and 0 has none.
  ///
  /// The name says what the band means while the pointer is on it.
  var bands: [(name: String, color: NSColor)] = [] {
    didSet {
      headerChanged = true
      needsDisplay = true
    }
  }

  private var marked: [Int] = []
  /// Each sample's values for a line apiece, such as every CPU's frequency, kept only by a row that
  /// is to draw them (`keepsEach`) and drawn while `showsEach`: thin, all in one faint colour, so
  /// that where many run together they darken, under the row's own lines, of which the series
  /// `bold` is then drawn heavier.
  ///
  /// The header gives their range, as "CPUs 1.20–3.40" (`eachName` and an s), and hovering lists
  /// each one's value in a box beside the pointer.
  var keepsEach = false

  var showsEach = false {
    didSet {
      if showsEach != oldValue {
        widestHeader = 0
        headerChanged = true
        needsDisplay = true
      }
    }
  }

  var eachName = "CPU"
  var bold: Int?
  private(set) var each: [[Double]] = []
  /// The widest the range has been as header text.
  private(set) var widestRange: CGFloat = 0

  var notes: [Note] = [] {
    didSet {
      let widths = noteWidths
      widestNotes = max(widestNotes, ChartPanel.runWidth(widths))
      if widths != noteWidthsCounted {
        noteWidthsCounted = widths
        headerChanged = true
      }
      readingsChanged()
    }
  }

  private var noteWidthsCounted: [CGFloat] = []
  /// Whether anything the header's line count depends on has changed since the dashboard last
  /// counted: a value or range wider than any before, notes of other widths, or other series
  /// listed.
  ///
  /// Counting measures every readout's text, so after a sample the dashboard counts only when an
  /// open row's header has changed.
  var headerChanged = true
  /// Whether the row has had new readings while its window could not be seen.
  ///
  /// A layer-backed view that needs display is drawn at the next commit even in a window that is
  /// closed, hidden or covered, so new readings ask for a redraw only while the window shows, and
  /// the row catches up when it next does.
  private var missedReadings = false

  /// How many samples back from the newest the pointer is; shared by all panels.
  var hoverAge: Int? { didSet { needsDisplay = true } }

  var onHover: ((Int?) -> Void)?

  var showsTimeAxis = false { didSet { needsDisplay = true } }

  /// How many lines the header's text takes.
  ///
  /// 1 puts the values on the title's line, 2 on a line of their own under it, and more gives them
  /// further lines to wrap onto. The dashboard sets the same number on every row, so the plots stay
  /// the same height.
  var headerRows = 1 { didSet { if headerRows != oldValue { needsDisplay = true } } }

  var widestHeader: CGFloat = 0
  /// The notes at the widest they have been, as one run.
  private(set) var widestNotes: CGFloat = 0

  /// Series left out of the row, by index; they keep collecting values meanwhile.
  var hiddenSeries: Set<Int> = [] {
    didSet {
      widestHeader = 0
      headerChanged = true
      needsDisplay = true
    }
  }

  /// Series whose GPU is powered down, by index: they stay listed, with "Off" for a value.
  var offSeries: Set<Int> = [] { didSet { if offSeries != oldValue { needsDisplay = true } } }

  /// What the plot says while none of the listed series has a reading in it.
  var emptyCaption: String? { didSet { if emptyCaption != oldValue { needsDisplay = true } } }

  // Why a series has no value, by index, as the dashboard knows it. Resting the pointer on
  // the series' "n/a" shows it, as it does why an "Off" is off.
  var reasons: [Int: String] = [:]
  var offReason = "Powered down by macOS to save energy. It starts again when an app needs it."
  /// The header's "n/a" and "Off" values as last drawn, with what their tooltips say.
  var tips: [(rect: NSRect, text: String)] = []
  /// Has the one-line width count every series from the start, not only those listed so
  /// far, for a row whose series are all sure to report: its header then needs the same
  /// number of lines before the first sample as after it.
  var countsEverySeries = false

  init(title: String, unit: String, series: [Series], minTop: Double, step: Double) {
    self.title = title
    self.unit = unit
    self.series = series
    self.minTop = minTop
    self.step = step
    super.init(frame: .zero)
    // VoiceOver reads a row as one thing: what it is, then its latest values.
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// Adds a sample to the row.
  ///
  /// Every series gets a slot for every sample, so they stay aligned in time; nil leaves a gap in
  /// that series' line.
  ///
  /// - Parameters:
  ///   - values: One value per series, in order.
  ///   - band: The band to put the sample in, or `ChartPanel.noBand` for none.
  ///   - each: The sample's values for a line apiece, if the row keeps them.
  func push(_ values: [Double?], band: Int = ChartPanel.noBand, each: [Double] = []) {
    for index in series.indices {
      let value = index < values.count ? values[index] : nil
      series[index].values.append(value)
      if series[index].values.count > ChartPanel.storage { series[index].values.removeFirst() }
      if value != nil { series[index].reported = true }
      let width = ChartPanel.valueWidth(ChartPanel.text(value, series[index].format))
      if width > series[index].widestValue {
        series[index].widestValue = width
        headerChanged = true
      }
    }
    marked.append(min(max(band, 0), bands.count))
    if self.marked.count > ChartPanel.storage { self.marked.removeFirst() }
    if keepsEach {
      self.each.append(each)
      if self.each.count > ChartPanel.storage { self.each.removeFirst() }
      let width = ChartPanel.valueWidth(rangeText(each))
      if width > widestRange {
        widestRange = width
        headerChanged = true
      }
    }
    readingsChanged()
  }

  private func readingsChanged() {
    if window?.occlusionState.contains(.visible) == true {
      needsDisplay = true
    } else {
      missedReadings = true
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.didChangeOcclusionStateNotification,
      object: nil
    )
    if let window = window {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(occlusionChanged),
        name: NSWindow.didChangeOcclusionStateNotification,
        object: window
      )
    }
  }

  @objc private func occlusionChanged() {
    guard missedReadings, window?.occlusionState.contains(.visible) == true else { return }
    missedReadings = false
    needsDisplay = true
  }

  func hasReported(_ index: Int) -> Bool { series[index].reported }

  /// The band the sample `age` seconds back is in, or 0 for none.
  func band(at age: Int) -> Int {
    let slot = marked.count - 1 - age
    return slot >= 0 ? marked[slot] : ChartPanel.noBand
  }

  /// Bands are numbered from 1, in the order of `bands`; 0 is none.
  static let noBand = 0

  func band(numbered number: Int) -> (name: String, color: NSColor) { bands[number - 1] }

  /// The runs of samples in view in one band, each as the ages of its newest and oldest sample.
  var markedRuns: [(newest: Int, oldest: Int, band: Int)] {
    var runs: [(newest: Int, oldest: Int, band: Int)] = []
    var age = 0
    while age < ChartPanel.capacity {
      let band = self.band(at: age)
      guard band != ChartPanel.noBand else {
        age += 1
        continue
      }
      var oldest = age
      while oldest + 1 < ChartPanel.capacity, self.band(at: oldest + 1) == band { oldest += 1 }
      runs.append((age, oldest, band))
      age = oldest + 1
    }
    return runs
  }

  /// How many of the samples the plot now shows are in band n.
  func inView(band n: Int) -> Int { marked.suffix(ChartPanel.capacity).filter { $0 == n }.count }

  /// Whether a series has a reading among the samples the plot now shows.
  func hasDataInView(_ index: Int) -> Bool {
    series[index].values.suffix(ChartPanel.capacity).contains { $0 != nil }
  }

  /// Whether there are lines of `each` to draw: they are asked for and have values in view.
  var drawsEach: Bool { showsEach && each.suffix(ChartPanel.capacity).contains { !$0.isEmpty } }

  /// The colour of the lines of `each`: a faint grey, stronger with Increase Contrast on.
  var eachColor: NSColor {
    NSColor.systemGray.withAlphaComponent(
      DisplayOptions.increaseContrast ? ChartPanel.eachHighContrastOpacity : ChartPanel.eachOpacity
    )
  }

  private static let eachOpacity: CGFloat = 0.45
  private static let eachHighContrastOpacity: CGFloat = 0.75

  /// The range of values of `each` at one moment, as "1.20–3.40", in the bold series' format.
  func rangeText(_ values: [Double]) -> String {
    guard let low = values.min(), let high = values.max() else { return ChartPanel.noValue }
    let format = series[bold ?? 0].format
    return String(format: format, low) + ChartPanel.enDash + String(format: format, high)
  }

  /// The series to draw and list, by index: every one not hidden, so that a row names all
  /// the hardware it is about, with "n/a" for whatever has no value.
  var listed: [Int] { series.indices.filter { !hiddenSeries.contains($0) } }

  /// Why a series that has readings has none at some moment, by index, where that is known,
  /// such as an integrated GPU idle for the whole second having no clock to give.
  var gapReasons: [Int: String] = [:]

  /// The pattern of the line listed at `place`, which is the series at `index`.
  func dash(place: Int, index: Int) -> [CGFloat] {
    DisplayOptions.differentiateWithoutColor
      ? ChartPanel.patterns[place % ChartPanel.patterns.count] : series[index].dash
  }

  /// The top of the value axis: the row's least top, or the next step above the highest value
  /// listed or drawn in view.
  var axisTop: Double {
    var peak =
      listed.flatMap { series[$0].values.suffix(ChartPanel.capacity).compactMap { $0 } }.max() ?? 0
    if showsEach {
      peak = max(peak, each.suffix(ChartPanel.capacity).compactMap { $0.max() }.max() ?? 0)
    }
    return max(minTop, (peak / step).rounded(.up) * step)
  }

  var chartRect: NSRect {
    let bottom = showsTimeAxis ? ChartPanel.timeAxisHeight : 0
    return NSRect(
      x: ChartPanel.inset,
      y: bottom,
      width: bounds.width - 2 * ChartPanel.inset - ChartPanel.axisGutter,
      height: bounds.height - bottom - ChartPanel.headerHeight(rows: headerRows)
    )
  }

  var stepX: CGFloat { chartRect.width / CGFloat(ChartPanel.capacity - 1) }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self
      )
    )
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let chart = chartRect
    guard chart.width > ChartPanel.smallestChart, chart.contains(point) else {
      return mouseExited(with: event)
    }
    onHover?(Int(((chart.maxX - point.x) / stepX).rounded()))
  }

  override func mouseExited(with event: NSEvent) {
    onHover?(nil)
  }

  /// A moment `age` seconds back as the time axis labels it: "now", "−30s", or in a plot of more
  /// than two minutes, whole minutes, "−2m".
  ///
  /// - Parameters:
  ///   - age: How many seconds back the moment is.
  ///   - exact: Whether to give the moment to the second, as for the pointer's: "−42s", or in a
  ///     plot of more than two minutes "−4:05".
  static func timeLabel(_ age: Int, exact: Bool = true) -> String {
    if age == 0 { return "now" }
    let minute = Units.secondsPerMinute
    guard span > 2 * minute else { return minusSign + "\(age)s" }
    return exact
      ? minusSign + String(format: "%d:%02d", age / minute, age % minute)
      : minusSign + "\(age / minute)m"
  }

  /// Draws the plot (`ChartPanel+Plot.swift`), then the header above it
  /// (`ChartPanel+Header.swift`), then while the pointer is on the plot, the box of `each` values,
  /// which may cover both.
  override func draw(_ dirtyRect: NSRect) {
    let chart = chartRect
    guard chart.width > ChartPanel.smallestChart, chart.height > ChartPanel.smallestChart else {
      return
    }
    // The pointer's time, if it is on the plot.
    let age = hoverAge.flatMap { (0..<ChartPanel.capacity).contains($0) ? $0 : nil }
    drawPlot(in: chart, hoverAge: age)
    drawHeader(hoverAge: age)
    if let age = age, drawsEach { drawEachBox(at: age, chart: chart) }
  }

  /// The latest readings as a sentence, units spelled out, with the reason for any missing.
  override func accessibilityValue() -> Any? {
    let unit = ChartPanel.spokenUnits[self.unit] ?? self.unit
    let readings = seriesReadouts(at: nil).map { readout -> String in
      readout.tip.map {
        "\(readout.name) \(readout.value == ChartPanel.off ? "off" : "not available"): \($0)"
      }
        ?? "\(readout.name) \(readout.value) \(unit)"
    }
    // An empty plot's caption is its reason, unless "off" has said it already.
    let why = listed.contains { series[$0].hasData || offSeries.contains($0) } ? nil : emptyCaption
    // What the plot shows beyond the values: the band, and a line for each of `each`.
    var shows: [String] = []
    for (index, band) in bands.enumerated() {
      let number = index + 1  // bands are numbered from 1
      if inView(band: number) > 0 {
        shows.append(
          "\(band.name.lowercased()) for \(inView(band: number)) of the last "
            + "\(ChartPanel.span) seconds"
        )
      }
    }
    if drawsEach { shows.append("with a line for each \(eachName)") }
    return (readings + [why].compactMap { $0 } + notes.map { "\($0.name) \($0.value)" } + shows)
      .joined(separator: ", ")
  }
}
