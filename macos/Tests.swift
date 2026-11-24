import AppKit

func hasASCIILetter(_ text: String) -> Bool {
  text.contains { $0.isASCII && $0.isLetter }
}

func hasCJK(_ text: String) -> Bool {
  text.contains { ("\u{4E00}"..."\u{9FFF}").contains($0) }
}

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@MainActor
func settingsTests(_ scratch: URL) throws {
  let url = scratch.appendingPathComponent("settings-tests/settings.json")
  let missing = try Settings.load(from: url)
  require(missing == Settings(), "missing settings use defaults")
  let partial = try JSONDecoder().decode(Settings.self, from: Data("{\"enabled\":false}".utf8))
  require(!partial.enabled && partial.intensity == 20, "partial settings keep defaults")
  require(partial.language == nil, "old settings omit language")
  let unknown = try JSONDecoder().decode(
    Settings.self,
    from: Data("{\"enabled\":false,\"intensity\":15,\"language\":\"zh-Hant\"}".utf8))
  require(
    !unknown.enabled && unknown.intensity == 15 && unknown.language == nil,
    "unknown language does not reset settings")
  require(
    AppLanguage.resolved(saved: nil, preferred: ["zh-Hans-CN"]) == .zhHans, "simplified default")
  require(
    AppLanguage.resolved(saved: nil, preferred: ["zh-Hant-TW"]) == .en, "traditional uses English")
  require(AppLanguage.resolved(saved: nil, preferred: ["en-US"]) == .en, "english default")
  require(AppLanguage.resolved(saved: nil, preferred: []) == .en, "missing locale uses English")
  require(AppLanguage.resolved(saved: "en", preferred: ["zh-Hans-CN"]) == .en, "saved choice wins")
  var chosen = Settings()
  chosen.language = "zh-Hans"
  chosen.intensity = 25
  try chosen.save(to: url)
  let reopened = try Settings.load(from: url)
  require(reopened.language == "zh-Hans" && reopened.intensity == 25, "language reopens")
  let omitted = Settings()
  try omitted.save(to: url)
  let omittedText = String(decoding: try Data(contentsOf: url), as: UTF8.self)
  require(!omittedText.contains("\"language\""), "unset language is not written")
  let chinese = MenuText.make(.zhHans)
  let english = MenuText.make(.en)
  require(
    chinese.commandLabels.allSatisfy { !hasASCIILetter($0) }, "Chinese commands stay Chinese")
  require(english.commandLabels.allSatisfy { !hasCJK($0) }, "English commands stay English")
  let expectedIntensities = Settings.intensityRange.map { "\($0)%" }
  require(chinese.intensities == expectedIntensities, "Chinese intensity steps")
  require(english.intensities == expectedIntensities, "English intensity steps")
  require(chinese.intensityTitle(17) == "强度 - 17%", "Chinese intensity menu row")
  require(english.intensityTitle(17) == "Intensity - 17%", "English intensity menu row")
  var settings = Settings()
  settings.texture = "unknown"
  settings.intensity = 99
  settings.exclusions = [" com.example.fixture ", "com.example.fixture", ""]
  try settings.save(to: url)
  let normalized = try Settings.load(from: url)
  require(
    normalized.texture == "ClassicMatte" && normalized.intensity == 20, "invalid values normalized")
  require(normalized.exclusions == ["com.example.fixture"], "exclusions normalized")
  for outOfRange in [0, 14, 31, 99] {
    settings.intensity = outOfRange
    settings.normalize()
    require(settings.intensity == 20, "out-of-range intensity normalizes to default")
  }
  for interior in Settings.intensityRange {
    settings.intensity = interior
    settings.normalize()
    require(settings.intensity == interior, "one-point intensities inside 15...30 stay")
  }
  settings.intensity = 17
  try settings.save(to: url)
  let roundTrip = try Settings.load(from: url)
  require(roundTrip.intensity == 17, "interior intensity round-trips")
  for legacy in [15, 20, 25, 30] {
    settings.intensity = legacy
    settings.normalize()
    require(settings.intensity == legacy, "legacy intensity \(legacy) migrates unchanged")
  }
  settings = normalized
  settings.enabled = false
  try settings.save(to: url)
  let replaced = try Settings.load(from: url)
  require(replaced == settings, "atomic replacement persists settings")
  try Data("not json".utf8).write(to: url)
  do {
    _ = try Settings.load(from: url)
    require(false, "corrupt settings must report failure")
  } catch {}
  let now = Date()
  for enabled in [false, true] {
    for snoozed in [false, true] {
      for excluded in [false, true] {
        settings.enabled = enabled
        settings.exclusions = excluded ? ["fixture"] : []
        let visibility = Visibility(snoozeUntil: snoozed ? now.addingTimeInterval(60) : nil)
        require(
          visibility.isVisible(settings: settings, foreground: "fixture", now: now)
            == (enabled && !snoozed && !excluded), "visibility truth table")
      }
    }
  }
  settings.enabled = true
  settings.exclusions = []
  require(
    Visibility(snoozeUntil: now).isVisible(settings: settings, foreground: nil, now: now),
    "snooze expires at deadline")
  print(
    "PASS: settings defaults, normalization, atomic replacement, corruption and visibility states")
}

@MainActor
func renderSyntheticSliderSnapshots(to evidence: URL) throws {
  try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
  for intensity in [15, 17, 20, 30] {
    let view = IntensitySliderView(intensity: intensity)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      require(false, "slider bitmap rep creation")
      return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      require(false, "slider synthetic PNG encoding")
      return
    }
    try png.write(to: evidence.appendingPathComponent("slider-\(intensity)-synthetic.png"))
  }
}

@MainActor
func textureTests(resources: URL, evidence: URL) throws {
  let store = try TextureStore(directory: resources.appendingPathComponent("Textures"))
  try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
  func render(_ image: CGImage, scale: CGFloat) -> CGContext {
    let context = CGContext(
      data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
      bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    TextureView.draw(
      image, in: context,
      bounds: CGRect(x: 0, y: 0, width: 1024 / scale, height: 1024 / scale), scale: scale)
    return context
  }
  var fingerprints = Set<Data>()
  for texture in store.catalog {
    var previousAlpha = 0
    for intensity in Settings.intensityRange {
      let image = try store.image(texture: texture.id, intensity: intensity)
      let normal = render(image, scale: 1)
      let retina = render(image, scale: 2)
      let bytes = Data(bytes: normal.data!, count: 4096 * 1024)
      require(
        bytes == Data(bytes: retina.data!, count: 4096 * 1024), "Retina physical pixels match 1x")
      require(bytes[0..<2048] == bytes[2048..<4096], "horizontal tile repeat")
      require(bytes[0..<4096] == bytes[(512 * 4096)..<(513 * 4096)], "vertical tile repeat")
      let alpha = stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
      require(alpha > previousAlpha, "strength increases opacity")
      previousAlpha = alpha
      fingerprints.insert(bytes.prefix(4096))
      func writeComposite() throws {
        // Render only invented paper/text bars. Never read the desktop or another window.
        let composite = CGContext(
          data: nil, width: 768, height: 512, bitsPerComponent: 8,
          bytesPerRow: 768 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        composite.setFillColor(NSColor.white.cgColor)
        composite.fill(CGRect(x: 0, y: 0, width: 768, height: 512))
        composite.setFillColor(NSColor(white: 0.18, alpha: 1).cgColor)
        for y in stride(from: 24, to: 490, by: 18) {
          for x in stride(from: 24, to: 730, by: 61) {
            composite.fill(CGRect(x: x, y: y, width: 49, height: 5))
          }
        }
        composite.draw(normal.makeImage()!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let bitmap = NSBitmapImageRep(cgImage: composite.makeImage()!)
        try bitmap.representation(using: .png, properties: [:])!.write(
          to: evidence.appendingPathComponent("\(texture.id)-\(intensity)-synthetic.png"))
      }
      if intensity == 20 { try writeComposite() }
      if texture.id == "ClassicMatte" && [15, 17, 30].contains(intensity) { try writeComposite() }
    }
  }
  require(
    fingerprints.count == Settings.textures.count * Settings.intensityRange.count,
    "all texture/intensity combinations differ")
  try renderSyntheticSliderSnapshots(to: evidence)
  print(
    "PASS: 4 textures x 16 intensities, monotonic strength, seamless repeats and 1x/2x equality")
}

@MainActor
func scheduleTests(fixture: URL, scratch: URL) throws {
  let zone = TimeZone(identifier: "America/New_York")!
  let minutes = try String(contentsOf: fixture, encoding: .utf8)
  for row in minutes.split(whereSeparator: \.isNewline) {
    let columns = row.split(separator: ",")
    let utcMinute = Int64(columns[0])!
    let wall = Int(columns[1])!
    var settings = ScheduleSettings()
    settings.timed = true
    settings.start = String(format: "%02d:%02d", wall / 60, wall % 60)
    settings.end = "04:00"
    let now = Date(timeIntervalSince1970: Double(utcMinute) * 60)
    let active = settings.evaluate(now: now, zone: zone, manual: true, suppressed: false)
    let before = settings.evaluate(
      now: now.addingTimeInterval(-60), zone: zone, manual: true, suppressed: false)
    require(active.visible == 1 && before.visible == 0, "shared DST fixture wall-time boundary")
  }
  let directory = scratch.appendingPathComponent("schedule")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("settings.json")
  try Data(
    #"{"enabled":false,"intensity":30,"schedule":{"timed":true,"start":42,"sunset":true,"latitude":"nope","longitude":"0"}}"#
      .utf8
  )
  .write(to: url)
  var settings = try Settings.load(from: url)
  require(!settings.enabled && settings.intensity == 30, "legacy fields survive malformed rules")
  require(
    !settings.schedule.validTime && !settings.schedule.validLocation, "malformed rules unavailable")
  settings.schedule.start = "21:00"
  try settings.save(to: url)
  let reopened = try Settings.load(from: url)
  require(reopened == settings, "rules round trip next to legacy fields")
  let blocked = directory.appendingPathComponent("blocked")
  try Data().write(to: blocked)
  let retryURL = blocked.appendingPathComponent("settings.json")
  do {
    try settings.save(to: retryURL)
    require(false, "failed save is reported")
  } catch {}
  try FileManager.default.removeItem(at: blocked)
  try settings.save(to: retryURL)
  let retried = try Settings.load(from: retryURL)
  require(retried == settings, "failed save can be retried")
  print("PASS: shared rule bridge, native DST fixture, compatible settings and retry")
}

@MainActor
final class TestDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let resources: URL
  let scratch: URL
  let skipForegroundTests: Bool
  var controller: AppController!
  var fixture: NSWindow?
  var fullscreenEntered = false
  var foregroundFixture: Process?
  var dragSamples: [(shown: Int?, persisted: Int, disk: Int?)] = []
  var usedProgrammaticCellDrag = false
  var dragScript: [(value: Double, up: Bool)] = []
  var dragTick = 0
  var dragSampler: Timer?

  init(resources: URL, scratch: URL, skipForegroundTests: Bool) {
    self.resources = resources
    self.scratch = scratch
    self.skipForegroundTests = skipForegroundTests
  }

  func configureController(_ candidate: AppController) {
    if skipForegroundTests {
      // Keep the real panel offscreen so paused foreground-switcher tests never steal focus.
      candidate.presentIntensityPanel = { panel, _ in
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel.orderBack(nil)
      }
      candidate.presentScheduleWindow = { window in
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
      }
      candidate.foregroundIdentityProvider = { "com.suepaper.synthetic.included" }
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      controller = try AppController(
        settingsDirectory: scratch.appendingPathComponent("lifecycle"), resources: resources)
      configureController(controller)
      if skipForegroundTests {
        try controller.start()
        exerciseMenu()
        return
      }
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 640, height: 420),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.title = "MattePulp synthetic test fixture"
      window.isReleasedWhenClosed = false
      window.backgroundColor = .white
      window.collectionBehavior = [.fullScreenPrimary]
      window.delegate = self
      let label = NSTextField(labelWithString: "Synthetic paper fixture - no desktop capture")
      label.frame = NSRect(x: 30, y: 160, width: 580, height: 60)
      window.contentView?.addSubview(label)
      window.makeKeyAndOrderFront(nil)
      fixture = window
      NSApp.activate(ignoringOtherApps: true)
      awaitForeground(ProcessInfo.processInfo.processIdentifier) {
        self.fixture?.makeKeyAndOrderFront(nil)
        require(NSApp.keyWindow === self.fixture, "synthetic fixture establishes keyboard focus")
        do {
          try self.controller.start()
          self.exerciseMenu()
        } catch { require(false, "overlay startup: \(error)") }
      }
    } catch { require(false, "native fixture startup: \(error)") }
  }

  func currentOverlayIntensity() -> Int? {
    guard let image = (controller.overlays.first?.contentView as? TextureView)?.image else {
      return nil
    }
    return controller.intensityImages.first { $0.value === image }?.key
  }

  func exerciseMenu() {
    require(!controller.overlays.isEmpty, "real displays have overlays")
    if !skipForegroundTests {
      require(NSApp.keyWindow === fixture, "overlay startup preserves fixture keyboard focus")
    }
    let old = controller.overlays
    for (overlay, screen) in zip(old, NSScreen.screens) {
      require(overlay.frame == screen.frame, "overlay uses full display point coordinates")
      require(
        overlay.ignoresMouseEvents && !overlay.canBecomeKey && !overlay.canBecomeMain,
        "overlay cannot receive pointer or keyboard focus")
      require(overlay.isVisible && overlay.isOnActiveSpace, "overlay visible on active Space")
      print("DISPLAY: frame=\(screen.frame) backingScale=\(screen.backingScaleFactor)")
    }
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    require(
      controller.overlays.count == NSScreen.screens.count,
      "display notification rebuilds current topology")
    require(old.allSatisfy { !$0.isVisible }, "rebuild closes previous overlays")
    let menu = controller.statusItem!.menu!
    controller.menuNeedsUpdate(menu)
    menu.performActionForItem(at: 0)
    require(
      !controller.settings.enabled && controller.overlays.allSatisfy { !$0.isVisible },
      "menu disables overlays")
    menu.performActionForItem(at: 0)
    let textureMenu = menu.item(at: 1)!.submenu!
    textureMenu.performActionForItem(at: 2)
    require(controller.settings.texture == "Parchment", "native menu applies texture")
    controller.menuNeedsUpdate(menu)
    let initialIntensityTitle = MenuText.resolved(saved: controller.settings.language)
      .intensityTitle(20)
    require(
      menu.item(at: 2)!.title == initialIntensityTitle,
      "menu row shows the current intensity percent")
    menu.performActionForItem(at: 2)
    exerciseIntensitySlider()
  }

  func dispatchKey(_ keyCode: UInt16, characters: String, to panel: IntensityPanel) {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber, context: nil,
      characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: keyCode)!
    if skipForegroundTests {
      panel.sendEvent(event)
    } else {
      NSApp.postEvent(event, atStart: false)
    }
  }

  /// Keyboard, accessibility, drag-preview/release, endpoint, cancellation, and storage-failure
  /// exercise of the native slider in its panel. Events are synthesized process-locally with
  /// no global input injection and drive genuine NSSlider responder and tracking machinery.
  func exerciseIntensitySlider() {
    let panel = controller.intensityPanel
    require(panel != nil && panel!.isVisible, "intensity row opens the native panel")
    require(
      panel!.styleMask.contains(.nonactivatingPanel) && panel!.canBecomeKey
        && !panel!.canBecomeMain,
      "intensity panel is focusable without activating the app")
    let view = panel!.contentView as! IntensitySliderView
    let slider = view.slider
    require(slider.window === panel, "slider lives in the native panel window")
    require(
      slider.minValue == 15 && slider.maxValue == 30 && slider.isContinuous
        && slider.numberOfTickMarks == 16 && slider.allowsTickMarkValuesOnly,
      "slider spans 15...30 with real one-point steps")
    require(
      view.percent == 20 && view.percentLabel.stringValue == "20%"
        && slider.accessibilityValueDescription() == "20%" && currentOverlayIntensity() == 20,
      "slider starts synchronized with the persisted intensity")
    let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      require(panel!.firstResponder === slider, "panel routes keyboard responder to the slider")
      if !self.skipForegroundTests {
        require(panel!.isKeyWindow, "panel takes keyboard focus on the slider")
        require(
          NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostBefore,
          "opening the panel does not change the frontmost application")
      }
      self.keyboardStep(view, keyCode: 124, characters: "\u{F703}", target: 21) {
        self.keyboardStep(view, keyCode: 124, characters: "\u{F703}", target: 22) {
          self.keyboardStep(view, keyCode: 123, characters: "\u{F702}", target: 21) {
            self.exerciseAccessibility(view)
          }
        }
      }
    }
  }

  func keyboardStep(
    _ view: IntensitySliderView, keyCode: UInt16, characters: String, target: Int,
    done: @escaping () -> Void
  ) {
    let panel = view.slider.window as! IntensityPanel
    dispatchKey(keyCode, characters: characters, to: panel)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      require(
        view.percent == target && self.controller.settings.intensity == target
          && self.controller.previewIntensity == nil
          && view.percentLabel.stringValue == "\(target)%"
          && view.slider.accessibilityValueDescription() == "\(target)%"
          && self.currentOverlayIntensity() == target,
        "keyboard step adjusts one point and synchronizes readout and overlay")
      let persisted = try? Settings.load(from: self.controller.settingsURL)
      require(
        persisted == self.controller.settings, "each keyboard adjustment is saved on commit")
      done()
    }
  }

  func exerciseAccessibility(_ view: IntensitySliderView) {
    let slider = view.slider
    _ = slider.accessibilityPerformIncrement()
    require(
      view.percent == 22 && controller.settings.intensity == 22
        && view.percentLabel.stringValue == "22%"
        && slider.accessibilityValueDescription() == "22%" && currentOverlayIntensity() == 22,
      "accessibility increment steps one point and updates overlay")
    require(
      (try? Settings.load(from: controller.settingsURL))?.intensity == 22,
      "accessibility increment saves on commit")
    _ = slider.accessibilityPerformDecrement()
    require(
      view.percent == 21 && controller.settings.intensity == 21
        && view.percentLabel.stringValue == "21%"
        && slider.accessibilityValueDescription() == "21%" && currentOverlayIntensity() == 21,
      "accessibility decrement steps one point and updates overlay")
    require(
      (try? Settings.load(from: controller.settingsURL))?.intensity == 21,
      "accessibility decrement saves on commit")
    // Drag from 21 through interior stops (19, 18) to interior 17, then test endpoints 15 and 30.
    exerciseDrag(view, from: 21, through: [19, 18], to: 17) {
      self.exerciseDrag(view, from: 17, through: [16], to: 15) {
        // Left arrow at lower endpoint 15 stays clamped at 15.
        self.keyboardStep(view, keyCode: 123, characters: "\u{F702}", target: 15) {
          self.exerciseDrag(view, from: 15, through: [22, 27], to: 30) {
            // Right arrow at upper endpoint 30 stays clamped at 30.
            self.keyboardStep(view, keyCode: 124, characters: "\u{F703}", target: 30) {
              self.exerciseDrag(view, from: 30, through: [23], to: 17) {
                self.exerciseCancelAndStorageFailure(view)
              }
            }
          }
        }
      }
    }
  }

  func knobTrackGeometry(of slider: NSSlider) -> (minX: CGFloat, maxX: CGFloat, midY: CGFloat) {
    let cell = slider.cell as! NSSliderCell
    let saved = slider.doubleValue
    slider.doubleValue = slider.minValue
    let minKnob = cell.knobRect(flipped: slider.isFlipped)
    slider.doubleValue = slider.maxValue
    let maxKnob = cell.knobRect(flipped: slider.isFlipped)
    slider.doubleValue = saved
    return (minKnob.midX, maxKnob.midX, minKnob.midY)
  }

  func sliderPoint(
    _ value: Double, of slider: NSSlider,
    geometry: (minX: CGFloat, maxX: CGFloat, midY: CGFloat)
  ) -> NSPoint {
    let fraction = (value - slider.minValue) / max(slider.maxValue - slider.minValue, 1)
    return NSPoint(
      x: geometry.minX + CGFloat(fraction) * (geometry.maxX - geometry.minX), y: geometry.midY)
  }

  func makeMouseEvent(
    _ type: NSEvent.EventType, value: Double, to slider: NSSlider,
    geometry: (minX: CGFloat, maxX: CGFloat, midY: CGFloat)
  ) -> NSEvent {
    let point = sliderPoint(value, of: slider, geometry: geometry)
    let event = NSEvent.mouseEvent(
      with: type, location: slider.convert(point, to: nil),
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: slider.window!.windowNumber, context: nil, eventNumber: 1,
      clickCount: 1, pressure: 1)
    require(event != nil, "synthetic drag event created")
    return event!
  }

  func assertDragOutcome(
    _ view: IntensitySliderView, from start: Int, to end: Int,
    samples: [(shown: Int?, persisted: Int, disk: Int?)]
  ) {
    let slider = view.slider
    require(
      controller.settings.intensity == end && view.percent == end
        && controller.previewIntensity == nil
        && view.percentLabel.stringValue == "\(end)%"
        && slider.accessibilityValueDescription() == "\(end)%"
        && currentOverlayIntensity() == end,
      "drag release commits final intensity \(end) and synchronizes UI and overlay")
    let persisted = try? Settings.load(from: controller.settingsURL)
    require(persisted?.intensity == end, "drag release persists \(end) to disk")
    require(
      samples.allSatisfy { $0.persisted == start && $0.disk == start },
      "no per-tick writes while the drag previews from \(start) to \(end)")
    require(
      samples.contains { $0.shown != nil && $0.shown != start && $0.shown != end },
      "drag previews intermediate levels on screen before release")
  }

  func exerciseDrag(
    _ view: IntensitySliderView, from start: Int, through stops: [Int], to end: Int,
    done: @escaping @MainActor () -> Void
  ) {
    let slider = view.slider
    let panel = slider.window as! IntensityPanel
    let cell = slider.cell as! TrackingSliderCell
    require(panel.isVisible && controller.intensityPanel === panel, "panel stays open before drag")
    let geometry = knobTrackGeometry(of: slider)
    let down = makeMouseEvent(.leftMouseDown, value: Double(start), to: slider, geometry: geometry)
    let hit = panel.contentView?.hitTest(down.locationInWindow)
    require(hit === slider, "drag start hits native slider")
    if slider.gestureRecognizers.isEmpty {
      // On macOS 15, NSSlider uses NSCell.trackMouse without a gesture recognizer and ends
      // tracking at mouse-down when no physical mouse button is held (pressedMouseButtons == 0).
      // Verify real window hit-testing on mouse-down, then drive NSSliderCell tracking
      // programmatically to test preview, zero-write drag ticks, and release persistence.
      usedProgrammaticCellDrag = true
      panel.sendEvent(down)
      var samples: [(shown: Int?, persisted: Int, disk: Int?)] = []
      var previous = sliderPoint(Double(start), of: slider, geometry: geometry)
      require(cell.startTracking(at: previous, in: slider), "cell starts tracking at drag origin")
      slider.sendAction(slider.action, to: slider.target)
      for value in stops + [end] {
        let next = sliderPoint(Double(value), of: slider, geometry: geometry)
        require(
          cell.continueTracking(last: previous, current: next, in: slider),
          "cell continues tracking through \(value)")
        slider.sendAction(slider.action, to: slider.target)
        let shown = currentOverlayIntensity()
        let disk = (try? Settings.load(from: controller.settingsURL))?.intensity
        samples.append((shown, controller.settings.intensity, disk))
        previous = next
      }
      cell.stopTracking(last: previous, current: previous, in: slider, mouseIsUp: true)
      assertDragOutcome(view, from: start, to: end, samples: samples)
      done()
      return
    }
    dragSamples = []
    // Real drags emit leftMouseDragged at the target coordinate before leftMouseUp releases there.
    dragScript = stops.map { (value: Double($0), up: false) }
    dragScript.append((value: Double(end), up: false))
    dragScript.append((value: Double(end), up: true))
    let scriptCount = dragScript.count
    dragTick = 0
    let sampler = Timer(timeInterval: 0.05, repeats: true) { _ in
      MainActor.assumeIsolated {
        self.dragTick += 1
        if self.dragTick <= scriptCount {
          let shown = self.currentOverlayIntensity()
          let disk = (try? Settings.load(from: self.controller.settingsURL))?.intensity
          self.dragSamples.append((shown, self.controller.settings.intensity, disk))
          let step = self.dragScript.removeFirst()
          let event = self.makeMouseEvent(
            step.up ? .leftMouseUp : .leftMouseDragged, value: step.value, to: slider,
            geometry: geometry)
          panel.sendEvent(event)
        } else if self.dragTick >= scriptCount + 4 {
          self.dragSampler?.invalidate()
          self.dragSampler = nil
          self.assertDragOutcome(view, from: start, to: end, samples: self.dragSamples)
          done()
        }
      }
    }
    RunLoop.main.add(sampler, forMode: .common)
    dragSampler = sampler
    panel.sendEvent(down)
  }

  func exerciseCancelAndStorageFailure(_ view: IntensitySliderView) {
    let menu = controller.statusItem!.menu!
    controller.menuNeedsUpdate(menu)
    let interiorTitle = MenuText.resolved(saved: controller.settings.language).intensityTitle(17)
    require(
      menu.item(at: 2)!.title == interiorTitle,
      "menu row reflects committed interior intensity")
    // Cancelling an active tracking drag (mouseIsUp == false) reverts overlay and slider UI.
    let slider = view.slider
    let cell = slider.cell as! TrackingSliderCell
    let geometry = knobTrackGeometry(of: slider)
    let pt17 = sliderPoint(17, of: slider, geometry: geometry)
    let pt25 = sliderPoint(25, of: slider, geometry: geometry)
    require(cell.startTracking(at: pt17, in: slider), "cell starts tracking for cancel test")
    require(cell.continueTracking(last: pt17, current: pt25, in: slider), "cell tracks to 25")
    slider.sendAction(slider.action, to: slider.target)
    require(
      controller.previewIntensity == 25 && currentOverlayIntensity() == 25
        && controller.settings.intensity == 17,
      "cancelled drag previews 25 before abort")
    cell.stopTracking(last: pt25, current: pt25, in: slider, mouseIsUp: false)
    require(
      controller.previewIntensity == nil && controller.settings.intensity == 17
        && view.percent == 17 && currentOverlayIntensity() == 17
        && (try? Settings.load(from: controller.settingsURL))?.intensity == 17,
      "aborted tracking reverts overlay and slider UI without writing to disk")
    // Uncommitted preview cancelled by Escape must also revert overlay and leave disk untouched.
    let panel = slider.window as! IntensityPanel
    view.percent = 26
    controller.previewIntensity(26)
    require(
      controller.previewIntensity == 26 && currentOverlayIntensity() == 26
        && controller.settings.intensity == 17,
      "uncommitted preview updates overlay without mutating persisted settings")
    dispatchKey(53, characters: "\u{1b}", to: panel)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      require(self.controller.intensityPanel == nil, "Escape closes the panel")
      require(
        self.controller.previewIntensity == nil && self.controller.settings.intensity == 17
          && self.currentOverlayIntensity() == 17
          && (try? Settings.load(from: self.controller.settingsURL))?.intensity == 17,
        "cancelling uncommitted preview restores persisted overlay and disk state")
      self.exerciseStorageFailure()
    }
  }

  func exerciseStorageFailure() {
    let menu = controller.statusItem!.menu!
    controller.menuNeedsUpdate(menu)
    menu.performActionForItem(at: 2)
    let view = controller.intensityPanel!.contentView as! IntensitySliderView
    let url = controller.settingsURL
    let backup = url.deletingLastPathComponent().appendingPathComponent("settings-backup.json")
    do {
      try? FileManager.default.removeItem(at: backup)
      try FileManager.default.moveItem(at: url, to: backup)
      // Replacing settings.json with a directory guarantees atomic save fails predictably.
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      view.percent = 24
      controller.previewIntensity(24)
      require(currentOverlayIntensity() == 24, "preview shows 24 before commit attempt")
      controller.commitIntensity()
      require(controller.lastError != nil, "storage failure records error")
      require(
        controller.settings.intensity == 17 && controller.previewIntensity == nil
          && currentOverlayIntensity() == 17 && view.percent == 17
          && view.percentLabel.stringValue == "17%",
        "storage failure reverts both overlay and slider UI to persisted intensity")
      try FileManager.default.removeItem(at: url)
      try FileManager.default.moveItem(at: backup, to: url)
      let restored = try Settings.load(from: url)
      require(
        restored.intensity == 17,
        "persisted settings file remained untouched after failed commit")
      // Confirm normal saving recovers and clears lastError.
      controller.previewIntensity(18)
      controller.commitIntensity()
      require(
        controller.lastError == nil && controller.settings.intensity == 18,
        "commit recovers once storage is writable again")
      controller.previewIntensity(17)
      controller.commitIntensity()
      controller.intensityPanel?.close()
      if usedProgrammaticCellDrag {
        print(
          "PASS: native slider keyboard, accessibility, programmatic NSSliderCell tracking preview/release (15%, 17%, 30%), cancel revert and storage-failure recovery"
        )
        print(
          "LIMIT: synthetic NSEvent drag on \(ProcessInfo.processInfo.operatingSystemVersionString) exits NSCell.trackMouse at mouse-down when pressedMouseButtons=0; preview/release assertions ran via programmatic NSSliderCell startTracking/continueTracking/stopTracking (not live NSEvent or physical drag)"
        )
      } else {
        print(
          "PASS: native slider keyboard, accessibility, process-local NSEvent drag preview/release (15%, 17%, 30%), cancel revert and storage-failure recovery"
        )
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.exerciseHiddenAdjustment()
      }
    } catch { require(false, "storage failure test setup: \(error)") }
  }

  /// Disabled, snoozed, and excluded overlays must stay hidden while the intensity changes.
  func exerciseHiddenAdjustment() {
    controller.snooze(for: 60)
    require(controller.overlays.allSatisfy { !$0.isVisible }, "snooze hides overlays")
    let menu = controller.statusItem!.menu!
    controller.menuNeedsUpdate(menu)
    menu.performActionForItem(at: 2)
    let view = controller.intensityPanel!.contentView as! IntensitySliderView
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      self.keyboardStep(view, keyCode: 124, characters: "\u{F703}", target: 18) {
        require(
          self.controller.overlays.allSatisfy { !$0.isVisible },
          "snoozed overlays stay hidden during slider adjustment")
        self.controller.intensityPanel?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          self.controller.resume()
          require(
            self.controller.overlays.allSatisfy(\.isVisible)
              && self.currentOverlayIntensity() == 18,
            "resuming snooze shows the adjusted intensity")
          self.controller.menuNeedsUpdate(menu)
          menu.performActionForItem(at: 0)  // disable
          self.controller.menuNeedsUpdate(menu)
          menu.performActionForItem(at: 2)
          let disabledView = self.controller.intensityPanel!.contentView as! IntensitySliderView
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.keyboardStep(disabledView, keyCode: 123, characters: "\u{F702}", target: 17) {
              require(
                self.controller.overlays.allSatisfy { !$0.isVisible },
                "disabled overlays stay hidden during slider adjustment")
              self.controller.intensityPanel?.close()
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.controller.menuNeedsUpdate(menu)
                menu.performActionForItem(at: 0)  // re-enable
                require(
                  self.controller.overlays.allSatisfy(\.isVisible)
                    && self.currentOverlayIntensity() == 17,
                  "re-enabled overlays show the adjusted intensity")
                self.continueAfterIntensity()
              }
            }
          }
        }
      }
    }
  }

  func continueAfterIntensity() {
    do {
      let persisted = try Settings.load(from: controller.settingsURL)
      require(persisted == controller.settings, "menu changes persisted")
      let second = try AppController(
        settingsDirectory: controller.settingsURL.deletingLastPathComponent(), resources: resources)
      do {
        try second.start()
        require(false, "duplicate instance must refuse")
      } catch StartupError.alreadyRunning {} catch { require(false, "duplicate instance error") }
      second.shutdown()
    } catch { require(false, "menu persistence/lock: \(error)") }
    let menu = controller.statusItem!.menu!
    controller.menuNeedsUpdate(menu)
    menu.item(at: 3)!.submenu!.performActionForItem(at: 1)
    controller.menuNeedsUpdate(menu)
    require(controller.settings.language == "en", "English choice persisted")
    require(menu.item(at: 0)?.title == "Enable paper texture", "English menu refreshed")
    require(menu.item(at: 1)?.title == "Texture", "English texture menu")
    require(menu.item(at: 2)?.title == "Intensity - 17%", "English intensity menu row")
    require(
      menu.item(at: 2)?.accessibilityLabel() == "Intensity - 17%",
      "English intensity accessibility label")
    require(controller.statusItem?.button?.title == "S", "menu bar mark stays S")
    require(
      controller.statusItem?.button?.accessibilityLabel() == "MattePulp",
      "English accessibility name")
    menu.item(at: 3)!.submenu!.performActionForItem(at: 0)
    controller.menuNeedsUpdate(menu)
    require(menu.item(at: 0)?.title == "启用纸张纹理", "Chinese menu refreshed")
    require(menu.item(at: 1)?.submenu?.item(at: 2)?.title == "羊皮纸", "Chinese texture name")
    require(menu.item(at: 2)?.title == "强度 - 17%", "Chinese intensity menu row")
    require(
      controller.statusItem?.button?.accessibilityLabel() == "柔纸", "Chinese accessibility name")
    do {
      let saved = try Settings.load(from: controller.settingsURL)
      require(
        saved.language == "zh-Hans" && saved.intensity == 17 && saved.texture == "Parchment",
        "language reopens with texture and strength")
    } catch { require(false, "language reopen: \(error)") }
    do { try exerciseSchedule(menu) } catch { require(false, "schedule settings: \(error)") }
    controller.snooze(for: 0.1)
    require(controller.overlays.allSatisfy { !$0.isVisible }, "snooze hides immediately")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.exerciseExclusion() }
  }

  func exerciseSchedule(_ menu: NSMenu) throws {
    let index = menu.items.firstIndex { $0.action == #selector(AppController.showSchedule) }!
    menu.performActionForItem(at: index)
    let window = controller.scheduleWindow!.window!
    require(window.isVisible && window.title == "定时与日落", "menu opens native schedule settings")
    menu.performActionForItem(at: index)
    require(controller.scheduleWindow?.window === window, "reopening keeps the current draft")
    func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }
    let controls = descendants(window.contentView!)
    let buttons = controls.compactMap { $0 as? NSButton }
    let timed = buttons.first { $0.title == "启用定时" }!
    let sunset = buttons.first { $0.title == "启用日落" }!
    let save = buttons.first { $0.title == "保存" }!
    let fields = controls.compactMap { $0 as? NSTextField }
    let start = fields.first { $0.accessibilityLabel() == "开始时间（24 小时）" }!
    let end = fields.first { $0.accessibilityLabel() == "结束时间（24 小时）" }!
    require(timed.state == .off && sunset.state == .off, "native toggles default to off")
    require(start.stringValue == "21:00" && end.stringValue == "06:00", "native clock defaults")
    let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
    let wall = components.hour! * 60 + components.minute!
    func time(_ delta: Int) -> String {
      let minute = (wall + delta + 1440) % 1440
      return String(format: "%02d:%02d", minute / 60, minute % 60)
    }
    timed.state = .on
    sunset.state = .on
    start.stringValue = time(60)
    end.stringValue = time(120)
    save.performClick(nil)
    require(
      controller.settings.schedule.timed && controller.settings.schedule.sunset, "both rules save")
    require(
      controller.overlays.allSatisfy { !$0.isVisible },
      "daily rule remains active when sunset is unavailable")
    require(
      fields.contains { $0.stringValue.contains("请输入坐标") }
        && fields.contains { $0.stringValue.contains("下次自动变化") },
      "native status shows missing location and the next change")
    let original = controller.settings
    let backup = scratch.appendingPathComponent("settings-backup.json")
    try FileManager.default.moveItem(at: controller.settingsURL, to: backup)
    try FileManager.default.createDirectory(
      at: controller.settingsURL, withIntermediateDirectories: false)
    start.stringValue = time(-60)
    end.stringValue = time(60)
    save.performClick(nil)
    require(controller.settings == original, "failed save keeps the applied schedule")
    require(
      fields.contains { $0.stringValue.contains("保存失败") }, "native save failure stays visible")
    try FileManager.default.removeItem(at: controller.settingsURL)
    try FileManager.default.moveItem(at: backup, to: controller.settingsURL)
    save.performClick(nil)
    require(controller.overlays.allSatisfy(\.isVisible), "retry applies the retained draft")
    timed.state = .off
    save.performClick(nil)
    require(
      !controller.settings.schedule.timed && controller.settings.schedule.sunset,
      "toggle daily rule independently")
    sunset.state = .off
    save.performClick(nil)
    require(!controller.settings.schedule.sunset, "toggle sunset independently")
    let reopened = try Settings.load(from: controller.settingsURL)
    require(
      reopened == controller.settings, "schedule edits persist alongside the existing settings")
    window.close()
    fixture?.makeKeyAndOrderFront(nil)
    print(
      "PASS: native schedule menu, window lifecycle, independent toggles, status and save retry")
  }

  func exerciseExclusion() {
    require(controller.overlays.allSatisfy(\.isVisible), "timer resumes overlays")
    controller.snooze(for: 60)
    controller.resume()
    require(controller.overlays.allSatisfy(\.isVisible), "explicit resume cancels snooze")
    do {
      let directory = controller.settingsURL.deletingLastPathComponent()
      var settings = controller.settings
      let identity: String
      if skipForegroundTests {
        identity = "com.suepaper.synthetic.excluded"
      } else {
        guard let current = AppController.identity(NSWorkspace.shared.frontmostApplication),
          NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        else {
          require(false, "synthetic fixture is frontmost")
          return
        }
        identity = current
      }
      settings.exclusions = [identity]
      controller.shutdown()
      try settings.save(to: directory.appendingPathComponent("settings.json"))
      controller = try AppController(settingsDirectory: directory, resources: resources)
      configureController(controller)
      if skipForegroundTests {
        controller.foregroundIdentityProvider = { identity }
      }
      try controller.start()
      require(
        controller.overlays.allSatisfy { !$0.isVisible },
        "frontmost fixture exclusion hides on launch")
      require(
        controller.settings.intensity == 17 && currentOverlayIntensity() == 17,
        "restart recovers the interior slider intensity")
      if skipForegroundTests {
        let menu = controller.statusItem!.menu!
        controller.menuNeedsUpdate(menu)
        require(
          menu.item(at: 2)!.title == "强度 - 17%",
          "restart recovers menu intensity readout")
        menu.performActionForItem(at: 2)
        let excludedView = controller.intensityPanel!.contentView as! IntensitySliderView
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          self.keyboardStep(excludedView, keyCode: 124, characters: "\u{F703}", target: 18) {
            require(
              self.controller.overlays.allSatisfy { !$0.isVisible },
              "excluded overlays stay hidden during slider adjustment")
            self.keyboardStep(excludedView, keyCode: 123, characters: "\u{F702}", target: 17) {
              self.controller.intensityPanel?.close()
              self.finishSyntheticExclusionRestart(directory: directory)
            }
          }
        }
        return
      }
      settings.exclusions = []
      controller.shutdown()
      try settings.save(to: directory.appendingPathComponent("settings.json"))
      controller = try AppController(settingsDirectory: directory, resources: resources)
      configureController(controller)
      try controller.start()
      require(
        controller.overlays.allSatisfy(\.isVisible), "removing exclusion restores after restart")
      print(
        "PASS: native menus, display notification rebuild, focus, snooze timer, foreground exclusion and restart"
      )
      let process = Process()
      process.executableURL = scratch.appendingPathComponent("foreground-fixture")
      process.currentDirectoryURL = scratch
      try process.run()
      foregroundFixture = process
      awaitForeground(process.processIdentifier) { self.excludeFixture() }
    } catch { require(false, "exclusion lifecycle: \(error)") }
  }

  func finishSyntheticExclusionRestart(directory: URL) {
    do {
      var settings = controller.settings
      settings.exclusions = []
      controller.shutdown()
      try settings.save(to: directory.appendingPathComponent("settings.json"))
      controller = try AppController(settingsDirectory: directory, resources: resources)
      configureController(controller)
      try controller.start()
      require(
        controller.overlays.allSatisfy(\.isVisible) && currentOverlayIntensity() == 17,
        "removing exclusion restores overlay at recovered interior intensity after restart")
      print(
        "PASS: native menus, display notification rebuild, snooze timer, synthetic exclusion during adjustment and restart recovery"
      )
      print(
        "LIMIT: SUE_PAPER_SKIP_FOREGROUND_TESTS=1 skipped live foreground-app switching, on-screen panel key focus, and fullscreen Space transitions"
      )
      finish()
    } catch { require(false, "restart recovery: \(error)") }
  }

  func awaitForeground(
    _ pid: pid_t, visible: Bool? = nil, attempts: Int = 25, action: @escaping @MainActor () -> Void
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      let visibilityMatches =
        visible.map { expected in
          self.controller.overlays.allSatisfy { $0.isVisible == expected }
        } ?? true
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && visibilityMatches {
        action()
      } else {
        require(attempts > 0, "task-owned foreground fixture activation timed out")
        self.awaitForeground(pid, visible: visible, attempts: attempts - 1, action: action)
      }
    }
  }

  func excludeFixture() {
    let menu = controller.statusItem!.menu!
    controller.menuNeedsUpdate(menu)
    let index = menu.items.firstIndex { $0.action == #selector(AppController.toggleExclusion) }!
    menu.performActionForItem(at: index)
    require(
      controller.overlays.allSatisfy { !$0.isVisible }, "menu excludes separate frontmost process")
    // While the excluded fixture remains the frontmost application, the panel must take
    // keyboard focus without activating this app and without unhiding its overlays.
    controller.menuNeedsUpdate(menu)
    menu.performActionForItem(at: 2)
    let panel = controller.intensityPanel
    let fixturePID = foregroundFixture!.processIdentifier
    require(
      panel != nil && panel!.isVisible
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID,
      "panel opens without stealing frontmost from the excluded application")
    let excludedView = panel!.contentView as! IntensitySliderView
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      require(
        panel!.isKeyWindow && panel!.firstResponder === excludedView.slider,
        "panel takes keyboard focus while another application is frontmost")
      self.keyboardStep(excludedView, keyCode: 124, characters: "\u{F703}", target: 18) {
        require(
          self.controller.overlays.allSatisfy { !$0.isVisible },
          "excluded overlays stay hidden during panel adjustment")
        self.controller.intensityPanel?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
          require(self.controller.intensityPanel == nil, "panel closes while excluded")
          NSApp.activate(ignoringOtherApps: true)
          self.awaitForeground(ProcessInfo.processInfo.processIdentifier, visible: true) {
            require(
              self.controller.overlays.allSatisfy(\.isVisible),
              "activation notification restores for included app")
            let pid = self.foregroundFixture!.processIdentifier
            NSRunningApplication(processIdentifier: pid)?.activate(
              options: [.activateIgnoringOtherApps])
            self.awaitForeground(pid, visible: false) {
              require(
                self.controller.overlays.allSatisfy { !$0.isVisible },
                "activation notification hides for excluded app")
              self.controller.menuNeedsUpdate(menu)
              let include = menu.items.firstIndex {
                $0.action == #selector(AppController.toggleExclusion)
              }!
              menu.performActionForItem(at: include)
              require(
                self.controller.overlays.allSatisfy(\.isVisible),
                "menu can include excluded app again")
              self.foregroundFixture?.terminate()
              self.foregroundFixture?.waitUntilExit()
              self.foregroundFixture = nil
              NSApp.activate(ignoringOtherApps: true)
              self.awaitForeground(ProcessInfo.processInfo.processIdentifier) {
                self.exerciseFullscreen()
              }
            }
          }
        }
      }
    }
  }

  func exerciseFullscreen() {
    print("PASS: native menu exclusion and inclusion, actual frontmost-app switching notifications")
    fixture?.makeKeyAndOrderFront(nil)
    fixture?.toggleFullScreen(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
      if !self.fullscreenEntered {
        print(
          "LIMIT: WindowServer did not enter synthetic fullscreen; manual fullscreen verification remains"
        )
        self.finish()
      }
    }
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    fullscreenEntered = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      require(
        self.controller.overlays.allSatisfy { $0.isOnActiveSpace && $0.isVisible },
        "overlay joins synthetic fullscreen Space")
      require(NSApp.keyWindow === self.fixture, "fullscreen fixture keeps keyboard focus")
      print(
        "PASS: synthetic native fullscreen Space entered; overlays remain on active Space without focus"
      )
      self.fixture?.toggleFullScreen(nil)
    }
  }

  func windowDidExitFullScreen(_ notification: Notification) { finish() }

  func finish() {
    let windows = controller.overlays
    controller.shutdown()
    require(windows.allSatisfy { !$0.isVisible }, "shutdown closes overlays")
    require(
      controller.overlays.isEmpty && controller.statusItem == nil, "shutdown removes native objects"
    )
    fixture?.close()
    print("PASS: cleanup complete")
    NSApp.terminate(nil)
  }
}

@main
struct Tests {
  @MainActor static func main() throws {
    require(
      CommandLine.arguments.count == 5 || CommandLine.arguments.last == "--fixtures-only",
      "tests RESOURCES SCRATCH EVIDENCE ZONE_FIXTURE [--fixtures-only]")
    let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    let scratch = URL(fileURLWithPath: CommandLine.arguments[2])
    let evidence = URL(fileURLWithPath: CommandLine.arguments[3])
    let skipForeground =
      ProcessInfo.processInfo.environment["SUE_PAPER_SKIP_FOREGROUND_TESTS"] == "1"
    let app = NSApplication.shared
    try settingsTests(scratch)
    try scheduleTests(fixture: URL(fileURLWithPath: CommandLine.arguments[4]), scratch: scratch)
    try textureTests(resources: resources, evidence: evidence)
    if CommandLine.arguments.last == "--fixtures-only" { return }
    app.setActivationPolicy(skipForeground ? .prohibited : .regular)
    let delegate = TestDelegate(
      resources: resources, scratch: scratch, skipForegroundTests: skipForeground)
    app.delegate = delegate
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
      require(false, "native lifecycle timed out")
    }
    app.run()
    withExtendedLifetime(delegate) {}
  }
}
