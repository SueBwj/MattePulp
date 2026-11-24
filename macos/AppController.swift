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
  private(set) var lastError: MenuNotice?
  private var lock: Int32 = -1
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var snoozeTimer: Timer?
  private var scheduleTimer: Timer?
  private(set) var scheduleWindow: ScheduleWindow?
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
      record(error, notice: .loadFailed)
    }
    try rebuildOverlays()
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem?.button?.title = "S"
    let menu = NSMenu()
    menu.delegate = self
    statusItem?.menu = menu
    menuNeedsUpdate(menu)
    applyVisibility()

    observe(.default, NSApplication.didChangeScreenParametersNotification) { controller, _ in
      do { try controller.rebuildOverlays() } catch {
        controller.record(error, notice: .displaysFailed)
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
    for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
      observe(.default, name) { controller, _ in controller.applyVisibility() }
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
    updateVisibility(foreground: foreground, reorder: true)
  }

  private func updateVisibility(foreground: String?, reorder: Bool) {
    updateScheduleTimer()
    let now = Date()
    let zone = TimeZone.current
    let snoozed = visibility.isSnoozed(at: now)
    let excluded = foreground.map(settings.exclusions.contains) ?? false
    let result = settings.schedule.evaluate(
      now: now, zone: zone, manual: settings.enabled, suppressed: snoozed || excluded)
    let visible = result.visible != 0
    for overlay in overlays {
      guard reorder || overlay.isVisible != visible else { continue }
      if visible { overlay.orderFrontRegardless() } else { overlay.orderOut(nil) }
    }
    statusItem?.button?.appearsDisabled = !visible
    if let panel = scheduleWindow, panel.window?.isVisible == true {
      panel.refresh(
        result, settings: settings.schedule, now: now, zone: zone, manual: settings.enabled,
        snoozed: snoozed, excluded: excluded)
    }
  }

  private func updateScheduleTimer() {
    guard
      settings.schedule.timed || settings.schedule.sunset
        || scheduleWindow?.window?.isVisible == true
    else {
      scheduleTimer?.invalidate()
      scheduleTimer = nil
      return
    }
    guard scheduleTimer == nil else { return }
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.updateVisibility(
          foreground: Self.identity(NSWorkspace.shared.frontmostApplication), reorder: false)
      }
    }
    scheduleTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func record(_ error: Error, notice: MenuNotice) {
    lastError = notice
    // Avoid logging app identities, paths, or other desktop metadata.
    fputs("MattePulp: \(notice.logSummary) (\((error as NSError).code))\n", stderr)
  }

  private func refreshChrome(_ text: MenuText) {
    statusItem?.button?.toolTip = text.product
    statusItem?.button?.setAccessibilityLabel(text.product)
    statusItem?.menu?.title = text.product
  }

  @discardableResult
  private func change(_ updated: Settings) -> Bool {
    do {
      let image = try textures.image(texture: updated.texture, intensity: updated.intensity)
      try updated.save(to: settingsURL)
      settings = updated
      for overlay in overlays { (overlay.contentView as? TextureView)?.image = image }
      lastError = nil
      refreshChrome(MenuText.resolved(saved: settings.language))
      applyVisibility()
      return true
    } catch {
      record(error, notice: .saveFailed)
      return false
    }
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

  @objc func selectLanguage(_ item: NSMenuItem) {
    guard let raw = item.representedObject as? String, AppLanguage(rawValue: raw) != nil else {
      return
    }
    var updated = settings
    guard updated.language != raw else { return }
    updated.language = raw
    change(updated)
  }

  @objc func showSchedule() {
    if scheduleWindow?.window?.isVisible != true {
      let language = MenuText.resolved(saved: settings.language).language
      scheduleWindow = ScheduleWindow(language: language, settings: settings.schedule) {
        [weak self] rules in
        guard let self else { return false }
        var updated = self.settings
        updated.schedule = rules
        return self.change(updated)
      }
    }
    NSApp.activate(ignoringOtherApps: true)
    scheduleWindow?.window?.makeKeyAndOrderFront(nil)
    applyVisibility()
  }

  @objc func quit() { NSApp.terminate(nil) }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let text = MenuText.resolved(saved: settings.language)
    refreshChrome(text)
    let foreground = NSWorkspace.shared.frontmostApplication
    menuForeground =
      foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier
      ? nil : Self.identity(foreground)
    func item(
      _ title: String, _ action: Selector?, tag: Int = 0,
      checked: Bool = false, represented: String? = nil, parent: NSMenu? = nil
    ) {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self
      entry.tag = tag
      entry.state = checked ? .on : .off
      entry.representedObject = represented
      entry.setAccessibilityLabel(title)
      (parent ?? menu).addItem(entry)
    }
    func submenu(_ title: String, _ child: NSMenu) {
      let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      entry.submenu = child
      entry.setAccessibilityLabel(title)
      menu.addItem(entry)
    }
    item(text.toggle, #selector(toggle), checked: settings.enabled)
    let textureMenu = NSMenu(title: text.textureMenu)
    for (index, texture) in textures.catalog.enumerated() {
      item(
        MenuText.textureTitle(id: texture.id, language: text.language),
        #selector(selectTexture(_:)), tag: index,
        checked: texture.id == settings.texture, parent: textureMenu)
    }
    submenu(text.textureMenu, textureMenu)
    let intensityMenu = NSMenu(title: text.intensityMenu)
    for (label, intensity) in zip(text.intensities, Settings.intensities) {
      item(
        label, #selector(selectIntensity(_:)), tag: intensity,
        checked: intensity == settings.intensity, parent: intensityMenu)
    }
    submenu(text.intensityMenu, intensityMenu)
    let languageMenu = NSMenu(title: text.languageMenu)
    for choice in [AppLanguage.zhHans, AppLanguage.en] {
      item(
        choice.menuTitle, #selector(selectLanguage(_:)),
        checked: text.language == choice, represented: choice.rawValue, parent: languageMenu)
    }
    submenu(text.languageMenu, languageMenu)
    menu.addItem(.separator())
    item(ScheduleWindow.title(text.language) + "…", #selector(showSchedule))
    item(text.snooze5, #selector(snooze(_:)), tag: 5)
    item(text.snooze15, #selector(snooze(_:)), tag: 15)
    if visibility.snoozeUntil.map({ $0 > Date() }) == true {
      item(text.resume, #selector(resume))
    }
    if let identity = menuForeground {
      let excluded = settings.exclusions.contains(identity)
      let name = foreground?.localizedName ?? text.unnamedApp
      item(
        text.exclusionTitle(name: name, excluded: excluded),
        #selector(toggleExclusion), checked: excluded)
    }
    if let lastError { item(text.notice(lastError), nil) }
    menu.addItem(.separator())
    item(text.quit, #selector(quit))
  }

  func shutdown() {
    snoozeTimer?.invalidate()
    snoozeTimer = nil
    scheduleTimer?.invalidate()
    scheduleTimer = nil
    scheduleWindow?.close()
    scheduleWindow = nil
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
