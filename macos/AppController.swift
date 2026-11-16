import AppKit
import Darwin

enum StartupError: Error { case alreadyRunning, lockUnavailable }

@MainActor
final class AppController: NSObject, NSMenuDelegate {
  let settingsURL: URL
  let textures: TextureStore
  private(set) var settings = Settings()
  private(set) var visibility = Visibility()
  private(set) var overlays: [Overlay] = []
  private(set) var statusItem: NSStatusItem?
  private(set) var lastError: String?
  private var lock: Int32 = -1
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var snoozeTimer: Timer?
  private var menuForeground: String?

  init(settingsDirectory: URL, resources: URL) throws {
    settingsURL = settingsDirectory.appendingPathComponent("settings.json")
    textures = try TextureStore(directory: resources.appendingPathComponent("Textures"))
    super.init()
  }

  func start() throws {
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    lock = open(
      settingsURL.deletingLastPathComponent().appendingPathComponent("instance.lock").path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lock >= 0 else { throw StartupError.lockUnavailable }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      let error = errno
      close(lock)
      lock = -1
      throw error == EWOULDBLOCK ? StartupError.alreadyRunning : StartupError.lockUnavailable
    }
    do { settings = try Settings.load(from: settingsURL) } catch {
      record(error, context: "Could not load settings; using defaults")
    }
    try rebuildOverlays()
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem?.button?.title = "S"
    statusItem?.button?.toolTip = "Sue-Paper"
    statusItem?.button?.setAccessibilityLabel("Sue-Paper")
    let menu = NSMenu(title: "Sue-Paper")
    menu.delegate = self
    statusItem?.menu = menu
    menuNeedsUpdate(menu)
    applyVisibility()

    observe(.default, NSApplication.didChangeScreenParametersNotification) { controller, _ in
      do { try controller.rebuildOverlays() } catch {
        controller.record(error, context: "Could not update displays")
      }
    }
    let workspace = NSWorkspace.shared.notificationCenter
    observe(workspace, NSWorkspace.didActivateApplicationNotification) {
      controller, activatedIdentity in
      controller.applyVisibility(foreground: activatedIdentity)
    }
    for name in [
      NSWorkspace.activeSpaceDidChangeNotification,
      NSWorkspace.didWakeNotification,
      NSWorkspace.screensDidWakeNotification,
    ] {
      observe(workspace, name) { controller, _ in controller.applyVisibility() }
    }
  }

  private func observe(
    _ center: NotificationCenter, _ name: Notification.Name,
    action: @escaping @MainActor (AppController, String?) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) {
      [weak self] notification in
      let activated =
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let identity = activated?.bundleIdentifier ?? activated?.executableURL?.absoluteString
      MainActor.assumeIsolated { if let self { action(self, identity) } }
    }
    observers.append((center, token))
  }

  func rebuildOverlays() throws {
    let image = try textures.image(texture: settings.texture, intensity: settings.intensity)
    let replacements = NSScreen.screens.map { Overlay(screen: $0, image: image) }
    let previous = overlays
    overlays = replacements
    applyVisibility()
    for overlay in previous { overlay.close() }
  }

  static func identity(_ app: NSRunningApplication?) -> String? {
    guard let app else { return nil }
    return app.bundleIdentifier ?? app.executableURL?.absoluteString
  }

  func applyVisibility() {
    applyVisibility(foreground: Self.identity(NSWorkspace.shared.frontmostApplication))
  }

  private func applyVisibility(foreground: String?) {
    let visible = visibility.isVisible(
      settings: settings,
      foreground: foreground)
    for overlay in overlays {
      if visible { overlay.orderFrontRegardless() } else { overlay.orderOut(nil) }
    }
    statusItem?.button?.appearsDisabled = !visible
  }

  private func record(_ error: Error, context: String) {
    lastError = context
    // Avoid logging app identities, paths, or other desktop metadata.
    fputs("Sue-Paper: \(context) (\((error as NSError).code))\n", stderr)
  }

  private func change(_ updated: Settings) {
    do {
      let image = try textures.image(texture: updated.texture, intensity: updated.intensity)
      try updated.save(to: settingsURL)
      settings = updated
      for overlay in overlays { (overlay.contentView as? TextureView)?.image = image }
      lastError = nil
      applyVisibility()
    } catch { record(error, context: "Change not saved; check settings storage and app resources") }
  }

  @objc func toggle() {
    var updated = settings
    updated.enabled.toggle()
    change(updated)
  }

  @objc func selectTexture(_ item: NSMenuItem) {
    guard Settings.textures.indices.contains(item.tag) else { return }
    var updated = settings
    updated.texture = Settings.textures[item.tag]
    change(updated)
  }

  @objc func selectIntensity(_ item: NSMenuItem) {
    guard Settings.intensities.contains(item.tag) else { return }
    var updated = settings
    updated.intensity = item.tag
    change(updated)
  }

  @objc func snooze(_ item: NSMenuItem) { snooze(for: TimeInterval(item.tag * 60)) }

  func snooze(for seconds: TimeInterval) {
    snoozeTimer?.invalidate()
    visibility.snoozeUntil = Date().addingTimeInterval(seconds)
    let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.resume() }
    }
    snoozeTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    applyVisibility()
  }

  @objc func resume() {
    snoozeTimer?.invalidate()
    snoozeTimer = nil
    visibility.snoozeUntil = nil
    applyVisibility()
  }

  @objc func toggleExclusion() {
    guard let identity = menuForeground else { return }
    var updated = settings
    if updated.exclusions.contains(identity) {
      updated.exclusions.removeAll { $0 == identity }
    } else {
      updated.exclusions.append(identity)
    }
    change(updated)
  }

  @objc func quit() { NSApp.terminate(nil) }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let foreground = NSWorkspace.shared.frontmostApplication
    menuForeground =
      foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier
      ? nil : Self.identity(foreground)
    func item(
      _ title: String, _ action: Selector?, tag: Int = 0,
      checked: Bool = false, parent: NSMenu? = nil
    ) {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self
      entry.tag = tag
      entry.state = checked ? .on : .off
      (parent ?? menu).addItem(entry)
    }
    item("启用 Enabled", #selector(toggle), checked: settings.enabled)
    let textureMenu = NSMenu(title: "纸张 Texture")
    for (index, texture) in textures.catalog.enumerated() {
      item(
        texture.name, #selector(selectTexture(_:)), tag: index,
        checked: texture.id == settings.texture, parent: textureMenu)
    }
    let textureItem = NSMenuItem(title: textureMenu.title, action: nil, keyEquivalent: "")
    textureItem.submenu = textureMenu
    menu.addItem(textureItem)
    let intensityMenu = NSMenu(title: "强度 Intensity")
    for intensity in Settings.intensities {
      item(
        "\(intensity)%", #selector(selectIntensity(_:)), tag: intensity,
        checked: intensity == settings.intensity, parent: intensityMenu)
    }
    let intensityItem = NSMenuItem(title: intensityMenu.title, action: nil, keyEquivalent: "")
    intensityItem.submenu = intensityMenu
    menu.addItem(intensityItem)
    menu.addItem(.separator())
    item("打盹 5 分钟 / Snooze 5 minutes", #selector(snooze(_:)), tag: 5)
    item("打盹 15 分钟 / Snooze 15 minutes", #selector(snooze(_:)), tag: 15)
    if visibility.snoozeUntil.map({ $0 > Date() }) == true {
      item("恢复 Resume now", #selector(resume))
    }
    if let identity = menuForeground {
      let excluded = settings.exclusions.contains(identity)
      let name = foreground?.localizedName ?? "current app"
      item(
        excluded ? "取消排除 / Include \(name)" : "排除 / Exclude \(name)",
        #selector(toggleExclusion), checked: excluded)
    }
    if let lastError { item(lastError, nil) }
    menu.addItem(.separator())
    item("退出 Quit Sue-Paper", #selector(quit))
  }

  func shutdown() {
    snoozeTimer?.invalidate()
    snoozeTimer = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers.removeAll()
    for overlay in overlays { overlay.close() }
    overlays.removeAll()
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
    if lock >= 0 {
      flock(lock, LOCK_UN)
      close(lock)
      lock = -1
    }
  }
}
