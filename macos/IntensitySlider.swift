import AppKit

/// Smallest native focusable host for the intensity control, anchored at the menu bar
/// item. Nonactivating: the panel becomes the key window without activating this app,
/// so hardware keyboard focus reaches the slider while the frontmost application (and
/// its exclusion eligibility) is untouched. Esc and clicking away both close it.
@MainActor
final class IntensityPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init(view: IntensitySliderView, title: String = "Intensity") {
    super.init(
      contentRect: view.bounds,
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered, defer: false)
    self.title = title
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    isExcludedFromWindowsMenu = true
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    contentView = view
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
  }

  override func cancelOperation(_ sender: Any?) { performClose(sender) }

  override func resignKey() {
    super.resignKey()
    // Clicking outside the panel moves key focus elsewhere: treat that as closing.
    if isVisible { performClose(nil) }
  }
}

/// Menu-bar intensity control: a native, keyboard-focusable slider with a live percent
/// readout. Mouse drags and arrow keys both move in real one-percentage-point steps
/// (the sixteen tick marks at 15%...30% keep every committed value an integer). While a
/// drag is tracking, every action previews through `onPreview` without touching storage;
/// the concluding action of each gesture - mouse release, key press, or accessibility
/// adjustment - additionally invokes `onCommit` so the shown value is persisted.
@MainActor
final class IntensitySliderView: NSView {
  let slider: NSSlider
  let percentLabel: NSTextField

  var onPreview: ((Int) -> Void)?
  var onCommit: (() -> Void)?

  init(intensity: Int, title titleText: String = "Intensity") {
    let title = NSTextField(labelWithString: titleText)
    title.font = .menuFont(ofSize: 0)
    title.textColor = .secondaryLabelColor
    percentLabel = NSTextField(labelWithString: "\(intensity)%")
    percentLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
    percentLabel.textColor = .labelColor
    percentLabel.alignment = .right
    slider = NSSlider(
      value: Double(intensity),
      minValue: Double(Settings.intensityRange.lowerBound),
      maxValue: Double(Settings.intensityRange.upperBound),
      target: nil, action: nil)
    slider.isContinuous = true
    slider.numberOfTickMarks = Settings.intensityRange.count
    slider.tickMarkPosition = .below
    slider.allowsTickMarkValuesOnly = true
    slider.setAccessibilityLabel(titleText)
    slider.setAccessibilityValueDescription("\(intensity)%")
    super.init(frame: NSRect(x: 0, y: 0, width: 268, height: 68))
    slider.target = self
    slider.action = #selector(adjust(_:))
    addSubview(title)
    addSubview(percentLabel)
    addSubview(slider)
    title.frame = NSRect(x: 16, y: 40, width: 150, height: 18)
    percentLabel.frame = NSRect(x: 166, y: 40, width: 86, height: 18)
    slider.frame = NSRect(x: 16, y: 8, width: 236, height: 28)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

  /// The percent currently shown by the control; assigning it moves the knob silently.
  var percent: Int {
    get { Int(slider.doubleValue.rounded()) }
    set {
      slider.doubleValue = Double(newValue)
      reflect(percent: newValue)
    }
  }

  private func reflect(percent: Int) {
    percentLabel.stringValue = "\(percent)%"
    slider.setAccessibilityValueDescription("\(percent)%")
  }

  @objc private func adjust(_ sender: NSSlider) {
    let value = Int(sender.doubleValue.rounded())
    reflect(percent: value)
    // Mouse-down and drag actions preview; the concluding action of the gesture
    // (mouse-up, key press, accessibility adjustment) commits what is already shown.
    let tracking =
      NSApp.currentEvent.map { $0.type == .leftMouseDown || $0.type == .leftMouseDragged }
      ?? false
    onPreview?(value)
    if !tracking { onCommit?() }
  }
}
