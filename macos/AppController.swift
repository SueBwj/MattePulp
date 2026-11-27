import AppKit
import Darwin

enum StartupError: Error { case alreadyRunning, lockUnavailable }

@MainActor
final class AppController: NSObject, NSMenuDelegate, NSWindowDelegate {
  let settingsURL: URL
  let textures: TextureStore
  private let loginItem: LoginItem
  private var loginItemChangeFailed = false
  private(set) var settings = Settings()
  private(set) var visibility = Visibility()
  private(set) var overlays: [Overlay] = []
  private(set) var statusItem: NSStatusItem?
  private(set) var lastError: MenuNotice?
  /// All intensity levels of the active texture and tone, preloaded for previewing.
  private(set) var intensityImages: [Int: CGImage] = [:]
  /// Intensity shown on screen but not yet persisted; nil means screen matches settings.
  private(set) var previewIntensity: Int?
  private(set) var intensityPanel: IntensityPanel?
  /// Optional override used by non-intrusive synthetic fixtures to host the real panel offscreen.
  var presentIntensityPanel: ((IntensityPanel, NSPoint) -> Void)?
  var presentScheduleWindow: ((NSWindow) -> Void)?
  /// Injectable only for synthetic tests so exclusion checks never inspect unrelated user apps.
  var foregroundIdentityProvider: () -> String? = {
    AppController.identity(NSWorkspace.shared.frontmostApplication)
  }
  private var lock: Int32 = -1
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var snoozeTimer: Timer?
  private var scheduleTimer: Timer?
  private(set) var scheduleWindow: ScheduleWindow?
  /// True when no settings file existed at launch: the determinable new-install boundary
  /// for the one-time first-launch language entry.
  private(set) var firstLaunch = false
  private(set) var languagePicker: LanguagePickerWindow?
  /// Optional override used by non-intrusive synthetic fixtures to host the real window
  /// offscreen.
  var presentLanguageWindow: ((NSWindow) -> Void)?
  /// Synthetic tests can supply no screens to avoid creating overlays.
  var screensProvider: () -> [NSScreen] = { NSScreen.screens }
  private var menuForeground: String?

  init(settingsDirectory: URL, resources: URL, loginItem: LoginItem = .unavailable) throws {
    settingsURL = settingsDirectory.appendingPathComponent("settings.json")
    textures = try TextureStore(directory: resources.appendingPathComponent("Textures"))
    self.loginItem = loginItem
    super.init()
  }

  func start(presentUI: Bool = true) throws {
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
    // Checked before loading: a settings file that exists in any form (with or without a
    // language field, even if unreadable) marks an existing user who never sees the entry.
    firstLaunch = !FileManager.default.fileExists(atPath: settingsURL.path)
    do { settings = try Settings.load(from: settingsURL) } catch {
      record(error, notice: .loadFailed)
    }
    intensityImages = try textures.images(texture: settings.texture, tone: settings.tone)
    guard presentUI else { return }
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
    showFirstLaunchLanguage()
  }

  /// Presents the one-time first-launch language entry. Only a first launch with no
  /// settings file shows it; confirming persists immediately (follow system keeps
  /// following the system but ends the entry), and canceling or closing writes nothing,
  /// so a canceled entry returns on the next launch. The menu bar language submenu keeps
  /// switching the language afterwards.
  func showFirstLaunchLanguage() {
    guard firstLaunch, languagePicker == nil else { return }
    let picker = LanguagePickerWindow(following: AppLanguage.resolved(saved: settings.language))
    picker.onChoose = { [weak self] choice in
      guard let self else { return false }
      var updated = self.settings
      updated.language = choice?.rawValue
      return self.change(updated)
    }
    picker.onClose = { [weak self] in self?.languagePicker = nil }
    languagePicker = picker
    guard let window = picker.window else { return }
    if let presentLanguageWindow {
      presentLanguageWindow(window)
    } else {
      window.center()
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
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
    // Once a topology changes, obsolete windows must never become visible again.
    let previous = overlays
    overlays = []
    for overlay in previous { overlay.close() }
    let activeIntensity = previewIntensity ?? settings.intensity
    guard let image = intensityImages[activeIntensity] else {
      throw NSError(
        domain: "SuePaper", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "No texture loaded for current intensity"])
    }
    let screens = screensProvider()
    let identities = screens.map(Self.displayIdentity)
    let replacements = screens.enumerated().compactMap { index, screen -> Overlay? in
      guard settings.coversDisplay(at: index, identities: identities) else { return nil }
      return Overlay(screen: screen, image: image)
    }
    overlays = replacements
    applyVisibility()
  }

  // Persist the system UUID, never the transient CGDirectDisplayID or the visible name.
  // https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid(_:)
  static func displayIdentity(_ screen: NSScreen) -> String? {
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
  }

  static func identity(_ app: NSRunningApplication?) -> String? {
    guard let app else { return nil }
    return app.bundleIdentifier ?? app.executableURL?.absoluteString
  }

  func applyVisibility() {
    applyVisibility(foreground: foregroundIdentityProvider())
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
    statusItem?.button?.appearsDisabled = !visible || overlays.isEmpty
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
          foreground: self?.foregroundIdentityProvider(), reorder: false)
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
      var images = intensityImages
      if updated.texture != settings.texture || updated.tone != settings.tone {
        images = try textures.images(texture: updated.texture, tone: updated.tone)
      }
      try updated.save(to: settingsURL)
      settings = updated
      intensityImages = images
      previewIntensity = nil
      if let image = images[settings.intensity] {
        for overlay in overlays { (overlay.contentView as? TextureView)?.image = image }
      }
      (intensityPanel?.contentView as? IntensitySliderView)?.percent = settings.intensity
      lastError = nil
      refreshChrome(MenuText.resolved(saved: settings.language))
      applyVisibility()
      return true
    } catch {
      record(error, notice: .saveFailed)
      return false
    }
  }

  @objc func selectDisplayMode(_ item: NSMenuItem) {
    var updated = settings
    updated.displayMode = item.tag == 0 ? "all" : "selected"
    guard updated.displayMode != settings.displayMode, change(updated) else { return }
    do { try rebuildOverlays() } catch { record(error, notice: .displaysFailed) }
  }

  @objc func toggleDisplay(_ item: NSMenuItem) {
    guard let id = item.representedObject as? String else { return }
    var updated = settings
    if updated.selectedDisplays[id] != nil {
      updated.selectedDisplays.removeValue(forKey: id)
    } else {
      let matches = screensProvider().filter { Self.displayIdentity($0) == id }
      guard matches.count == 1 else { return }
      updated.selectedDisplays[id] = matches[0].localizedName
    }
    guard change(updated) else { return }
    do { try rebuildOverlays() } catch { record(error, notice: .displaysFailed) }
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

  @objc func selectTone(_ item: NSMenuItem) {
    guard let id = item.representedObject as? String, let tone = PaperTone(rawValue: id),
      tone != settings.tone
    else { return }
    var updated = settings
    updated.tone = tone
    change(updated)
  }

  /// Shows the keyboard-focusable intensity panel anchored at the menu bar item. The
  /// panel is nonactivating: it takes keyboard focus without activating this app, so
  /// the last external foreground application (and any exclusion of it) stays in effect
  /// while the intensity is adjusted.
  @objc func openIntensity(_ item: NSMenuItem) {
    if let panel = intensityPanel {
      panel.close()
      return
    }
    guard let button = statusItem?.button, let buttonWindow = button.window else { return }
    let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let screen =
      NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.screens.first
    guard let screen else { return }
    let title = MenuText.resolved(saved: settings.language).intensityMenu
    let view = IntensitySliderView(
      intensity: previewIntensity ?? settings.intensity, title: title)
    view.onPreview = { [weak self] value in self?.previewIntensity(value) }
    view.onCommit = { [weak self] in self?.commitIntensity() }
    view.onCancel = { [weak self] in self?.cancelIntensityPreview() }
    let panel = IntensityPanel(view: view, title: title)
    intensityPanel = panel
    panel.delegate = self
    let size = panel.frame.size
    let visible = screen.visibleFrame
    var origin = NSPoint(x: buttonRect.minX, y: buttonRect.minY - size.height - 8)
    origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
    if origin.y < visible.minY + 8 || origin.y + size.height > visible.maxY {
      origin.y = max(visible.minY + 8, visible.maxY - size.height - 8)
    }
    if let presentIntensityPanel {
      presentIntensityPanel(panel, origin)
    } else {
      panel.setFrameOrigin(origin)
      panel.makeKeyAndOrderFront(nil)
    }
    panel.makeFirstResponder(view.slider)
  }

  /// Live preview from the slider: swap overlay images from the preloaded levels only.
  /// Disabled, snoozed and excluded overlays stay hidden because visibility is reapplied.
  func previewIntensity(_ value: Int) {
    guard Settings.intensityRange.contains(value) else { return }
    previewIntensity = value
    if let image = intensityImages[value] {
      for overlay in overlays { (overlay.contentView as? TextureView)?.image = image }
    }
    applyVisibility()
  }

  /// Persists the previewed intensity. On storage failure the overlays and slider UI
  /// return to the persisted level so the screen never shows a value that was not saved.
  func commitIntensity() {
    let value = previewIntensity
    previewIntensity = nil
    guard let value else { return }
    if value == settings.intensity {
      restorePersistedIntensity()
      return
    }
    var updated = settings
    updated.intensity = value
    do {
      try updated.save(to: settingsURL)
      settings = updated
      lastError = nil
      if let image = intensityImages[settings.intensity] {
        for overlay in overlays { (overlay.contentView as? TextureView)?.image = image }
      }
      applyVisibility()
    } catch {
      record(error, notice: .saveFailed)
      restorePersistedIntensity()
    }
  }

  /// Discards an uncommitted preview without touching storage and restores overlays
  /// and slider UI to the last persisted intensity.
  func cancelIntensityPreview() {
    guard previewIntensity != nil else { return }
    restorePersistedIntensity()
  }

  private func restorePersistedIntensity() {
    previewIntensity = nil
    if let image = intensityImages[settings.intensity] {
      for overlay in overlays { (overlay.contentView as? TextureView)?.image = image }
    }
    (intensityPanel?.contentView as? IntensitySliderView)?.percent = settings.intensity
    applyVisibility()
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
    if let window = scheduleWindow?.window {
      if let presentScheduleWindow {
        presentScheduleWindow(window)
      } else {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
      }
    }
    applyVisibility()
  }

  @objc func quit() { NSApp.terminate(nil) }

  @objc func changeLoginItem(_ item: NSMenuItem) {
    let enabled = item.tag == 1
    do {
      try loginItem.setEnabled(enabled)
      let state = loginItem.status()
      loginItemChangeFailed =
        enabled ? (state != .on && state != .requiresApproval) : state != .off
    } catch {
      loginItemChangeFailed = loginItem.status() != .requiresApproval || !enabled
      let error = error as NSError
      NSLog("Could not change launch at login (%@, %ld)", error.domain, error.code)
    }
  }

  func appendLoginItemMenu(to menu: NSMenu, text: MenuText) {
    let state = loginItem.status()
    let action = state == .on || state == .off ? #selector(changeLoginItem(_:)) : nil
    let item = menu.addItem(withTitle: text.launchAtLogin, action: action, keyEquivalent: "")
    item.target = self
    item.tag = state == .off ? 1 : 0
    item.state = state == .on ? .on : .off
    item.isEnabled = action != nil
    item.setAccessibilityLabel(item.title)

    if state == .requiresApproval {
      menu.addItem(withTitle: text.loginApproval, action: nil, keyEquivalent: "").isEnabled = false
      let remove = menu.addItem(
        withTitle: text.removeLoginItem, action: #selector(changeLoginItem(_:)), keyEquivalent: "")
      remove.target = self
      remove.setAccessibilityLabel(remove.title)
    } else if state == .unavailable {
      menu.addItem(withTitle: text.loginUnavailable, action: nil, keyEquivalent: "").isEnabled =
        false
    }
    if loginItemChangeFailed {
      menu.addItem(withTitle: text.loginChangeFailed, action: nil, keyEquivalent: "").isEnabled =
        false
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    populateMenu(menu, foreground: NSWorkspace.shared.frontmostApplication)
  }

  func populateMenu(_ menu: NSMenu, foreground: NSRunningApplication?) {
    menu.removeAllItems()
    let text = MenuText.resolved(saved: settings.language)
    refreshChrome(text)
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
    let chinese = text.language == .zhHans
    let displayMenu = NSMenu(title: chinese ? "显示器" : "Displays")
    item(
      chinese ? "全部显示器" : "All displays", #selector(selectDisplayMode(_:)), tag: 0,
      checked: settings.displayMode == "all", parent: displayMenu)
    item(
      chinese ? "所选显示器" : "Selected displays", #selector(selectDisplayMode(_:)), tag: 1,
      checked: settings.displayMode == "selected", parent: displayMenu)
    if settings.displayMode == "selected" {
      displayMenu.addItem(.separator())
      let screens = screensProvider()
      let ids = screens.map(Self.displayIdentity)
      let counts = Dictionary(ids.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
      var connected = Set<String>()
      for (index, pair) in zip(screens, ids).enumerated() {
        let (screen, id) = pair
        let title = "\(screen.localizedName) (\(index + 1))"
        guard let id, counts[id] == 1 else {
          let entry = displayMenu.addItem(
            withTitle: title + (chinese ? " - 无法识别" : " - Unavailable"), action: nil,
            keyEquivalent: "")
          entry.isEnabled = false
          continue
        }
        connected.insert(id)
        item(
          title, #selector(toggleDisplay(_:)), checked: settings.selectedDisplays[id] != nil,
          represented: id, parent: displayMenu)
      }
      let disconnected = settings.selectedDisplays.sorted(by: { $0.key < $1.key })
        .filter { !connected.contains($0.key) }
      for (index, entry) in disconnected.enumerated() {
        let (id, title) = entry
        item(
          "\(title) (\(index + 1))" + (chinese ? " - 未连接或不可识别" : " - Disconnected or unavailable"),
          #selector(toggleDisplay(_:)), checked: true, represented: id, parent: displayMenu)
      }
      if !ids.indices.contains(where: { settings.coversDisplay(at: $0, identities: ids) }) {
        let notice = displayMenu.addItem(
          withTitle: chinese ? "没有选中的已连接显示器" : "No selected displays connected", action: nil,
          keyEquivalent: "")
        notice.isEnabled = false
      }
    }
    submenu(chinese ? "显示器" : "Displays", displayMenu)
    let textureMenu = NSMenu(title: text.textureMenu)
    for (index, texture) in textures.catalog.enumerated() {
      item(
        MenuText.textureTitle(id: texture.id, language: text.language),
        #selector(selectTexture(_:)), tag: index,
        checked: texture.id == settings.texture, parent: textureMenu)
    }
    submenu(text.textureMenu, textureMenu)
    item(text.intensityTitle(settings.intensity), #selector(openIntensity(_:)))
    let toneMenu = NSMenu(title: text.toneMenu)
    for tone in PaperTone.allCases {
      item(
        text.toneTitle(tone), #selector(selectTone(_:)), checked: tone == settings.tone,
        represented: tone.rawValue, parent: toneMenu)
    }
    submenu(text.toneMenu, toneMenu)
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
    appendLoginItemMenu(to: menu, text: text)
    menu.addItem(.separator())
    item(text.quit, #selector(quit))
  }

  func windowWillClose(_ notification: Notification) {
    // Discard any uncommitted preview so cancelling never writes unsaved values.
    cancelIntensityPreview()
    if intensityPanel === notification.object as? NSPanel { intensityPanel = nil }
  }

  func shutdown() {
    intensityPanel?.close()
    intensityPanel = nil
    languagePicker?.close()
    languagePicker = nil
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
