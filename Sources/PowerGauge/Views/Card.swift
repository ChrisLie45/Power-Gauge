import Cocoa

/// One of the window's two panels: a header, a rule under it, and its chart rows, on a rounded
/// backing a shade off the window's colour.
///
/// It is content, so it is drawn the same plain way on every macOS version; the system's glass is
/// for the toolbar above it.
final class Card: NSView {
  let header: CardHeader
  let panels: [ChartPanel]
  /// Everything under the rule.
  let body = NSView()
  /// The chart rows, which size the card even while hidden.
  let rows = NSStackView()
  private var rowFloor: NSLayoutConstraint!

  /// How many lines each row's header takes: 1, or more in a narrow card, when the card's
  /// own header takes a second line too.
  var headerRows = 1 {
    didSet {
      guard headerRows != oldValue else { return }
      panels.forEach { $0.headerRows = headerRows }
      rowFloor.constant = ChartPanel.minHeight(headerRows: headerRows)
      header.twoLines = headerRows > 1
    }
  }

  init(header: CardHeader, panels: [ChartPanel]) {
    self.header = header
    self.panels = panels
    super.init(frame: .zero)
    panels.last?.showsTimeAxis = true
    let rule = NSBox()
    rule.boxType = .separator
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.distribution = .fill
    rows.spacing = Card.rowSpacing
    rows.edgeInsets = NSEdgeInsets(
      top: Card.rowsPadding,
      left: 0,
      bottom: Card.rowsPadding,
      right: 0
    )
    for panel in panels {
      rows.addArrangedSubview(panel)
      panel.translatesAutoresizingMaskIntoConstraints = false
      panel.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
    // Every plot is the same height; the bottom row is taller by its time axis labels.
    // Both cards hold the same stack under the same header, so their rows line up
    // without being tied to each other.
    rowFloor = panels[0].heightAnchor.constraint(
      greaterThanOrEqualToConstant: ChartPanel.minHeight(headerRows: 1)
    )
    rowFloor.isActive = true
    for panel in panels.dropFirst() {
      panel.heightAnchor.constraint(
        equalTo: panels[0].heightAnchor,
        constant: panel.showsTimeAxis ? ChartPanel.timeAxisHeight : 0
      ).isActive = true
    }
    for view in [header, rule, body] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    rows.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(rows)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      rule.topAnchor.constraint(equalTo: header.bottomAnchor),
      rule.heightAnchor.constraint(equalToConstant: 1),
      rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChartPanel.inset),
      rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChartPanel.inset),
      body.topAnchor.constraint(equalTo: rule.bottomAnchor),
      body.leadingAnchor.constraint(equalTo: leadingAnchor),
      body.trailingAnchor.constraint(equalTo: trailingAnchor),
      body.bottomAnchor.constraint(equalTo: bottomAnchor),
      rows.topAnchor.constraint(equalTo: body.topAnchor),
      rows.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      rows.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      rows.bottomAnchor.constraint(equalTo: body.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  private static let cornerRadius: CGFloat = 10
  private static let rowSpacing: CGFloat = 10
  private static let rowsPadding: CGFloat = 8
  /// The backing's tint where the system has no fill colour for it (before macOS 14).
  private static let fillOpacity: CGFloat = 0.05
  /// Half the edge's width, so that all of it falls inside the card.
  private static let edgeInset: CGFloat = 0.5

  override func draw(_ dirtyRect: NSRect) {
    // The #if compiler checks in this file stand in for checks of the SDK, which Swift has
    // none of: Swift 5.5.1 came with the macOS 12 SDK, 5.9 with macOS 14 and 6.2 with macOS 26.
    // They hold while each Swift builds with its own SDK, as build.sh has it do.
    #if compiler(>=5.9)
      if #available(macOS 14.0, *) {
        NSColor.quaternarySystemFill.setFill()
      } else {
        NSColor.labelColor.withAlphaComponent(Card.fillOpacity).setFill()
      }
    #else
      NSColor.labelColor.withAlphaComponent(Card.fillOpacity).setFill()
    #endif
    NSBezierPath(roundedRect: bounds, xRadius: Card.cornerRadius, yRadius: Card.cornerRadius).fill()
    // So faint a fill is no edge at all for someone who has asked for more contrast.
    if DisplayOptions.increaseContrast {
      NSColor.separatorColor.setStroke()
      NSBezierPath(
        roundedRect: bounds.insetBy(dx: Card.edgeInset, dy: Card.edgeInset),
        xRadius: Card.cornerRadius,
        yRadius: Card.cornerRadius
      ).stroke()
    }
  }
}
