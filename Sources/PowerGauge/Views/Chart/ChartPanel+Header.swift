// A chart row's header: its title and unit, each series' value keyed to its line, and the
// notes; how many lines all that takes at a given width; and the tooltips on missing values.

import Cocoa

extension ChartPanel: NSViewToolTipOwner {
  private static let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
    .foregroundColor: NSColor.labelColor,
  ]

  /// A readout's name: the size of its value, so that the two share a baseline.
  private static let readoutNameAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12),
    .foregroundColor: NSColor.secondaryLabelColor,
  ]

  private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

  private static let timeAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor.secondaryLabelColor,
  ]

  private static let readoutGap: CGFloat = 16
  private static let titleGap: CGFloat = 16
  private static let unitGap: CGFloat = 4
  /// Between a readout's name and its value.
  private static let nameGap: CGFloat = 6
  // A readout's swatch: a bar along the bottom of its line, under its name and value, heavier
  // for the bold series and lighter for the lines of `each` and a reference line; or for a
  // band a block of its colour, before the name, the space after it included.
  private static let barWidth: CGFloat = 3
  private static let boldBarWidth: CGFloat = 4
  private static let thinBarWidth: CGFloat = 1.5
  /// The bars' bottom edge, above the bottom of their line, the same for every weight so
  /// that a line's bars sit level.
  private static let barFloor: CGFloat = 1
  private static let blockSize = NSSize(width: 12, height: 9)
  private static let blockRise: CGFloat = 2.5
  private static let blockRadius: CGFloat = 2
  private static let blockAdvance: CGFloat = 16
  /// How far the header's text sits up from the bottom of its line: above the bars, with
  /// room between them and the letters' descenders, so that a bar reads as a key to the
  /// whole reading rather than as an underline of its name.
  private static let textRaise: CGFloat = 6

  /// What keys a readout to its line in the plot.
  enum Swatch {
    /// A bar under the readout, in the line's colour and pattern.
    case line(NSColor, dash: [CGFloat], width: CGFloat)
    /// A block of the colour it stands for, before the name.
    case block(NSColor)
  }

  /// A name and a value in the header, keyed to its line in the plot by a swatch if it has one:
  /// a bar under both in the line's colour, as Intel Power Gadget keys its readings, or for a
  /// band a block of its colour before the name.
  struct Readout {
    let name: String
    let value: String
    var color = NSColor.labelColor
    var swatch: Swatch?
    /// The least room the value is given, so that the readouts after it stay where they
    /// are when it gains or loses a digit.
    var reserved: CGFloat = 0
    /// Why there is no value, for a value of "n/a" or "Off".
    var tip: String?
  }

  /// Above the plot: the title and its unit, then each series' value.
  ///
  /// The right end of the title's line holds the notes or, while the pointer is on an earlier
  /// moment, which moment that is, after the band's name if it was marked (notes are current
  /// readings with no history, so they are left out then).
  ///
  /// - Parameter age: How many samples back the moment under the pointer is, or nil while the
  ///   pointer is not on the plot.
  func drawHeader(hoverAge age: Int?) {
    let left = ChartPanel.inset
    let right = bounds.maxX - ChartPanel.inset
    var lineY = bounds.maxY - ChartPanel.headerRowHeight + ChartPanel.textRaise
    title.draw(at: NSPoint(x: left, y: lineY), withAttributes: ChartPanel.titleAttrs)
    var x = left + ChartPanel.width(title, ChartPanel.titleAttrs) + ChartPanel.unitGap
    unit.draw(at: NSPoint(x: x, y: lineY), withAttributes: ChartPanel.nameAttrs)
    x += ChartPanel.width(unit, ChartPanel.nameAttrs) + ChartPanel.titleGap
    let hovered = (age ?? 0) > 0
    let notesBeside = headerRows == 1 || notesFitBesideTitle(width: bounds.width)
    if let age = age, hovered {
      let (name, time) = hoverText(at: age)
      var x = right - ChartPanel.width(time, ChartPanel.timeAttrs)
      time.draw(at: NSPoint(x: x, y: lineY), withAttributes: ChartPanel.timeAttrs)
      if let band = name {
        let marker = Readout(name: band.name, value: "", swatch: .block(band.color))
        x -= ChartPanel.readoutGap + width(of: marker)
        draw(marker, at: NSPoint(x: x, y: lineY))
      }
    } else if notesBeside {
      var x = right
      for note in noteReadouts.reversed() {
        x -= width(of: note)
        draw(note, at: NSPoint(x: x, y: lineY))
        x -= ChartPanel.readoutGap
      }
    }
    if headerRows > 1 {
      lineY -= ChartPanel.headerRowHeight
      x = left
    }
    let starts = headerRows > 1 ? lineStarts(width: bounds.width) : []
    var newTips: [(rect: NSRect, text: String)] = []
    for (place, readout) in seriesReadouts(at: age).enumerated() {
      if starts.contains(place) {
        lineY -= ChartPanel.headerRowHeight
        x = left
      }
      draw(readout, at: NSPoint(x: x, y: lineY))
      if let tip = readout.tip {
        newTips.append(
          (
            NSRect(
              x: x,
              y: lineY - ChartPanel.textRaise,
              width: width(of: readout),
              height: ChartPanel.headerRowHeight
            ), tip
          )
        )
      }
      x += width(of: readout) + ChartPanel.readoutGap
    }
    // Tooltips go where the "n/a" and "Off" values were just drawn, renewed only when one
    // has moved or says something else.
    if newTips.map({ "\($0.rect)\($0.text)" }) != tips.map({ "\($0.rect)\($0.text)" }) {
      tips = newTips
      removeAllToolTips()
      for tip in tips { addToolTip(tip.rect, owner: self, userData: nil) }
    }
    // In a row too narrow for them beside the title, the notes have a line of their own
    // under the values, and more if they need them.
    if !notesBeside, !hovered {
      lineY -= ChartPanel.headerRowHeight
      x = left
      let breaks = noteStarts(width: bounds.width)
      for (place, note) in noteReadouts.enumerated() {
        if breaks.contains(place) {
          lineY -= ChartPanel.headerRowHeight
          x = left
        }
        draw(note, at: NSPoint(x: x, y: lineY))
        x += width(of: note) + ChartPanel.readoutGap
      }
    }
  }

  /// What the tooltip of a series' "n/a" or "Off" says, for its latest value or the one
  /// `age` samples back: why it is off, why the series has none at all, or that this one
  /// reading is missing from a series that has others.
  private func reason(for index: Int, at age: Int?, off: Bool) -> String {
    if off { return offReason }
    if series[index].hasData {
      return gapReasons[index]
        ?? ((age ?? 0) == 0 ? "No reading in the latest sample." : "No reading at that moment.")
    }
    return reasons[index] ?? "Not reported."
  }

  /// What keys the series at `index`, listed at `place`, to the plot: a length of its line.
  private func swatch(for index: Int, place: Int) -> Swatch {
    .line(
      series[index].color,
      dash: dash(place: place, index: index),
      width: showsEach && index == bold ? ChartPanel.boldBarWidth : ChartPanel.barWidth
    )
  }

  /// The text that stands in for the notes while the pointer is on an earlier moment: when
  /// that was, after the band's name if the moment is in the band.
  private func hoverText(at age: Int) -> (band: (name: String, color: NSColor)?, time: String) {
    let number = band(at: age)
    return (number == ChartPanel.noBand ? nil : band(numbered: number), ChartPanel.timeLabel(age))
  }

  /// Each listed series with its latest value, or its value `age` samples back, and the range
  /// of `each` then, while its lines are shown.
  func seriesReadouts(at age: Int?) -> [Readout] {
    var readouts = listed.enumerated().map { place, index -> Readout in
      let line = series[index]
      let slot = line.values.count - 1 - (age ?? 0)
      let shown = slot >= 0 ? line.values[slot] : nil
      let isOff = (age ?? 0) == 0 && offSeries.contains(index)
      return Readout(
        name: line.name,
        value: isOff ? ChartPanel.off : ChartPanel.text(shown, line.format),
        color: isOff || shown == nil ? .secondaryLabelColor : .labelColor,
        swatch: swatch(for: index, place: place),
        reserved: line.widestValue,
        tip: isOff || shown == nil ? reason(for: index, at: age, off: isOff) : nil
      )
    }
    if showsEach {
      let slot = each.count - 1 - (age ?? 0)
      let values = slot >= 0 ? each[slot] : []
      readouts.append(
        Readout(
          name: eachName + "s",
          value: rangeText(values),
          color: values.isEmpty ? .secondaryLabelColor : .labelColor,
          swatch: .line(eachColor, dash: [], width: ChartPanel.thinBarWidth),
          reserved: widestRange,
          tip: values.isEmpty
            ? ((age ?? 0) == 0 ? "No reading in the latest sample." : "No reading at that moment.")
            : nil
        )
      )
    }
    return readouts
  }

  /// The room the range of `each` takes in the header while its lines are shown, counted like
  /// a series' (see `room(for:)`).
  private var eachRoom: [CGFloat] {
    guard showsEach else { return [] }
    let typical = countsEverySeries ? ChartPanel.valueWidth(rangeText([0, 0])) : 0
    return [
      ChartPanel.width(eachName + "s", ChartPanel.readoutNameAttrs) + ChartPanel.nameGap
        + max(widestRange, ChartPanel.valueWidth(ChartPanel.noValue), typical)
    ]
  }

  private var noteReadouts: [Readout] {
    notes.map {
      Readout(
        name: $0.name,
        value: $0.value,
        color: $0.color,
        swatch: $0.dashed
          ? .line(
            .secondaryLabelColor,
            dash: ChartPanel.referenceDash,
            width: ChartPanel.thinBarWidth
          ) : nil
      )
    }
  }

  static func text(_ value: Double?, _ format: String) -> String {
    value.map { String(format: format, $0) } ?? noValue
  }

  static func width(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> CGFloat {
    (text as NSString).size(withAttributes: attrs).width
  }

  static func valueWidth(_ text: String) -> CGFloat { width(text, [.font: valueFont]) }

  private func width(of readout: Readout) -> CGFloat {
    var block: CGFloat = 0
    if case .block? = readout.swatch { block = ChartPanel.blockAdvance }
    return block + ChartPanel.width(readout.name, ChartPanel.readoutNameAttrs) + ChartPanel.nameGap
      + max(ChartPanel.valueWidth(readout.value), readout.reserved)
  }

  /// The room a listed series takes in the header: its name, and its value at the widest that
  /// has been, or as wide as what stands in for a missing one.
  private func room(for index: Int) -> CGFloat {
    let placeholder = max(
      ChartPanel.valueWidth(ChartPanel.noValue),
      ChartPanel.valueWidth(ChartPanel.off)
    )
    // Before its first reading a series may be counted at the width of a typical value.
    let typical =
      countsEverySeries ? ChartPanel.valueWidth(String(format: series[index].format, 0.0)) : 0
    return ChartPanel.width(series[index].name, ChartPanel.readoutNameAttrs) + ChartPanel.nameGap
      + max(series[index].widestValue, placeholder, typical)
  }

  /// Which of a run of readouts of these widths, by place, start a further line when they
  /// are laid out left to right in a row of this width.
  private static func lineBreaks(_ widths: [CGFloat], width: CGFloat) -> Set<Int> {
    var starts: Set<Int> = []
    var x: CGFloat = 0
    for (place, readoutWidth) in widths.enumerated() {
      if place > 0, x + readoutWidth > width - 2 * inset {
        starts.insert(place)
        x = 0
      }
      x += readoutWidth + readoutGap
    }
    return starts
  }

  /// Where the values' lines break when they have lines of their own under the title.
  private func lineStarts(width: CGFloat) -> Set<Int> {
    ChartPanel.lineBreaks(listed.map { room(for: $0) } + eachRoom, width: width)
  }

  /// Where the notes' lines break when they have lines of their own under the values.
  private func noteStarts(width: CGFloat) -> Set<Int> {
    ChartPanel.lineBreaks(noteReadouts.map { self.width(of: $0) }, width: width)
  }

  /// Each note's width as a readout, in order, and all of them as one run.
  var noteWidths: [CGFloat] { noteReadouts.map { width(of: $0) } }

  static func runWidth(_ widths: [CGFloat]) -> CGFloat {
    widths.reduce(0, +) + readoutGap * CGFloat(max(widths.count - 1, 0))
  }

  /// Whether the notes, at the widest they have been, fit on the title's line in a row of
  /// this width once the values have lines of their own.
  private func notesFitBesideTitle(width: CGFloat) -> Bool {
    let title =
      ChartPanel.width(self.title, ChartPanel.titleAttrs) + ChartPanel.unitGap
      + ChartPanel.width(unit, ChartPanel.nameAttrs)
    return notes.isEmpty
      || 2 * ChartPanel.inset + title + ChartPanel.titleGap + widestNotes <= width
  }

  /// How many header lines a row of this width needs: 1 if everything fits beside the title;
  /// otherwise the title's line, as many under it as the values take, and the notes' if they
  /// do not fit beside the title.
  func headerRowsNeeded(width: CGFloat) -> Int {
    guard oneRowHeaderWidth() > width else { return 1 }
    let notesLines = notesFitBesideTitle(width: width) ? 0 : 1 + noteStarts(width: width).count
    let valueLines = 1 + lineStarts(width: width).count
    return 1 + valueLines + notesLines  // the title's line, then the values', then the notes'
  }

  private func draw(_ readout: Readout, at point: NSPoint) {
    var x = point.x
    let nameWidth = ChartPanel.width(readout.name, ChartPanel.readoutNameAttrs)
    switch readout.swatch {
    case .line(let color, let dash, let width)?:
      // The bar, in the line's colour and pattern, as long as the readout (setDash gives
      // dots their round ends).
      let bar = NSBezierPath()
      bar.lineWidth = width
      ChartPanel.setDash(dash, on: bar)
      let middle = point.y - ChartPanel.textRaise + ChartPanel.barFloor + width / 2
      let cap = bar.lineCapStyle == .round ? width / 2 : 0
      bar.move(to: NSPoint(x: x + cap, y: middle))
      bar.line(to: NSPoint(x: x + self.width(of: readout) - cap, y: middle))
      color.setStroke()
      bar.stroke()
    case .block(let color)?:
      color.setFill()
      let size = ChartPanel.blockSize
      NSBezierPath(
        roundedRect: NSRect(
          x: x,
          y: point.y + ChartPanel.blockRise,
          width: size.width,
          height: size.height
        ),
        xRadius: ChartPanel.blockRadius,
        yRadius: ChartPanel.blockRadius
      ).fill()
      x += ChartPanel.blockAdvance
    case nil:
      break
    }
    readout.name.draw(at: NSPoint(x: x, y: point.y), withAttributes: ChartPanel.readoutNameAttrs)
    x += nameWidth + ChartPanel.nameGap
    readout.value.draw(
      at: NSPoint(x: x, y: point.y),
      withAttributes: [.font: ChartPanel.valueFont, .foregroundColor: readout.color]
    )
  }

  /// The row width at which title, values and notes (or the hovered time) fit on one line.
  ///
  /// Each listed series counts at the widest its value has been, whether or not the row was open or
  /// the series shown then, so the values of any hovered moment fit as well. For one choice of
  /// series the answer only ever grows, so a value gaining a digit cannot make the header flip back
  /// and forth between one line and two.
  func oneRowHeaderWidth() -> CGFloat {
    func run(_ readouts: [Readout]) -> CGFloat {
      readouts.map { width(of: $0) }.reduce(0, +) + ChartPanel.readoutGap
        * CGFloat(max(readouts.count - 1, 0))
    }
    // The hovered moment at its widest: the longest time, after the band's name.
    var time = ChartPanel.width(ChartPanel.timeLabel(ChartPanel.span), ChartPanel.timeAttrs)
    if let widest = bands.map({
      width(of: Readout(name: $0.name, value: "", swatch: .block($0.color)))
    }).max() {
      time += ChartPanel.readoutGap + widest
    }
    let shown = countsEverySeries ? series.indices.filter { !hiddenSeries.contains($0) } : listed
    let rooms = shown.map { room(for: $0) } + eachRoom
    let values = rooms.reduce(0, +) + ChartPanel.readoutGap * CGFloat(max(rooms.count - 1, 0))
    let needed =
      ChartPanel.inset + ChartPanel.width(title, ChartPanel.titleAttrs) + ChartPanel.unitGap
      + ChartPanel.width(unit, ChartPanel.nameAttrs)
      + ChartPanel.titleGap + values + ChartPanel.titleGap + max(run(noteReadouts), time)
      + ChartPanel.inset
    widestHeader = max(widestHeader, needed)
    return widestHeader
  }

  /// The text of the tooltip under the pointer: why that value is "n/a" or "Off".
  func view(
    _ view: NSView,
    stringForToolTip tag: NSView.ToolTipTag,
    point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    tips.first { $0.rect.contains(point) }?.text ?? ""
  }
}
