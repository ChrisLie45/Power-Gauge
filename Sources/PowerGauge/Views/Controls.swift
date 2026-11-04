// Small pieces shared by the views: display accommodations, symbols and labels.

import Cocoa

/// Two display accommodations the drawing follows; the snapshot mode can force either on.
enum DisplayOptions {
  static var increaseContrast: Bool {
    CommandLine.arguments.contains("--increase-contrast")
      || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
  }

  static var differentiateWithoutColor: Bool {
    CommandLine.arguments.contains("--differentiate")
      || NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
  }
}

extension NSImage {
  /// An SF Symbol at a text size, or nil on a system that does not have it.
  static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
  }
}

/// A label that draws its own text, so that an offscreen capture shows it as the screen does.
///
/// A stock label hands its text to a private subview, which an offscreen capture then paints on top
/// of the label's own drawing, so the text comes out twice as heavy as on screen. Overriding
/// `draw(_:)` keeps the text in the label itself, where it is drawn once either way.
final class PlainLabel: NSTextField {
  override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }

  /// A one-line label that keeps to the width of its text and, where there is not room for
  /// that, is cut short with an ellipsis.
  convenience init(
    oneLine text: String,
    font: NSFont = .systemFont(ofSize: 11),
    color: NSColor = .secondaryLabelColor
  ) {
    self.init(labelWithString: text)
    self.font = font
    textColor = color
    lineBreakMode = .byTruncatingTail
    setContentHuggingPriority(.defaultHigh, for: .horizontal)
    setContentCompressionResistancePriority(
      NSLayoutConstraint.Priority.defaultHigh.stepped(1),
      for: .horizontal
    )
  }
}

extension NSLayoutConstraint.Priority {
  /// A priority a few steps above or below a stock one, to win against the views left at it or
  /// to give way to them.
  func stepped(_ steps: Float) -> NSLayoutConstraint.Priority {
    NSLayoutConstraint.Priority(rawValue + steps)
  }
}

/// A button drawn as a link, for an action offered in a line of text, such as starting
/// monitoring from a card's header.
final class LinkButton: NSButton {
  init(_ text: String) {
    super.init(frame: .zero)
    isBordered = false
    setButtonType(.momentaryPushIn)
    setText(text)
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func setText(_ text: String) {
    attributedTitle = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.linkColor,
      ]
    )
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
