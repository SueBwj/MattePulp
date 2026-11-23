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
  require(chinese.intensities == ["15%", "20%", "25%", "30%"], "Chinese intensity steps")
  require(english.intensities == ["15%", "20%", "25%", "30%"], "English intensity steps")
  var settings = Settings()
  settings.texture = "unknown"
  settings.intensity = 99
  settings.exclusions = [" com.example.fixture ", "com.example.fixture", ""]
  try settings.save(to: url)
  let normalized = try Settings.load(from: url)
  require(
    normalized.texture == "ClassicMatte" && normalized.intensity == 20, "invalid values normalized")
  require(normalized.exclusions == ["com.example.fixture"], "exclusions normalized")
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
    for intensity in Settings.intensities {
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
      if intensity == 20 {
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
          to: evidence.appendingPathComponent("\(texture.id)-synthetic.png"))
      }
    }
  }
  require(fingerprints.count == 16, "all sixteen texture/strength combinations differ")
  print(
    "PASS: all 16 shared textures, strength, seamless repeats and 1x/2x physical pixel equality")
}

@MainActor
final class TestDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let resources: URL
  let scratch: URL
  var controller: AppController!
  var fixture: NSWindow!
  var fullscreenEntered = false
  var foregroundFixture: Process?

  init(resources: URL, scratch: URL) {
    self.resources = resources
    self.scratch = scratch
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      fixture = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 640, height: 420),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      fixture.title = "MattePulp synthetic test fixture"
      fixture.isReleasedWhenClosed = false
      fixture.backgroundColor = .white
      fixture.collectionBehavior = [.fullScreenPrimary]
      fixture.delegate = self
      let label = NSTextField(labelWithString: "Synthetic paper fixture - no desktop capture")
      label.frame = NSRect(x: 30, y: 160, width: 580, height: 60)
      fixture.contentView?.addSubview(label)
      fixture.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      controller = try AppController(
        settingsDirectory: scratch.appendingPathComponent("lifecycle"), resources: resources)
      awaitForeground(ProcessInfo.processInfo.processIdentifier) {
        self.fixture.makeKeyAndOrderFront(nil)
        require(NSApp.keyWindow === self.fixture, "synthetic fixture establishes keyboard focus")
        do {
          try self.controller.start()
          self.exerciseMenu()
        } catch { require(false, "overlay startup: \(error)") }
      }
    } catch { require(false, "native fixture startup: \(error)") }
  }

  func exerciseMenu() {
    require(!controller.overlays.isEmpty, "real displays have overlays")
    require(NSApp.keyWindow === fixture, "overlay startup preserves fixture keyboard focus")
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
    let strengthMenu = menu.item(at: 2)!.submenu!
    strengthMenu.performActionForItem(at: 3)
    require(
      controller.settings.texture == "Parchment" && controller.settings.intensity == 30,
      "native menu applies texture and strength")
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
    menu.item(at: 3)!.submenu!.performActionForItem(at: 1)
    controller.menuNeedsUpdate(menu)
    require(controller.settings.language == "en", "English choice persisted")
    require(menu.item(at: 0)?.title == "Enable paper texture", "English menu refreshed")
    require(menu.item(at: 1)?.title == "Texture", "English texture menu")
    require(menu.item(at: 2)?.title == "Intensity", "English intensity menu")
    require(
      menu.item(at: 2)?.submenu?.items.map(\.title) == ["15%", "20%", "25%", "30%"],
      "intensity steps unchanged")
    require(
      menu.item(at: 2)?.submenu?.items.map { $0.accessibilityLabel() }
        == ["15%", "20%", "25%", "30%"],
      "intensity accessibility values")
    require(controller.statusItem?.button?.title == "S", "menu bar mark stays S")
    require(
      controller.statusItem?.button?.accessibilityLabel() == "MattePulp",
      "English accessibility name")
    menu.item(at: 3)!.submenu!.performActionForItem(at: 0)
    controller.menuNeedsUpdate(menu)
    require(menu.item(at: 0)?.title == "启用纸张纹理", "Chinese menu refreshed")
    require(menu.item(at: 1)?.submenu?.item(at: 2)?.title == "羊皮纸", "Chinese texture name")
    require(
      controller.statusItem?.button?.accessibilityLabel() == "柔纸", "Chinese accessibility name")
    do {
      let saved = try Settings.load(from: controller.settingsURL)
      require(
        saved.language == "zh-Hans" && saved.intensity == 30 && saved.texture == "Parchment",
        "language reopens with texture and strength")
    } catch { require(false, "language reopen: \(error)") }
    controller.snooze(for: 0.1)
    require(controller.overlays.allSatisfy { !$0.isVisible }, "snooze hides immediately")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.exerciseExclusion() }
  }

  func exerciseExclusion() {
    require(controller.overlays.allSatisfy(\.isVisible), "timer resumes overlays")
    controller.snooze(for: 60)
    controller.resume()
    require(controller.overlays.allSatisfy(\.isVisible), "explicit resume cancels snooze")
    do {
      let directory = controller.settingsURL.deletingLastPathComponent()
      var settings = controller.settings
      guard let identity = AppController.identity(NSWorkspace.shared.frontmostApplication),
        NSWorkspace.shared.frontmostApplication?.processIdentifier
          == ProcessInfo.processInfo.processIdentifier
      else {
        require(false, "synthetic fixture is frontmost")
        return
      }
      settings.exclusions = [identity]
      controller.shutdown()
      try settings.save(to: directory.appendingPathComponent("settings.json"))
      controller = try AppController(settingsDirectory: directory, resources: resources)
      try controller.start()
      require(
        controller.overlays.allSatisfy { !$0.isVisible },
        "actual frontmost fixture exclusion hides on launch")
      settings.exclusions = []
      controller.shutdown()
      try settings.save(to: directory.appendingPathComponent("settings.json"))
      controller = try AppController(settingsDirectory: directory, resources: resources)
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
    NSApp.activate(ignoringOtherApps: true)
    awaitForeground(ProcessInfo.processInfo.processIdentifier, visible: true) {
      require(
        self.controller.overlays.allSatisfy(\.isVisible),
        "activation notification restores for included app")
      let pid = self.foregroundFixture!.processIdentifier
      NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
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
          self.controller.overlays.allSatisfy(\.isVisible), "menu can include excluded app again")
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

  func exerciseFullscreen() {
    print("PASS: native menu exclusion and inclusion, actual frontmost-app switching notifications")
    fixture.makeKeyAndOrderFront(nil)
    fixture.toggleFullScreen(nil)
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
      self.fixture.toggleFullScreen(nil)
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
    fixture.close()
    print("PASS: cleanup complete")
    NSApp.terminate(nil)
  }
}

@main
struct Tests {
  @MainActor static func main() throws {
    require(CommandLine.arguments.count == 4, "tests RESOURCES SCRATCH EVIDENCE")
    let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    let scratch = URL(fileURLWithPath: CommandLine.arguments[2])
    let evidence = URL(fileURLWithPath: CommandLine.arguments[3])
    let app = NSApplication.shared
    try settingsTests(scratch)
    try textureTests(resources: resources, evidence: evidence)
    app.setActivationPolicy(.regular)
    let delegate = TestDelegate(resources: resources, scratch: scratch)
    app.delegate = delegate
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
      require(false, "native lifecycle timed out")
    }
    app.run()
    withExtendedLifetime(delegate) {}
  }
}
