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
/// Subclass of NSSliderCell that tracks the exact mouse-drag lifecycle so mouse release
/// commits reliably across macOS versions (including macOS 15, where continuous sliders
/// may not fire a trailing action on mouse-up when the snapped tick value is unchanged).
@MainActor
final class TrackingSliderCell: NSSliderCell {
  private(set) var isTrackingMouse = false
  var onTrackingEnd: ((_ mouseIsUp: Bool) -> Void)?
  var onTrace: ((String) -> Void)?

  override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
    isTrackingMouse = true
    let shouldContinue = super.startTracking(at: startPoint, in: controlView)
    onTrace?("start(pt=\(startPoint),ok=\(shouldContinue),v=\(Int(doubleValue.rounded())))")
    if !shouldContinue { isTrackingMouse = false }
    return shouldContinue
  }

  override func continueTracking(
    last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView
  ) -> Bool {
    let shouldContinue = super.continueTracking(
      last: lastPoint, current: currentPoint, in: controlView)
    onTrace?("cont(cur=\(currentPoint),ok=\(shouldContinue),v=\(Int(doubleValue.rounded())))")
    return shouldContinue
  }

  override func stopTracking(
    last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView,
    mouseIsUp flag: Bool
  ) {
    super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
    isTrackingMouse = false
    onTrace?("stop(pt=\(stopPoint),up=\(flag),v=\(Int(doubleValue.rounded())))")
    onTrackingEnd?(flag)
  }
}

/// Menu-bar intensity control: a native, keyboard-focusable slider with a live percent
/// readout. Mouse drags and arrow keys both move in real one-percentage-point steps
/// (the sixteen tick marks at 15%...30% keep every committed value an integer). While a
/// drag is tracking, every action previews through `onPreview` without touching storage;
/// mouse release, key presses, and accessibility adjustments additionally invoke `onCommit`
/// so the shown value is persisted.
@MainActor
final class IntensitySliderView: NSView {
  let slider: NSSlider
  let percentLabel: NSTextField
  private let trackingCell: TrackingSliderCell

  var onPreview: ((Int) -> Void)?
  var onCommit: (() -> Void)?
  var onCancel: (() -> Void)?

  init(intensity: Int, title titleText: String = "Intensity") {
    let title = NSTextField(labelWithString: titleText)
    title.font = .menuFont(ofSize: 0)
    title.textColor = .secondaryLabelColor
    percentLabel = NSTextField(labelWithString: "\(intensity)%")
    percentLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
    percentLabel.textColor = .labelColor
    percentLabel.alignment = .right
    let cell = TrackingSliderCell()
    trackingCell = cell
    slider = NSSlider(frame: NSRect(x: 16, y: 8, width: 236, height: 28))
    slider.cell = cell
    slider.minValue = Double(Settings.intensityRange.lowerBound)
    slider.maxValue = Double(Settings.intensityRange.upperBound)
    slider.doubleValue = Double(intensity)
    slider.isContinuous = true
    slider.numberOfTickMarks = Settings.intensityRange.count
    slider.tickMarkPosition = .below
    slider.allowsTickMarkValuesOnly = true
    slider.setAccessibilityLabel(titleText)
    slider.setAccessibilityValueDescription("\(intensity)%")
    super.init(frame: NSRect(x: 0, y: 0, width: 268, height: 68))
    slider.target = self
    slider.action = #selector(adjust(_:))
    cell.onTrackingEnd = { [weak self] mouseIsUp in
      guard let self else { return }
      if mouseIsUp {
        let value = Int(self.slider.doubleValue.rounded())
        self.reflect(percent: value)
        self.onPreview?(value)
        self.onCommit?()
      } else {
        self.onCancel?()
      }
    }
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
    // Mouse-drag actions preview only; release commits via TrackingSliderCell.stopTracking.
    // Keyboard and accessibility adjustments run outside mouse tracking and commit immediately.
    onPreview?(value)
    if !trackingCell.isTrackingMouse { onCommit?() }
  }
}
