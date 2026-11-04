import Cocoa

/// The window's content: a CPU card and a GPU card, either open or both side by side.
///
/// How its cards open and close is in `Dashboard+Cards.swift`, the readings they plot in
/// `Dashboard+Readings.swift`, what they say about monitoring in `Dashboard+Status.swift`, and why
/// a row or a value is empty in `Dashboard+Captions.swift`.
final class Dashboard: NSView {
  let power = ChartPanel(
    title: "Power",
    unit: "W",
    series: [
      Series(name: "Package", color: .systemBlue, format: "%.1f"),
      Series(name: "IA cores", color: .systemIndigo, format: "%.1f"),
      Series(name: "GT", color: .systemPink, format: "%.1f"),
      Series(name: "DRAM", color: .systemBrown, format: "%.1f"),
    ],
    minTop: 20,
    step: 20
  )

  let frequency = ChartPanel(
    title: "Frequency",
    unit: "GHz",
    series: [
      Series(name: "Core max", color: .systemOrange, format: "%.2f"),
      Series(name: "Core avg", color: .systemGreen, format: "%.2f"),
      Series(name: "Core min", color: .systemTeal, format: "%.2f"),
    ],
    minTop: 5,
    step: 1
  )

  /// The CPU die's temperature, from powermetrics, and the hottest, average and coolest core's,
  /// from the SMC's sensor in each core.
  let temperature = ChartPanel(
    title: "Temperature",
    unit: "°C",
    series: [
      Series(name: "CPU die", color: .systemRed, format: "%.0f"),
      Series(name: "Core max", color: .systemOrange, format: "%.0f"),
      Series(name: "Core avg", color: .systemGreen, format: "%.0f"),
      Series(name: "Core min", color: .systemTeal, format: "%.0f"),
    ],
    minTop: 100,
    step: 20
  )

  /// The places of the CPU rows' series, in the order they are listed and pushed.
  enum PowerSeries { static let package = 0, cores = 1, graphics = 2, memory = 3 }

  enum FrequencySeries { static let fastest = 0, average = 1, slowest = 2 }

  enum TemperatureSeries { static let die = 0, hottestCore = 1, averageCore = 2, coolestCore = 3 }

  enum UtilizationSeries { static let cpu = 0 }

  enum MemorySeries { static let used = 0, compressed = 1, swap = 2 }

  /// The GPU clock row has two series for each GPU: its core clock, then its memory clock.
  static let clockSeriesPerGPU = 2

  static func coreClockSeries(ofGPU index: Int) -> Int { index * clockSeriesPerGPU }

  static func memoryClockSeries(ofGPU index: Int) -> Int { index * clockSeriesPerGPU + 1 }

  /// A GPU menu item's tag: its GPU's place in `gpus` plus one, or 0 for the item that shows them
  /// all.
  static func tag(forGPU index: Int) -> Int { index + 1 }

  static func gpu(forTag tag: Int) -> Int? { tag > 0 ? tag - 1 : nil }

  // The view picker's segments.
  static let cpuSegment = 0
  static let gpuSegment = 1
  /// How many minutes back the plots can go, as the View menu offers.
  static let historyChoices = [2, 5, 10]

  let utilization = ChartPanel(
    title: "Utilization",
    unit: "%",
    series: [Series(name: "CPU", color: .systemPurple, format: "%.0f")],
    minTop: 100,
    step: 100
  )

  /// The Mac's memory, on an axis as tall as all of it.
  let memory: ChartPanel
  /// The processor's name, base frequency and memory this shows.
  let machine: MachineInfo
  // The GPU rows match the CPU ones row for row and carry one line per GPU (two in the
  // clock row, for its core and memory clocks).
  let gpus: [GPU]
  let gpuPower: ChartPanel
  let gpuClock: ChartPanel
  let gpuTemperature: ChartPanel
  let gpuUtilization: ChartPanel
  let gpuMemory: ChartPanel

  /// The window's two controls that live outside the cards' headers: the toolbar takes the
  /// picker of which cards are open, and the CPU card shows the button until monitoring starts.
  let viewPicker = NSSegmentedControl(
    labels: ["CPU", "GPU"],
    trackingMode: .selectAny,
    target: nil,
    action: nil
  )

  let startButton = NSButton(title: "Start Monitoring…", target: nil, action: nil)
  // Links that start monitoring again from the headers: the CPU card's once it has plotted
  // samples and its button is gone, and the GPU card's while the CPU card is closed.
  let cpuStartLink = LinkButton("Restart…")
  let gpuStartLink = LinkButton("Start Monitoring…")
  private let gpuPicker = NSPopUpButton(frame: .zero, pullsDown: false)
  let cpuCard: Card
  let gpuCard: Card
  // Which cards are open. A card on its way out stays on screen until its animation ends.
  var showsCPU = true
  var showsGPU = false
  /// The one GPU the GPU card is limited to, by its place in `gpus`; nil while it shows them all.
  private(set) var selectedGPU: Int?
  // Called after a card has been opened or closed, so the window can follow, and after the
  // GPU card has been limited to a GPU or shown them all.
  var onViewChange: (() -> Void)?
  var onGPUSelect: (() -> Void)?
  private(set) var state = MonitorState.idle(cancelled: false)
  /// Whether a sample has been plotted.
  ///
  /// Until one has, the CPU card has only its blank state to say things in; afterwards its rows
  /// stay up and its header does the talking.
  var hasSamples = false
  /// The CPU card's header: a mark and a word for the state, then what is limiting the CPU.
  let cpuMark = NSImageView()

  let cpuState = PlainLabel(
    oneLine: "",
    font: .systemFont(ofSize: 11, weight: .medium),
    color: .labelColor
  )

  let limitsCaption = PlainLabel(oneLine: "Limits")
  let limitsValue = PlainLabel(oneLine: "")
  // The GPU card's header has room for one remark, with a mark if it is a warning.
  let gpuMark = NSImageView()
  let gpuRemark = PlainLabel(oneLine: "")
  // What the CPU card shows in place of its rows before there is anything to plot.
  let blank = NSStackView()
  let blankSymbol = NSImageView()

  let blankTitle = PlainLabel(
    oneLine: "",
    font: .preferredFont(forTextStyle: .headline),
    color: .labelColor
  )

  let blankSpinner = NSProgressIndicator()
  let blankMessage = PlainLabel(wrappingLabelWithString: "")
  static let cardMinWidth: CGFloat = 360
  // Where the cards sit: 10 pt in from the window's sides and bottom and 6 below the
  // toolbar, which leaves space of its own, with 10 between them.
  static let insets = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
  static let gap: CGFloat = 10
  // Each open card's height is tied to this view's. A closed card's tie is only a
  // preference, so that its rows' minimum height cannot hold the window up.
  var cpuCardHeight: NSLayoutConstraint!
  var gpuCardHeight: NSLayoutConstraint!
  // The cards' places across: the CPU card's left edge and width and the GPU card's width,
  // the GPU card always sitting a gap to the right of the CPU card. They follow this view's
  // width, except while a card opens or closes, when they are animated. A closed card
  // keeps its width just outside the window on its own side, which is where it opens from.
  var cpuLeft: NSLayoutConstraint!
  var cpuWidth: NSLayoutConstraint!
  var gpuWidth: NSLayoutConstraint!
  // A card opening or closing: which, the content width it is all moving to, and which
  // change this is, so that the end of one cut short by another does nothing.
  var moving: (opening: Card?, closing: Card?, toWidth: CGFloat, generation: Int)?
  var moves = 0

  var moveGeneration: Int? { moving?.generation }

  /// The title of the item that shows every GPU, in the GPU card's pop-up and the View menu, which
  /// says how many there are.
  static func allGPUsTitle(count: Int) -> String { count == 2 ? "Both GPUs" : "All \(count) GPUs" }

  /// The narrowest the content can be with the cards now open.
  var minimumWidth: CGFloat {
    let both = showsCPU && showsGPU
    return (both ? 2 * Dashboard.cardMinWidth + Dashboard.gap : Dashboard.cardMinWidth)
      + Dashboard.insets.left + Dashboard.insets.right
  }

  var cpuPanels: [ChartPanel] { cpuCard.panels }

  /// The cards as they are now, the CPU card's first, for the layout check.
  var cardStates: [(frame: NSRect, alpha: CGFloat, hidden: Bool)] {
    [cpuCard, gpuCard].map { ($0.frame, $0.alphaValue, $0.isHidden) }
  }

  var gpuPanels: [ChartPanel] { gpuCard.panels }

  var panels: [ChartPanel] { cpuPanels + gpuPanels }

  /// More than 1 in a window too narrow for the rows' one-line headers: then the values move
  /// under the titles, on as many lines as the fullest row needs, and what the cards' headers
  /// have to say moves under theirs.
  var rows = 1
  /// What the CPU's readings last gave for the integrated GPU, whose driver publishes neither
  /// its power nor its clock: the power from the kernel or powermetrics, the clock from
  /// powermetrics only.
  var integratedGPU: (at: Date, mhz: Double?, watts: Double?)?

  /// Where the CPU's readings come from: the latest sample's source, kept after monitoring
  /// stops; nil before the first sample.
  var readingsSource: ReadingsSource? {
    didSet {
      if readingsSource != oldValue {
        describeCPURows()
        refresh()
      }
    }
  }

  /// Whether starting will read the kernel first, which needs no password (`Monitor.triesKernel`):
  /// only with that experiment turned on.
  var triesKernel = false {
    didSet {
      if triesKernel != oldValue {
        describeCPURows()
        refresh()
      }
    }
  }

  /// Why the kernel's statistics couldn't be used, when Power Gauge has gone to powermetrics
  /// instead.
  var fallbackReason: String? {
    didSet { if fallbackReason != oldValue { refresh() } }
  }

  /// Where the GPUs' utilisation comes from, which the GPU readings are taken with and the
  /// utilization row's "n/a" tooltips follow.
  var gpuUtilizationSource: GPU.UtilizationSource = .driver {
    didSet { if gpuUtilizationSource != oldValue { describeGPURows() } }
  }

  // The GPUs now powered down, and those seen powered up at least once, by place in `gpus`.
  var gpusOff: Set<Int> = []
  var gpusSeenOn: Set<Int> = []
  let baseNote: Note
  /// How the processor's limit bits are laid out (see `LimitBits`): this Mac's, or a fixed one for
  /// the snapshot mode, so that its pictures do not depend on the Mac.
  var limitLayout = LimitBits.current
  /// When the last CPU sample arrived, so that a long wait for the next one shows as a gap.
  var lastArrival: TimeInterval?
  /// The SMC's prochot count in the sample before.
  var lastProchots: Int?

  init(gpus: [GPU], machine: MachineInfo = .current) {
    self.gpus = gpus
    self.machine = machine
    let memoryTop = max(1, machine.memoryGB.rounded(.up))
    memory = ChartPanel(
      title: "Memory",
      unit: "GB",
      series: [
        Series(name: "Used", color: .systemBlue, format: "%.1f"),
        Series(name: "Compressed", color: .systemOrange, format: "%.1f"),
        Series(name: "Swap", color: .systemRed, format: "%.1f"),
      ],
      minTop: memoryTop,
      step: memoryTop
    )
    baseNote = Note(
      name: "Base",
      value: machine.baseMHz.map { String(format: "%.2f", $0 / Units.mhzPerGHz) }
        ?? ChartPanel.noValue,
      color: machine.baseMHz == nil ? .secondaryLabelColor : .labelColor,
      dashed: machine.baseMHz != nil
    )
    // GPUs of one make share its colour, so the first one's lines are solid and each one
    // after has a pattern of its own. A memory clock is drawn in its GPU's colour, faded.
    func perGPU(_ format: String) -> [Series] {
      gpus.map {
        Series(name: $0.short, color: $0.color, format: format, dash: Dashboard.dash(of: $0))
      }
    }
    gpuPower = ChartPanel(title: "Power", unit: "W", series: perGPU("%.1f"), minTop: 20, step: 20)
    gpuClock = ChartPanel(
      title: "Clock",
      unit: "MHz",
      series: gpus.flatMap {
        [
          Series(
            name: $0.short + " core",
            color: $0.color,
            format: "%.0f",
            dash: Dashboard.dash(of: $0)
          ),
          Series(
            name: $0.short + " memory",
            color: $0.color.withAlphaComponent(Dashboard.memoryClockOpacity),
            format: "%.0f",
            dash: Dashboard.dash(of: $0)
          ),
        ]
      },
      minTop: 1000,
      step: 1000
    )
    gpuTemperature = ChartPanel(
      title: "Temperature",
      unit: "°C",
      series: perGPU("%.0f"),
      minTop: 100,
      step: 20
    )
    gpuUtilization = ChartPanel(
      title: "Utilization",
      unit: "%",
      series: perGPU("%.0f"),
      minTop: 100,
      step: 100
    )
    gpuMemory = ChartPanel(title: "Memory", unit: "GB", series: perGPU("%.2f"), minTop: 1, step: 1)

    // Which GPUs the GPU card shows is picked in its header. With one GPU there is
    // nothing to pick, and the header names it instead.
    gpuPicker.controlSize = .small
    gpuPicker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    // A very long GPU name is cut short in the pop-up rather than widening the window.
    gpuPicker.setContentCompressionResistancePriority(
      NSLayoutConstraint.Priority.defaultLow.stepped(1),
      for: .horizontal
    )
    if gpus.count > 1 {
      gpuPicker.menu?.addItem(
        NSMenuItem(title: Dashboard.allGPUsTitle(count: gpus.count), action: nil, keyEquivalent: "")
      )
      gpuPicker.menu?.addItem(.separator())
    }
    // An item's tag is its GPU's place in `gpus` plus one; the item for all of them has none.
    for (index, gpu) in gpus.enumerated() {
      let item = NSMenuItem(title: gpu.name, action: nil, keyEquivalent: "")
      item.tag = Dashboard.tag(forGPU: index)
      gpuPicker.menu?.addItem(item)
    }
    // The headers' first lines are as tall as the tallest thing either holds, so no
    // height is assumed for a control that each macOS version draws its own size.
    let lineHeight = max(
      PlainLabel(oneLine: "CPU", font: .preferredFont(forTextStyle: .headline)).fittingSize.height,
      gpus.count > 1 ? gpuPicker.fittingSize.height : 0
    ).rounded(.up)
    func group(_ views: [NSView], spacing: CGFloat) -> NSStackView {
      let stack = NSStackView(views: views)
      stack.distribution = .fill
      stack.spacing = spacing
      stack.setHuggingPriority(.defaultHigh, for: .horizontal)
      return stack
    }
    let cpuFixed = group([cpuMark, cpuState, cpuStartLink], spacing: Dashboard.markSpacing)
    cpuFixed.setCustomSpacing(Dashboard.linkSpacing, after: cpuState)
    let gpuDetail = group([gpuMark, gpuRemark, gpuStartLink], spacing: Dashboard.markSpacing)
    gpuDetail.setCustomSpacing(Dashboard.linkSpacing, after: gpuRemark)
    cpuCard = Card(
      header: CardHeader(
        title: "CPU",
        subtitle: machine.processor,
        fixed: cpuFixed,
        detail: group([limitsCaption, limitsValue], spacing: Dashboard.captionSpacing),
        detailFirst: false,
        lineHeight: lineHeight
      ),
      panels: [power, frequency, temperature, utilization, memory]
    )
    gpuCard = Card(
      header: CardHeader(
        title: "GPU",
        subtitle: gpus.count == 1 ? gpus[0].name : nil,
        fixed: gpus.count > 1 ? gpuPicker : nil,
        detail: gpuDetail,
        detailFirst: true,
        lineHeight: lineHeight
      ),
      panels: [gpuPower, gpuClock, gpuTemperature, gpuUtilization, gpuMemory]
    )
    super.init(frame: .zero)
    let inner = Dashboard.windowSize.width - Dashboard.insets.left - Dashboard.insets.right
    // Puts a card under the toolbar, and gives back the tie of its height to this view's,
    // which holds only while the card is open.
    func place(_ card: Card) -> NSLayoutConstraint {
      card.translatesAutoresizingMaskIntoConstraints = false
      addSubview(card)
      card.topAnchor.constraint(equalTo: topAnchor, constant: Dashboard.insets.top).isActive = true
      let height = {
        card.heightAnchor.constraint(
          equalTo: self.heightAnchor,
          constant: -(Dashboard.insets.top + Dashboard.insets.bottom)
        )
      }
      let preferred = height()
      preferred.priority = .defaultLow
      preferred.isActive = true
      return height()
    }
    cpuCardHeight = place(cpuCard)
    gpuCardHeight = place(gpuCard)
    cpuLeft = cpuCard.leadingAnchor.constraint(
      equalTo: leadingAnchor,
      constant: Dashboard.insets.left
    )
    cpuWidth = cpuCard.widthAnchor.constraint(equalToConstant: inner)
    gpuWidth = gpuCard.widthAnchor.constraint(equalToConstant: inner)
    NSLayoutConstraint.activate([
      cpuLeft,
      cpuWidth,
      gpuWidth,
      gpuCard.leadingAnchor.constraint(equalTo: cpuCard.trailingAnchor, constant: Dashboard.gap),
    ])
    gpuCard.isHidden = true
    cpuCardHeight.isActive = true

    viewPicker.target = self
    viewPicker.action = #selector(viewPicked)
    viewPicker.setSelected(true, forSegment: Dashboard.cpuSegment)
    viewPicker.setEnabled(!gpus.isEmpty, forSegment: Dashboard.gpuSegment)
    viewPicker.setToolTip("Show or hide the CPU panel", forSegment: Dashboard.cpuSegment)
    viewPicker.setToolTip(
      gpus.isEmpty ? "No GPU found" : "Show or hide the GPU panel",
      forSegment: Dashboard.gpuSegment
    )
    viewPicker.setAccessibilityLabel("Panels")
    gpuPicker.target = self
    gpuPicker.action = #selector(gpuPicked)
    gpuPicker.setAccessibilityLabel("GPUs shown")

    // Text in the headers that may be longer than its place is cut short, and resting
    // the pointer on it shows the rest. The limits can also be selected, to copy an error.
    for mark in [cpuMark, gpuMark, blankSymbol] {
      mark.cell?.setAccessibilityElement(false)  // the words beside each mark say what it means
      mark.setContentHuggingPriority(.required, for: .horizontal)
      mark.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    for field in [limitsValue, gpuRemark] {
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      field.allowsExpansionToolTips = true
    }
    limitsValue.isSelectable = true
    gpuMark.contentTintColor = .systemRed

    // The blank state: a symbol, what the card is waiting for, and the button that starts
    // it. Its parts keep their places when hidden, so nothing moves as the state changes.
    blankSymbol.contentTintColor = .secondaryLabelColor
    blankMessage.font = .systemFont(ofSize: 11)
    blankMessage.textColor = .secondaryLabelColor
    blankMessage.alignment = .center
    blankMessage.isSelectable = true  // an error from powermetrics is worth being able to copy
    blankMessage.maximumNumberOfLines = Dashboard.blankMessageLines
    blankMessage.cell?.truncatesLastVisibleLine = true
    blankMessage.preferredMaxLayoutWidth = Dashboard.blankMessageWidth
    blankSpinner.style = .spinning
    blankSpinner.controlSize = .small
    let message = group([blankSpinner, blankMessage], spacing: Dashboard.blankSpacing)
    // Room for two lines whatever the message, so that going from the two-line
    // explanation to a one-line "Waiting…" and back moves nothing.
    message.heightAnchor.constraint(greaterThanOrEqualToConstant: Dashboard.twoLinesHeight)
      .isActive = true
    for view in [blankSymbol, blankTitle, message, startButton] { blank.addArrangedSubview(view) }
    blank.orientation = .vertical
    blank.alignment = .centerX
    blank.spacing = Dashboard.blankSpacing
    blank.detachesHiddenViews = false
    blank.setCustomSpacing(Dashboard.spaceAfterSymbol, after: blankSymbol)
    blank.setCustomSpacing(Dashboard.spaceAfterMessage, after: message)
    blank.translatesAutoresizingMaskIntoConstraints = false
    cpuCard.body.addSubview(blank)
    NSLayoutConstraint.activate([
      blank.centerXAnchor.constraint(equalTo: cpuCard.body.centerXAnchor),
      blank.centerYAnchor.constraint(equalTo: cpuCard.body.centerYAnchor),
      blank.widthAnchor.constraint(lessThanOrEqualToConstant: Dashboard.blankWidth),
    ])

    frequency.reference = machine.baseMHz.map { $0 / Units.mhzPerGHz }
    // Behind the frequency plot, a band wherever something was limiting the CPU: amber
    // for its power budget, red for heat or macOS (see CPULimits.band). With per-core
    // frequencies on, every CPU has a thin line, under the average drawn bold.
    frequency.bands = [
      ("Power limited", NSColor.systemOrange.withAlphaComponent(Dashboard.powerBandOpacity)),
      ("Throttled", NSColor.systemRed.withAlphaComponent(Dashboard.throttledBandOpacity)),
    ]
    frequency.keepsEach = true
    frequency.bold = FrequencySeries.average
    // The frequency row has the widest header of the CPU card, so it decides how many
    // lines the headers take. It is given its full width now, with a stand-in for the
    // note the first sample brings, so that starting to monitor does not change that.
    frequency.notes = [
      baseNote,
      Note(name: "Ceiling", value: "5.00"),
      Note(name: "Turbo", value: "Active"),
    ]
    frequency.countsEverySeries = true
    for panel in cpuPanels { panel.setAccessibilityLabel("CPU " + panel.title) }
    memory.setAccessibilityLabel("Memory")
    // A processor without an integrated GPU, such as a Xeon, has no graphics power to list.
    if !gpus.contains(where: { $0.integrated }) { power.hiddenSeries = [PowerSeries.graphics] }
    describeCPURows()
    utilization.reasons = [
      UtilizationSeries.cpu: "Measured between two samples, so the first sample has none."
    ]
    memory.reasons = [MemorySeries.swap: "macOS didn't report how much swap is in use."]
    memory.notes = [Note(name: "Total", value: String(format: "%.1f", machine.memoryGB))]
    for panel in gpuPanels { panel.setAccessibilityLabel("GPU " + panel.title) }
    // Hovering one chart moves the time marker on all of them.
    let all = panels
    for panel in all { panel.onHover = { age in all.forEach { $0.hoverAge = age } } }
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(displayOptionsChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// Increase Contrast or Differentiate Without Colour has been switched; both change the drawing.
  @objc private func displayOptionsChanged() {
    ([cpuCard, gpuCard] as [NSView] + panels).forEach { $0.needsDisplay = true }
  }

  @objc private func viewPicked(_ sender: NSSegmentedControl) {
    open(
      cpu: sender.isSelected(forSegment: Dashboard.cpuSegment),
      gpu: sender.isSelected(forSegment: Dashboard.gpuSegment)
    )
  }

  /// How many minutes back the plots go: 2, 5 or 10.
  var historyMinutes: Int {
    get { ChartPanel.span / Units.secondsPerMinute }
    set {
      ChartPanel.span = newValue * Units.secondsPerMinute
      panels.forEach { $0.needsDisplay = true }
      needsLayout = true  // the longest time a header may show has changed
    }
  }

  /// Whether the frequency row plots a thin line for every CPU, under the average drawn bold,
  /// instead of the fastest, average and slowest; the thin lines' edges are the fastest and
  /// slowest, and the header gives their range.
  var showsPerCoreFrequencies: Bool {
    get { frequency.showsEach }
    set {
      frequency.showsEach = newValue
      frequency.hiddenSeries = newValue ? [FrequencySeries.fastest, FrequencySeries.slowest] : []
      needsLayout = true  // the row's header may now need more lines, or fewer
    }
  }

  /// Limits the GPU card to one GPU, by its place in `gpus`, or shows them all for nil.
  func select(gpu index: Int?) {
    selectedGPU = index
    let hidden = Set(gpus.indices.filter { index != nil && $0 != index })
    for panel in [gpuPower, gpuTemperature, gpuUtilization, gpuMemory] {
      panel.hiddenSeries = hidden
    }
    gpuClock.hiddenSeries = Set(
      hidden.flatMap {
        [Dashboard.coreClockSeries(ofGPU: $0), Dashboard.memoryClockSeries(ofGPU: $0)]
      }
    )
    if let index = index {
      gpuPicker.selectItem(withTag: Dashboard.tag(forGPU: index))
    } else {
      gpuPicker.selectItem(at: 0)
    }
    refresh()
    needsLayout = true  // the headers may now fit on one line, or need two
    onGPUSelect?()
  }

  @objc private func gpuPicked(_ sender: NSPopUpButton) {
    select(gpu: Dashboard.gpu(forTag: sender.selectedTag()))
  }

  /// Moves to a new monitoring state and shows it.
  func show(state new: MonitorState) {
    guard new != state else { return }
    state = new
    refresh()
  }

  override func layout() {
    if moving == nil { placeCards() }
    super.layout()
    let before = rows
    updateRows()
    if rows != before { super.layout() }
  }

  /// The content size the window opens at: tall enough for five rows with quarter labels.
  static let windowSize = NSSize(width: 760, height: 580)

  /// The pattern of a GPU's lines, which tells it from the others of its make.
  private static func dash(of gpu: GPU) -> [CGFloat] {
    ChartPanel.patterns[(gpu.nth - 1) % ChartPanel.patterns.count]
  }

  /// A memory clock is drawn faded.
  private static let memoryClockOpacity: CGFloat = 0.5
  // The spacing in the cards' headers: between a mark and its words, before a link, and between
  // a caption and its value.
  private static let markSpacing: CGFloat = 4
  private static let linkSpacing: CGFloat = 8
  private static let captionSpacing: CGFloat = 6
  // The blank state: its width and its message's, the lines the message may take and the room it
  // keeps for two of them, and the spacing between its parts.
  private static let blankWidth: CGFloat = 340
  private static let blankMessageWidth: CGFloat = 316
  private static let blankMessageLines = 5
  private static let twoLinesHeight: CGFloat = 28
  private static let blankSpacing: CGFloat = 6
  private static let spaceAfterSymbol: CGFloat = 10
  private static let spaceAfterMessage: CGFloat = 14
  // The bands behind the frequency plot, faint enough for the lines to show through.
  private static let powerBandOpacity: CGFloat = 0.18
  private static let throttledBandOpacity: CGFloat = 0.16
}
