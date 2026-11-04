// Opening and closing the cards and placing them: side by side or one alone, moving with the
// window, and with as many header lines as the fullest row needs.

import Cocoa

extension Dashboard {
  /// Opens the CPU card, the GPU card, or both side by side; one of them is always open.
  ///
  /// With a window to follow, the change is animated by `onViewChange` through `prepareMove`,
  /// `animateMove` and `endMove`; without one, as in the snapshot mode, it is made at once.
  func open(cpu: Bool, gpu: Bool) {
    let gpu = gpu && !gpus.isEmpty
    let cpu = cpu || !gpu
    viewPicker.setSelected(cpu, forSegment: Dashboard.cpuSegment)
    viewPicker.setSelected(gpu, forSegment: Dashboard.gpuSegment)
    guard cpu != showsCPU || gpu != showsGPU else { return }
    endMove()  // a change still under way is cut short where it is
    let opening = cpu && !showsCPU ? cpuCard : gpu && !showsGPU ? gpuCard : nil
    let closing = !cpu && showsCPU ? cpuCard : !gpu && showsGPU ? gpuCard : nil
    showsCPU = cpu
    showsGPU = gpu
    cpuCardHeight.isActive = cpu
    gpuCardHeight.isActive = gpu
    moves += 1
    moving = (opening, closing, bounds.width, moves)
    if let opening = opening {
      opening.alphaValue = 0
      opening.isHidden = false
    }
    refresh()  // what the CPU has to say goes in the GPU card's header while its own card is closed
    if let onViewChange = onViewChange { onViewChange() } else { endMove() }
  }

  /// The width each open card gets in a content view this wide.
  private func cardWidth(in width: CGFloat) -> CGFloat {
    let inner = width - Dashboard.insets.left - Dashboard.insets.right
    return max(Dashboard.cardMinWidth, showsCPU && showsGPU ? (inner - Dashboard.gap) / 2 : inner)
  }

  /// Puts the cards in their places for this view's width: the open ones share it, and a
  /// closed one waits outside on its own side.
  func placeCards() {
    let share = cardWidth(in: bounds.width)
    switch (showsCPU, showsGPU) {
    case (true, true):
      (cpuLeft.constant, cpuWidth.constant, gpuWidth.constant) = (
        Dashboard.insets.left,
        share,
        share
      )
    case (true, false): (cpuLeft.constant, cpuWidth.constant) = (Dashboard.insets.left, share)
    default:
      (gpuWidth.constant, cpuLeft.constant) = (
        share,
        Dashboard.insets.left - Dashboard.gap - cpuWidth.constant
      )
    }
  }

  /// Readies the cards to move to their places in a content view `width` wide, for an
  /// animation about to run: a card that is opening starts outside on its own side, already
  /// at the width it will have, and the rows take the header lines they will need there.
  func prepareMove(toWidth width: CGFloat) {
    guard var move = moving else { return }
    move.toWidth = width
    moving = move
    let share = cardWidth(in: width)
    if move.opening === gpuCard { gpuWidth.constant = share }
    if move.opening === cpuCard {
      (cpuWidth.constant, cpuLeft.constant) = (share, Dashboard.insets.left - Dashboard.gap - share)
    }
    updateRows(cardWidth: share)
    layoutSubtreeIfNeeded()
  }

  /// Sets the cards moving, within the caller's animation group.
  ///
  /// A card that stays keeps its width unless the window's new size changes its share; one that
  /// closes keeps its width and slides out on its side as it fades, and one that opens slides in as
  /// it appears.
  func animateMove() {
    guard let move = moving else { return }
    let share = cardWidth(in: move.toWidth)
    let toCPULeft: CGFloat
    let toCPUWidth: CGFloat
    let toGPUWidth: CGFloat
    switch (showsCPU, showsGPU) {
    case (true, true): (toCPULeft, toCPUWidth, toGPUWidth) = (Dashboard.insets.left, share, share)
    case (true, false):
      (toCPULeft, toCPUWidth, toGPUWidth) = (Dashboard.insets.left, share, gpuWidth.constant)
    default:
      (toCPULeft, toCPUWidth, toGPUWidth) = (
        Dashboard.insets.left - Dashboard.gap - cpuWidth.constant,
        cpuWidth.constant,
        share
      )
    }
    cpuLeft.animator().constant = toCPULeft
    cpuWidth.animator().constant = toCPUWidth
    gpuWidth.animator().constant = toGPUWidth
    move.opening?.animator().alphaValue = 1
    move.closing?.animator().alphaValue = 0
  }

  /// Ends a change of cards: the card that closed is hidden, and the window's width places the
  /// cards again.
  ///
  /// - Parameter generation: The change to end, if only that one; nil ends whichever is under way.
  func endMove(generation: Int? = nil) {
    guard let move = moving, generation == nil || generation == move.generation else { return }
    moving = nil
    move.opening?.alphaValue = 1
    move.closing?.isHidden = true
    move.closing?.alphaValue = 1
    needsLayout = true
  }

  /// Fits the rows' headers to the window's width.
  ///
  /// The values share the title's line while every open row has the width for that. In a narrower
  /// window everything takes a second line: the values move under the titles, the
  /// rows' minimum height grows by that line, and the cards' headers move their detail under their
  /// titles. The cards do the rest; all of it is done by constraints.
  func updateRows() {
    // A row's width is worked out from this view's own, because the rows themselves are
    // only laid out after it, by the cards that hold them. While cards move, the header
    // lines are those of where they are going.
    guard bounds.width > 0, moving == nil else { return }
    updateRows(cardWidth: cardWidth(in: bounds.width))
  }

  /// After new readings: counts the header lines again only if an open row's header has changed
  /// since they were last counted (see `ChartPanel.headerChanged`).
  func updateRowsIfHeadersChanged() {
    guard openPanels.contains(where: { $0.headerChanged }) else { return }
    updateRows()
  }

  private var openPanels: [ChartPanel] { (showsCPU ? cpuPanels : []) + (showsGPU ? gpuPanels : []) }

  private func updateRows(cardWidth width: CGFloat) {
    let open = openPanels
    let needed = open.map { $0.headerRowsNeeded(width: width) }.max() ?? 1
    open.forEach { $0.headerChanged = false }
    guard needed != rows else { return }
    rows = needed
    cpuCard.headerRows = rows
    gpuCard.headerRows = rows
  }
}
