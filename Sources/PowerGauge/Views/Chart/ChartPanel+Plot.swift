// A chart row's plot: the bands behind it, its grid and axes, its lines, and what hovering
// marks on it.

import Cocoa

extension ChartPanel {
  private static let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

  private static let axisAttrs: [NSAttributedString.Key: Any] = [
    .font: axisFont,
    .foregroundColor: NSColor.secondaryLabelColor,
  ]

  private static let tagAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
    .foregroundColor: NSColor.windowBackgroundColor,
  ]

  private static let boxValueAttrs: [NSAttributedString.Key: Any] = [
    .font: axisFont,
    .foregroundColor: NSColor.labelColor,
  ]

  /// The seconds between labels on the time axis, which also have an upright hairline each:
  /// every half minute in a plot of two minutes, every minute up to five, and every two beyond.
  private static var tickStep: Int {
    let minute = Units.secondsPerMinute
    return span <= 2 * minute ? minute / 2 : span <= 5 * minute ? minute : 2 * minute
  }

  // The value axis: divided into quarters, or halves where quarters would put the labels' digits
  // closer than `labelSpacing`; labels this far right of the plot, with up to `mostDecimals`.
  private static let axisDivisions = [4, 2]
  private static let labelSpacing: CGFloat = 4
  private static let axisLabelGap: CGFloat = 4
  private static let mostDecimals = 2
  /// How far round digits reach past the cap height.
  private static let digitOvershoot: CGFloat = 0.25
  /// How far the top label's digits may reach above the plot.
  private static let topLabelOverhang: CGFloat = 2
  /// Between the plot and the time labels under it.
  private static let timeLabelGap: CGFloat = 3
  /// The gridlines stop this far short of a caption.
  private static let captionMargin = NSSize(width: 8, height: 2)
  private static let baselineWidth: CGFloat = 1
  private static let lineWidth: CGFloat = 1.5
  private static let boldLineWidth: CGFloat = 2.5
  private static let eachLineWidth: CGFloat = 1
  private static let loneDotSize: CGFloat = 3
  private static let hoverDash: [CGFloat] = [2, 3]
  private static let hoverDotSize: CGFloat = 6
  private static let hoverDotHalo: CGFloat = 1
  private static let tagPadding = NSSize(width: 4, height: 1)
  private static let tagRadius: CGFloat = 3
  private static let tagClearance: CGFloat = 4
  // The box of `each` values: its lines, padding, gaps between columns and between a name and
  // its value, its distance from the pointer, its corners, and how opaque its backing is.
  private static let boxLineHeight: CGFloat = 13
  private static let boxPadding: CGFloat = 5
  private static let boxColumnGap: CGFloat = 10
  private static let boxNameGap: CGFloat = 6
  private static let boxOffset: CGFloat = 8
  private static let boxRadius: CGFloat = 4
  private static let boxOpacity: CGFloat = 0.92
  /// The smaller type the box falls back to when it doesn't fit in the axis font, as fractions
  /// of that font's size; its lines and gaps shrink with it.
  private static let boxShrinkSteps: [CGFloat] = [0.9, 0.8]
  // A pattern of one mark shorter than this and a gap is drawn as round dots: a mark of next to
  // nothing with round caps, at least `dotSpacing` line widths apart.
  private static let dotLength: CGFloat = 2
  private static let dotMark: CGFloat = 0.1
  private static let dotSpacing: CGFloat = 1.5
  /// The scale to draw for before the view is in a window.
  private static let defaultScale: CGFloat = 2

  /// Gives a line its pattern.
  ///
  /// Marks shorter than 2 pt are drawn as round dots, spaced so that they do not touch.
  static func setDash(_ dash: [CGFloat], on path: NSBezierPath) {
    guard !dash.isEmpty else { return }
    var pattern = dash
    var phase: CGFloat = 0
    if dash.count == 2, dash[0] < dotLength {
      path.lineCapStyle = .round
      pattern = [dotMark, max(dash[0] + dash[1], path.lineWidth * dotSpacing) - dotMark]
      phase = dotMark / 2  // so a dot due exactly at the end of a short line is still drawn
    }
    path.setLineDash(pattern, count: pattern.count, phase: phase)
  }

  /// The plot, in `chart`, with the pointer at the moment `age` seconds back, if it is on it.
  func drawPlot(in chart: NSRect, hoverAge age: Int?) {
    let shown = listed
    let eachLines = drawsEach
    let top = axisTop
    func y(_ value: Double) -> CGFloat {
      chart.minY + chart.height * CGFloat(min(max(value, 0), top) / top)
    }
    func x(_ age: Int) -> CGFloat { chart.maxX - CGFloat(age) * stepX }
    // Lines one device pixel wide are only that if they start on a pixel.
    let scale = window?.backingScaleFactor ?? ChartPanel.defaultScale
    func snap(_ coordinate: CGFloat) -> CGFloat { (coordinate * scale).rounded() / scale }

    // The band behind the plot: each run of marked samples, each sample a step wide.
    for run in markedRuns {
      band(numbered: run.band).color.setFill()
      let left = max(chart.minX, x(run.oldest) - stepX / 2)
      let right = min(chart.maxX, x(run.newest) + stepX / 2)
      NSRect(x: left, y: chart.minY, width: right - left, height: chart.height).fill(
        using: .sourceOver
      )
    }

    // A row with nothing to plot says why, in the middle of its plot.
    let caption = shown.contains { hasDataInView($0) } ? nil : emptyCaption
    let captionSize = (caption as NSString?)?.size(withAttributes: ChartPanel.nameAttrs) ?? .zero
    let captionBox = NSRect(
      x: snap(chart.midX - captionSize.width / 2),
      y: snap(chart.midY - captionSize.height / 2),
      width: captionSize.width,
      height: captionSize.height
    )
    caption?.draw(at: captionBox.origin, withAttributes: ChartPanel.nameAttrs)

    // The value axis divides the plot into quarters, or into halves if it is too short to
    // keep the labels' digits 4 pt apart. Each label is centred on its line (the digits sit
    // in the middle of their line box), except that the top one is nudged down until its
    // digits reach no more than 2 pt above the plot, clear of the header text there.
    let labelHeight = ("0" as NSString).size(withAttributes: ChartPanel.axisAttrs).height
    let digitHalf = ChartPanel.axisFont.capHeight / 2 + ChartPanel.digitOvershoot
    let topNudge = max(0, digitHalf - ChartPanel.topLabelOverhang)
    let steps =
      ChartPanel.axisDivisions.first {
        chart.height / CGFloat($0) - topNudge - 2 * digitHalf >= ChartPanel.labelSpacing
      } ?? 1

    // The grid, drawn onto the card with no fill or frame of its own: a baseline, a
    // hairline at each labelled value and at each labelled time, which stop short of a
    // caption. With Increase Contrast on, every line is the baseline's weight.
    // A pixel.
    let hairline = DisplayOptions.increaseContrast ? ChartPanel.baselineWidth : 1 / scale
    NSColor.separatorColor.setFill()
    NSRect(x: chart.minX, y: chart.minY, width: chart.width, height: ChartPanel.baselineWidth).fill(
      using: .sourceOver
    )
    NSGraphicsContext.saveGraphicsState()
    if caption != nil {
      let around = NSBezierPath(rect: bounds)
      around.appendRect(
        captionBox.insetBy(
          dx: -ChartPanel.captionMargin.width,
          dy: -ChartPanel.captionMargin.height
        )
      )
      around.windingRule = .evenOdd
      around.addClip()
    }
    for step in 1...steps {
      let y = snap(chart.minY + chart.height * CGFloat(step) / CGFloat(steps))
      NSRect(x: chart.minX, y: y - hairline, width: chart.width, height: hairline).fill(
        using: .sourceOver
      )
    }
    for age in stride(from: ChartPanel.tickStep, to: ChartPanel.span, by: ChartPanel.tickStep) {
      NSRect(x: snap(x(age)), y: chart.minY, width: hairline, height: chart.height).fill(
        using: .sourceOver
      )
    }
    NSGraphicsContext.restoreGraphicsState()

    // The value axis' labels, in the gutter at the right, with as few decimals as show
    // every one of them exactly (1.25 and 3.75 on a 5 GHz axis are not 1.2 and 3.8), up
    // to two, and the same number for all of them; the zero is a plain 0.
    let values = (0...steps).map { top * Double($0) / Double(steps) }
    let exactness = 1e-6
    let decimals =
      (0...ChartPanel.mostDecimals).first { places in
        values.allSatisfy {
          let scaled = $0 * pow(10, Double(places))
          return abs(scaled - scaled.rounded()) < exactness
        }
      } ?? ChartPanel.mostDecimals
    for (step, value) in values.enumerated() {
      let line = chart.minY + chart.height * CGFloat(step) / CGFloat(steps)
      let y = (step == steps ? line - topNudge : line) - labelHeight / 2
      let text = step == 0 ? "0" : String(format: "%.\(decimals)f", value)
      text.draw(
        at: NSPoint(x: chart.maxX + ChartPanel.axisLabelGap, y: y),
        withAttributes: ChartPanel.axisAttrs
      )
    }
    // Where the pointer's time is tagged on the time axis.
    let tag =
      showsTimeAxis
      ? age.map {
        tagBox(
          ChartPanel.timeLabel($0),
          centeredAt: x($0),
          midY: chart.minY - ChartPanel.timeAxisHeight / 2,
          within: chart.minX...chart.maxX
        )
      } : nil
    // The time axis, labelled under the bottom row only, the end labels kept inside the
    // plot. A label that the hover tag would sit on is left out while it does.
    if showsTimeAxis {
      for tick in stride(from: 0, through: ChartPanel.span, by: ChartPanel.tickStep) {
        let text = ChartPanel.timeLabel(tick, exact: false) as NSString
        let width = text.size(withAttributes: ChartPanel.axisAttrs).width
        let left = min(max(x(tick) - width / 2, chart.minX), chart.maxX - width)
        if let tag = tag, left < tag.maxX + ChartPanel.tagClearance,
          left + width > tag.minX - ChartPanel.tagClearance
        {
          continue
        }
        text.draw(
          at: NSPoint(x: left, y: chart.minY - ChartPanel.timeLabelGap - labelHeight),
          withAttributes: ChartPanel.axisAttrs
        )
      }
    }

    if let reference = reference {
      let line = NSBezierPath()
      line.move(to: NSPoint(x: chart.minX, y: snap(y(reference))))
      line.line(to: NSPoint(x: chart.maxX, y: snap(y(reference))))
      line.setLineDash(ChartPanel.referenceDash, count: ChartPanel.referenceDash.count, phase: 0)
      NSColor.secondaryLabelColor.setStroke()
      line.stroke()
    }

    NSGraphicsContext.saveGraphicsState()
    // Room for a line along the top or the bottom.
    NSBezierPath(rect: chart.insetBy(dx: 0, dy: -ChartPanel.baselineWidth)).addClip()
    if eachLines {
      // A line for each, under the row's own, from one sample before the plot's left edge.
      // Each is stroked on its own, so that where they cross the faint colour builds up.
      let recent = Array(each.suffix(ChartPanel.capacity + 1))
      for index in 0..<(recent.map { $0.count }.max() ?? 0) {
        let path = NSBezierPath()
        var drawing = false
        for (slot, values) in recent.enumerated() {
          guard index < values.count else {
            drawing = false
            continue
          }
          let point = NSPoint(x: x(recent.count - 1 - slot), y: y(values[index]))
          if drawing { path.line(to: point) } else { path.move(to: point) }
          drawing = true
        }
        path.lineWidth = ChartPanel.eachLineWidth
        path.lineJoinStyle = .round
        eachColor.setStroke()
        path.stroke()
      }
    }
    for (place, index) in shown.enumerated() {
      let line = series[index]
      let path = NSBezierPath()
      let lone = NSBezierPath()  // a reading with none on either side has no line to be part of
      var run = 0  // readings since a missing one last lifted the pen
      var last = NSPoint.zero
      func endRun() {
        let dot = ChartPanel.loneDotSize
        if run == 1 {
          lone.appendOval(
            in: NSRect(x: last.x - dot / 2, y: last.y - dot / 2, width: dot, height: dot)
          )
        }
        run = 0
      }
      // From one sample before the plot's left edge, so that a line runs in from the edge.
      for slot in max(0, line.values.count - ChartPanel.capacity - 1)..<line.values.count {
        guard let value = line.values[slot] else {
          endRun()
          continue
        }
        last = NSPoint(x: x(line.values.count - 1 - slot), y: y(value))
        if run > 0 { path.line(to: last) } else { path.move(to: last) }
        run += 1
      }
      endRun()
      path.lineWidth = eachLines && index == bold ? ChartPanel.boldLineWidth : ChartPanel.lineWidth
      path.lineJoinStyle = .round
      ChartPanel.setDash(dash(place: place, index: index), on: path)
      line.color.setStroke()
      path.stroke()
      line.color.setFill()
      lone.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Hover: a dotted line at the pointer's time, a marker on each series, and the time
    // tagged on the axis where it is labelled. The values of `each` go in a box beside it,
    // drawn last of all (drawEachBox).
    if let age = age {
      let dotted = NSBezierPath()
      dotted.move(to: NSPoint(x: snap(x(age)), y: chart.minY))
      dotted.line(to: NSPoint(x: snap(x(age)), y: chart.maxY))
      dotted.setLineDash(ChartPanel.hoverDash, count: ChartPanel.hoverDash.count, phase: 0)
      NSColor.secondaryLabelColor.setStroke()
      dotted.stroke()
      for index in shown {
        let slot = series[index].values.count - 1 - age
        guard slot >= 0, let value = series[index].values[slot] else { continue }
        let size = ChartPanel.hoverDotSize
        let halo = ChartPanel.hoverDotHalo
        let dot = NSRect(x: x(age) - size / 2, y: y(value) - size / 2, width: size, height: size)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -halo, dy: -halo)).fill()
        series[index].color.setFill()
        NSBezierPath(ovalIn: dot).fill()
      }
      if let tag = tag { drawTag(ChartPanel.timeLabel(age), in: tag) }
    }
  }

  /// Where the small inverted tag for the hovered time goes on the time axis: centred on
  /// that time, but kept within `span`.
  ///
  /// - Parameters:
  ///   - text: The time the tag shows.
  ///   - x: Where that time is across the plot.
  ///   - midY: The height the tag is centred on.
  ///   - span: How far across the tag may go.
  private func tagBox(
    _ text: String,
    centeredAt x: CGFloat,
    midY: CGFloat,
    within span: ClosedRange<CGFloat>
  ) -> NSRect {
    let size = (text as NSString).size(withAttributes: ChartPanel.tagAttrs)
    let pad = ChartPanel.tagPadding
    var box = NSRect(
      x: x - size.width / 2 - pad.width,
      y: midY - size.height / 2 - pad.height,
      width: size.width + 2 * pad.width,
      height: size.height + 2 * pad.height
    )
    box.origin.x = max(span.lowerBound, min(box.origin.x, span.upperBound - box.width))
    return box
  }

  private func drawTag(_ text: String, in box: NSRect) {
    NSColor.labelColor.setFill()
    NSBezierPath(roundedRect: box, xRadius: ChartPanel.tagRadius, yRadius: ChartPanel.tagRadius)
      .fill()
    text.draw(
      at: NSPoint(
        x: box.minX + ChartPanel.tagPadding.width,
        y: box.minY + ChartPanel.tagPadding.height
      ),
      withAttributes: ChartPanel.tagAttrs
    )
  }

  /// The values of `each` at the moment `age` samples back, in a box beside the pointer: the first
  /// along the top row, the values lined up at the right, laid out as `eachBoxLayout` says.
  ///
  /// The box goes right of the pointer if it fits in the plot, otherwise left, and is kept inside
  /// the room the layout was made for. Where that room is the whole row, the box covers the header:
  /// it is drawn after it, from the top of the row so as to cover the title whole rather than cut
  /// it, and opaque so that the header's words don't show through.
  func drawEachBox(at age: Int, chart: NSRect) {
    let slot = each.count - 1 - age
    guard slot >= 0, !each[slot].isEmpty else { return }
    let format = series[bold ?? 0].format
    let values = each[slot].map { String(format: format, $0) }
    let (layout, room) = eachBoxLayout(values, chart: chart)
    let x = chart.maxX - CGFloat(age) * stepX
    let pad = ChartPanel.boxPadding
    let offset = ChartPanel.boxOffset
    var box = NSRect(origin: .zero, size: layout.size)
    box.origin.x = x + offset + box.width <= chart.maxX ? x + offset : x - offset - box.width
    box.origin.x = max(room.minX, min(box.origin.x, room.maxX - box.width))
    let overHeader = room.height > chart.height
    box.origin.y = max(
      room.minY,
      overHeader ? room.maxY - box.height : min(chart.midY - box.height / 2, room.maxY - box.height)
    )
    let shape = NSBezierPath(
      roundedRect: box,
      xRadius: ChartPanel.boxRadius,
      yRadius: ChartPanel.boxRadius
    )
    NSColor.windowBackgroundColor.withAlphaComponent(overHeader ? 1 : ChartPanel.boxOpacity)
      .setFill()
    shape.fill()
    NSColor.separatorColor.setStroke()
    shape.stroke()
    for (place, name) in layout.names.enumerated() {
      let left = box.minX + pad + CGFloat(place % layout.columns) * (layout.cell + layout.columnGap)
      let bottom = box.maxY - pad - CGFloat(place / layout.columns + 1) * layout.line
      name.draw(at: NSPoint(x: left, y: bottom), withAttributes: layout.nameAttrs)
      values[place].draw(
        at: NSPoint(
          x: left + layout.cell - ChartPanel.width(values[place], layout.valueAttrs),
          y: bottom
        ),
        withAttributes: layout.valueAttrs
      )
    }
  }

  /// How the box of `each` values is laid out: each value's name, the type and spacing they are
  /// set in, the width of a name and its value, and the columns and lines they fill.
  private struct EachBoxLayout {
    let names: [String]
    let nameAttrs: [NSAttributedString.Key: Any]
    let valueAttrs: [NSAttributedString.Key: Any]
    let line: CGFloat
    let columnGap: CGFloat
    let cell: CGFloat
    let columns: Int
    let rows: Int

    var size: NSSize {
      NSSize(
        width: CGFloat(columns) * cell + CGFloat(columns - 1) * columnGap + 2
          * ChartPanel.boxPadding,
        height: CGFloat(rows) * line + 2 * ChartPanel.boxPadding
      )
    }
  }

  /// The roomiest layout of the box for `values`, and the room it fits in, so that a processor with
  /// many CPUs, such as a Xeon, still has all of them shown: names as "CPU 12" in the axis font,
  /// then as the number alone, then in smaller type.
  ///
  /// Each has as many columns as make the box about square, or more where the room isn't tall
  /// enough for that many lines. The room is the plot's height, leaving the header to be read, or
  /// if nothing fits there, the whole row's; the smallest layout in the whole row if nothing fits
  /// even that.
  private func eachBoxLayout(_ values: [String], chart: NSRect) -> (
    layout: EachBoxLayout,
    room: NSRect
  ) {
    let numbers = values.indices.map { String($0) }
    let named = numbers.map { "\(eachName) \($0)" }
    func layout(names: [String], scale: CGFloat, height: CGFloat) -> EachBoxLayout {
      let font = NSFont.monospacedDigitSystemFont(
        ofSize: ChartPanel.axisFont.pointSize * scale,
        weight: .regular
      )
      let nameAttrs = ChartPanel.axisAttrs.merging([.font: font]) { $1 }
      let valueAttrs = ChartPanel.boxValueAttrs.merging([.font: font]) { $1 }
      let nameWidth = names.map { ChartPanel.width($0, nameAttrs) }.max() ?? 0
      let valueWidth = values.map { ChartPanel.width($0, valueAttrs) }.max() ?? 0
      let line = ChartPanel.boxLineHeight * scale
      let fittingRows = max(1, Int((height - 2 * ChartPanel.boxPadding) / line))
      let columns = max(
        Int(Double(names.count).squareRoot().rounded(.up)),
        (names.count + fittingRows - 1) / fittingRows
      )
      return EachBoxLayout(
        names: names,
        nameAttrs: nameAttrs,
        valueAttrs: valueAttrs,
        line: line,
        columnGap: ChartPanel.boxColumnGap * scale,
        cell: nameWidth + ChartPanel.boxNameGap * scale + valueWidth,
        columns: columns,
        rows: (names.count + columns - 1) / columns
      )
    }
    let choices: [(names: [String], scale: CGFloat)] =
      [(named, 1)] + ([1] + ChartPanel.boxShrinkSteps).map { (numbers, $0) }
    let plot = NSRect(x: bounds.minX, y: chart.minY, width: bounds.width, height: chart.height)
    for room in [plot, bounds] {
      for choice in choices {
        let fitted = layout(names: choice.names, scale: choice.scale, height: room.height)
        if fitted.size.width <= room.width, fitted.size.height <= room.height {
          return (fitted, room)
        }
      }
    }
    return (
      layout(names: numbers, scale: ChartPanel.boxShrinkSteps.last ?? 1, height: bounds.height),
      bounds
    )
  }
}
