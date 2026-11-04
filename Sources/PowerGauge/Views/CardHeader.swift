import Cocoa

/// The top of a card: its title and a subtitle at the left; at the right a detail and, on one side
/// of it, something that stays put.
///
/// A card too narrow to give the detail room there shows it on a second line of its own instead.
/// The two forms are swapped by constraints alone, so that can be done in the middle of a layout
/// pass.
final class CardHeader: NSView {
  private static let margin: CGFloat = 12
  private static let padding: CGFloat = 6
  // The second line: one of 11 pt text.
  private static let lineGap: CGFloat = 2
  private static let detailHeight: CGFloat = 14
  // Between the title and the subtitle; at least this between them and what is on the right;
  // and between the two things on the right, a detail before what stays put or after it.
  private static let titleSpacing: CGFloat = 6
  private static let leadGap: CGFloat = 8
  private static let detailToFixedGap: CGFloat = 8
  private static let fixedToDetailGap: CGFloat = 12
  private let lineHeight: CGFloat
  private var height: NSLayoutConstraint!
  private var wide: [NSLayoutConstraint] = []
  private var narrow: [NSLayoutConstraint] = []

  var twoLines = false {
    didSet {
      guard twoLines != oldValue else { return }
      NSLayoutConstraint.deactivate(twoLines ? wide : narrow)
      NSLayoutConstraint.activate(twoLines ? narrow : wide)
      height.constant =
        2 * CardHeader.padding + lineHeight
        + (twoLines ? CardHeader.lineGap + CardHeader.detailHeight : 0)
    }
  }

  /// Creates the header of a card.
  ///
  /// `fixed` and `detail` may be empty or hidden; they then take no room.
  ///
  /// - Parameters:
  ///   - title: The card's name, at the left.
  ///   - subtitle: Text after the title, if any.
  ///   - fixed: What stays put at the right, if anything.
  ///   - detail: What stands beside `fixed` at the right.
  ///   - `detailFirst`: Whether `detail` comes before `fixed`, left to right, rather than after it.
  ///   - `lineHeight`: The height of the first line, which is the same in every card so that their
  ///     rows start level.
  init(
    title: String,
    subtitle: String?,
    fixed: NSView?,
    detail: NSView,
    detailFirst: Bool,
    lineHeight: CGFloat
  ) {
    self.lineHeight = lineHeight
    super.init(frame: .zero)
    let name = PlainLabel(
      oneLine: title,
      font: .preferredFont(forTextStyle: .headline),
      color: .labelColor
    )
    name.setContentCompressionResistancePriority(.required, for: .horizontal)
    let lead = NSStackView(views: [name])
    if let subtitle = subtitle {
      // The subtitle is the first thing to give way when the line is short of room.
      let about = PlainLabel(oneLine: subtitle)
      about.setContentCompressionResistancePriority(
        NSLayoutConstraint.Priority.defaultLow.stepped(-10),
        for: .horizontal
      )
      lead.addArrangedSubview(about)
    }
    lead.distribution = .fill
    lead.alignment = .firstBaseline
    lead.spacing = CardHeader.titleSpacing
    lead.setHuggingPriority(.defaultHigh, for: .horizontal)
    // Left to right on one line.
    let right = (detailFirst ? [detail, fixed] : [fixed, detail]).compactMap { $0 }
    for view in [lead] + right {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    let line = NSLayoutGuide()  // the first line
    addLayoutGuide(line)
    height = heightAnchor.constraint(equalToConstant: 2 * CardHeader.padding + lineHeight)
    var always: [NSLayoutConstraint] = [
      height,
      line.topAnchor.constraint(equalTo: topAnchor, constant: CardHeader.padding),
      line.heightAnchor.constraint(equalToConstant: lineHeight),
      line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardHeader.margin),
      line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardHeader.margin),
      lead.leadingAnchor.constraint(equalTo: line.leadingAnchor),
      lead.centerYAnchor.constraint(equalTo: line.centerYAnchor),
    ]
    // Whatever is on the right shrinks to nothing when it has nothing to show.
    for view in right {
      for size in [view.widthAnchor, view.heightAnchor] {
        let collapse = size.constraint(equalToConstant: 0)
        collapse.priority = NSLayoutConstraint.Priority(1)  // the weakest there is
        always.append(collapse)
      }
    }
    wide = [
      detail.centerYAnchor.constraint(equalTo: line.centerYAnchor),
      right[right.count - 1].trailingAnchor.constraint(equalTo: line.trailingAnchor),
      right[0].leadingAnchor.constraint(
        greaterThanOrEqualTo: lead.trailingAnchor,
        constant: CardHeader.leadGap
      ),
    ]
    if right.count == 2 {
      wide.append(
        right[0].trailingAnchor.constraint(
          equalTo: right[1].leadingAnchor,
          constant: -(detailFirst ? CardHeader.detailToFixedGap : CardHeader.fixedToDetailGap)
        )
      )
    }
    narrow = [
      detail.centerYAnchor.constraint(
        equalTo: line.bottomAnchor,
        constant: CardHeader.lineGap + CardHeader.detailHeight / 2
      ),
      detail.leadingAnchor.constraint(equalTo: line.leadingAnchor),
      detail.trailingAnchor.constraint(lessThanOrEqualTo: line.trailingAnchor),
    ]
    if let fixed = fixed {
      always.append(fixed.centerYAnchor.constraint(equalTo: line.centerYAnchor))
      narrow += [
        fixed.trailingAnchor.constraint(equalTo: line.trailingAnchor),
        fixed.leadingAnchor.constraint(
          greaterThanOrEqualTo: lead.trailingAnchor,
          constant: CardHeader.leadGap
        ),
      ]
    } else {
      narrow.append(lead.trailingAnchor.constraint(lessThanOrEqualTo: line.trailingAnchor))
    }
    NSLayoutConstraint.activate(always + wide)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
