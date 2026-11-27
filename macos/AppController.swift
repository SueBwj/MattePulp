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
  var foregroundIsOwnProvider: () -> Bool = {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
      == ProcessInfo.processInfo.processIdentifier
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
  private var lastForeground: String?
  private var activeForeground: String?
  private var loadedTexture: String?
  private var loadedTone: PaperTone?
  private var editingProfileIntensity: String?

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
    loadedTexture = settings.texture
    loadedTone = settings.tone
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
      MainActor.assumeIsolated {
        guard let self else { return }
        let identity =
          activated?.processIdentifier == ProcessInfo.processInfo.processIdentifier
          ? self.lastForeground : Self.identity(activated)
        action(self, identity)
      }
    }
    observers.append((center, token))
  }

  func rebuildOverlays() throws {
    let activeIntensity = previewIntensity ?? settings.appearance(for: activeForeground).intensity
    guard let image = intensityImages[activeIntensity] else {
      throw NSError(
        domain: "SuePaper", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "No texture loaded for current intensity"])
    }
    let replacements = screensProvider().map { Overlay(screen: $0, image: image) }
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
    applyVisibility(
      foreground: foregroundIsOwnProvider() ? lastForeground : foregroundIdentityProvider())
  }

  func applyVisibility(foreground: String?) {
    updateVisibility(foreground: foreground, reorder: true)
  }

  private func updateVisibility(foreground: String?, reorder: Bool) {
    activeForeground = foreground
    lastForeground = foreground
    let appearance = settings.appearance(for: foreground)
    do {
      if loadedTexture != appearance.texture || loadedTone != settings.tone {
        intensityImages = try textures.images(texture: appearance.texture, tone: settings.tone)
        loadedTexture = appearance.texture
        loadedTone = settings.tone
      }
      let profile = settings.profiles.first { $0.identity == foreground }
      let previewApplies =
        editingProfileIntensity == foreground
        || (editingProfileIntensity == nil && profile?.intensity == nil)
      let intensity = (previewApplies ? previewIntensity : nil) ?? appearance.intensity
      if let image = intensityImages[intensity] {
        for overlay in overlays { (overlay.contentView as? TextureView)?.image = image }
      }
    } catch { record(error, notice: .displaysFailed) }
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
        self?.applyVisibility()
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
      let appearance = updated.appearance(for: activeForeground)
      let images = try textures.images(texture: appearance.texture, tone: updated.tone)
      try updated.save(to: settingsURL)
      settings = updated
      intensityImages = images
      loadedTexture = appearance.texture
      loadedTone = updated.tone
      previewIntensity = nil
      (intensityPanel?.contentView as? IntensitySliderView)?.percent = appearance.intensity
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
    editingProfileIntensity = item.representedObject as? String
    let initial =
      editingProfileIntensity.flatMap { identity in
        settings.profiles.first { $0.identity == identity }?.intensity
      } ?? settings.intensity
    let title = MenuText.resolved(saved: settings.language).intensityMenu
    let view = IntensitySliderView(
      intensity: previewIntensity ?? initial, title: title)
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
    if editingProfileIntensity == nil || editingProfileIntensity == activeForeground {
      if let image = intensityImages[value] {
        for overlay in overlays { (overlay.contentView as? TextureView)?.image = image }
      }
    }
    applyVisibility()
  }

  /// Persists the previewed intensity. On storage failure the overlays and slider UI
  /// return to the persisted level so the screen never shows a value that was not saved.
  func commitIntensity() {
    let value = previewIntensity
    previewIntensity = nil
    guard let value else { return }
    var updated = settings
    if let identity = editingProfileIntensity {
      guard let index = updated.profiles.firstIndex(where: { $0.identity == identity }) else {
        restorePersistedIntensity()
        return
      }
      updated.profiles[index].intensity = value
    } else {
      updated.intensity = value
    }
    if !change(updated) { restorePersistedIntensity() }
  }

  /// Discards an uncommitted preview without touching storage and restores overlays
  /// and slider UI to the last persisted intensity.
  func cancelIntensityPreview() {
    guard previewIntensity != nil else { return }
    restorePersistedIntensity()
  }

  private func restorePersistedIntensity() {
    previewIntensity = nil
    let intensity = settings.appearance(for: activeForeground).intensity
    if let image = intensityImages[intensity] {
      for overlay in overlays { (overlay.contentView as? TextureView)?.image = image }
    }
    (intensityPanel?.contentView as? IntensitySliderView)?.percent = intensity
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

  @objc func createProfile() {
    guard let identity = menuForeground,
      !settings.profiles.contains(where: { $0.identity == identity })
    else { return }
    var updated = settings
    updated.profiles.append(AppProfile(identity: identity))
    change(updated)
  }

  @objc func removeProfile(_ item: NSMenuItem) {
    guard let identity = item.representedObject as? String else { return }
    var updated = settings
    updated.profiles.removeAll { $0.identity == identity }
    change(updated)
  }

  @objc func setProfileTexture(_ item: NSMenuItem) {
    guard let identity = item.representedObject as? String else { return }
    var updated = settings
    guard let index = updated.profiles.firstIndex(where: { $0.identity == identity }) else {
      return
    }
    guard item.tag == -1 || Settings.textures.indices.contains(item.tag) else { return }
    updated.profiles[index].texture = item.tag < 0 ? nil : Settings.textures[item.tag]
    change(updated)
  }

  @objc func resetProfileIntensity(_ item: NSMenuItem) {
    guard let identity = item.representedObject as? String else { return }
    var updated = settings
    guard let index = updated.profiles.firstIndex(where: { $0.identity == identity }) else {
      return
    }
    updated.profiles[index].intensity = nil
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
    let identity =
      foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier
      ? lastForeground : Self.identity(foreground)
    populateMenu(menu, foregroundIdentity: identity, foregroundName: foreground?.localizedName)
  }

  func populateMenu(_ menu: NSMenu, foregroundIdentity: String?, foregroundName: String?) {
    menu.removeAllItems()
    let text = MenuText.resolved(saved: settings.language)
    refreshChrome(text)
    menuForeground = foregroundIdentity
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
      let name = foregroundName ?? text.unnamedApp
      item(
        text.exclusionTitle(name: name, excluded: excluded),
        #selector(toggleExclusion), checked: excluded)
    }
    let profilesMenu = NSMenu()
    let chinese = text.language == .zhHans
    let create = NSMenuItem(
      title: (chinese ? "为当前应用创建配置" : "Create profile for current app")
        + (menuForeground.map { " (\($0))" } ?? ""),
      action: #selector(createProfile), keyEquivalent: "")
    create.target = self
    create.isEnabled =
      menuForeground != nil
      && !settings.profiles.contains { $0.identity == menuForeground }
    profilesMenu.addItem(create)
    for profile in settings.profiles {
      let profileMenu = NSMenu()
      let texturesMenu = NSMenu()
      item(
        chinese ? "跟随全局" : "Use global", #selector(setProfileTexture(_:)), tag: -1,
        checked: profile.texture == nil, represented: profile.identity, parent: texturesMenu)
      for (index, texture) in Settings.textures.enumerated() {
        item(
          MenuText.textureTitle(id: texture, language: text.language),
          #selector(setProfileTexture(_:)), tag: index, checked: profile.texture == texture,
          represented: profile.identity, parent: texturesMenu)
      }
      let textureEntry = NSMenuItem(title: text.textureMenu, action: nil, keyEquivalent: "")
      textureEntry.submenu = texturesMenu
      profileMenu.addItem(textureEntry)
      item(
        text.intensityTitle(profile.intensity ?? settings.intensity), #selector(openIntensity(_:)),
        represented: profile.identity, parent: profileMenu)
      item(
        chinese ? "强度跟随全局" : "Use global intensity", #selector(resetProfileIntensity(_:)),
        checked: profile.intensity == nil, represented: profile.identity, parent: profileMenu)
      item(
        chinese ? "移除配置" : "Remove profile", #selector(removeProfile(_:)),
        represented: profile.identity, parent: profileMenu)
      let entry = NSMenuItem(title: profile.identity, action: nil, keyEquivalent: "")
      entry.submenu = profileMenu
      profilesMenu.addItem(entry)
    }
    submenu(chinese ? "应用配置" : "App profiles", profilesMenu)
    if let lastError { item(text.notice(lastError), nil) }
    menu.addItem(.separator())
    appendLoginItemMenu(to: menu, text: text)
    menu.addItem(.separator())
    item(text.quit, #selector(quit))
  }

  func windowWillClose(_ notification: Notification) {
    // Discard any uncommitted preview so cancelling never writes unsaved values.
    cancelIntensityPreview()
    if intensityPanel === notification.object as? NSPanel {
      intensityPanel = nil
      editingProfileIntensity = nil
    }
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
