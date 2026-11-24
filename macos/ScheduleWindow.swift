import AppKit

@MainActor
final class ScheduleWindow: NSWindowController {
  private let chinese: Bool
  private let timed = NSButton()
  private let sunset = NSButton()
  private let start = NSTextField(string: "")
  private let end = NSTextField(string: "")
  private let latitude = NSTextField(string: "")
  private let longitude = NSTextField(string: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let next = NSTextField(wrappingLabelWithString: "")
  private let message = NSTextField(wrappingLabelWithString: "")
  private let save: (ScheduleSettings) -> Bool
  private var previewMinute: Double?
  private var previewZone: TimeZone?
  private var previewRules: ScheduleSettings?

  static func title(_ language: AppLanguage) -> String {
    language == .zhHans ? "定时与日落" : "Schedule & Sunset"
  }

  init(
    language: AppLanguage, settings: ScheduleSettings, save: @escaping (ScheduleSettings) -> Bool
  ) {
    chinese = language == .zhHans
    self.save = save
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 470, height: 360),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = Self.title(language)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    let timedLabel = localized("启用定时", "Enable daily schedule")
    let sunsetLabel = localized("启用日落", "Enable sunset to sunrise")
    for (button, label, checked) in [
      (timed, timedLabel, settings.timed), (sunset, sunsetLabel, settings.sunset),
    ] {
      button.setButtonType(.switch)
      button.title = label
      button.state = checked ? .on : .off
    }
    start.stringValue = settings.start
    end.stringValue = settings.end
    latitude.stringValue = settings.latitude
    longitude.stringValue = settings.longitude
    start.placeholderString = "21:00"
    end.placeholderString = "06:00"
    latitude.placeholderString = "−90 … 90"
    longitude.placeholderString = "−180 … 180"
    let grid = NSGridView(views: [
      [label("开始时间（24 小时）", "Start time (24-hour)", for: start), start],
      [label("结束时间（24 小时）", "End time (24-hour)", for: end), end],
    ])
    let location = NSGridView(views: [
      [label("纬度", "Latitude", for: latitude), latitude],
      [label("经度", "Longitude", for: longitude), longitude],
    ])
    for table in [grid, location] {
      table.columnSpacing = 12
      table.rowSpacing = 7
      table.column(at: 0).width = 125
      table.xPlacement = .leading
    }
    for field in [start, end, latitude, longitude] {
      field.widthAnchor.constraint(equalToConstant: 125).isActive = true
    }
    let note = NSTextField(
      wrappingLabelWithString: localized(
        "任一规则符合时自动覆盖。坐标仅保存在本机。",
        "Either rule can allow coverage. Coordinates stay on this device."))
    note.textColor = .secondaryLabelColor
    message.textColor = .systemRed
    let cancel = NSButton(title: localized("关闭", "Close"), target: self, action: #selector(close))
    cancel.keyEquivalent = "\u{1b}"
    let apply = NSButton(
      title: localized("保存", "Save"), target: self, action: #selector(applyRules))
    apply.keyEquivalent = "\r"
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let buttons = NSStackView(views: [spacer, cancel, apply])
    buttons.spacing = 8
    let stack = NSStackView(views: [
      timed, grid, sunset, location, note, status, next, message, buttons,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 9
    stack.setCustomSpacing(15, after: grid)
    stack.setCustomSpacing(15, after: location)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = window.contentView!
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
      status.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
      next.heightAnchor.constraint(greaterThanOrEqualToConstant: 17),
      message.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
    ])
    for label in [note, status, next, message] {
      label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    window.setContentSize(NSSize(width: 470, height: stack.fittingSize.height + 34))
    window.initialFirstResponder = timed
    window.center()
  }

  required init?(coder: NSCoder) { nil }

  private func localized(_ zh: String, _ en: String) -> String { chinese ? zh : en }

  private func label(_ zh: String, _ en: String, for field: NSTextField) -> NSTextField {
    field.setAccessibilityLabel(localized(zh, en))
    return NSTextField(labelWithString: localized(zh, en))
  }

  @objc private func applyRules() {
    window?.makeFirstResponder(nil)
    var draft = ScheduleSettings()
    draft.timed = timed.state == .on
    draft.sunset = sunset.state == .on
    draft.start = start.stringValue
    draft.end = end.stringValue
    draft.latitude = latitude.stringValue
    draft.longitude = longitude.stringValue
    if !save(draft) {
      message.stringValue = localized("保存失败。请重试。", "Could not save. Try again.")
    } else if draft.timed && !draft.validTime {
      message.stringValue = localized(
        "请输入不同的开始和结束时间，格式为 HH:mm。",
        "Enter two different times in HH:mm format.")
    } else if draft.sunset && !draft.blankLocation && !draft.validLocation {
      message.stringValue = localized(
        "请输入纬度 −90 到 90、经度 −180 到 180，或清空两项。",
        "Enter latitude −90 to 90 and longitude −180 to 180, or clear both.")
    } else {
      message.stringValue = ""
    }
  }

  func refresh(
    _ result: MatteScheduleEvaluation, settings: ScheduleSettings, now: Date, zone: TimeZone,
    manual: Bool, snoozed: Bool, excluded: Bool
  ) {
    let current: String
    if !manual {
      current = localized("手动关闭", "Manually disabled")
    } else if snoozed {
      current = localized("打盹中", "Snoozed")
    } else if excluded {
      current = localized("前台应用已排除", "Frontmost app is excluded")
    } else {
      current =
        result.visible != 0 ? localized("覆盖已开启", "Coverage on") : localized("覆盖已关闭", "Coverage off")
    }
    let solar: String
    if result.sunset == MATTE_RULE_UNAVAILABLE {
      if settings.blankLocation {
        solar = localized("日落暂不可用，请输入坐标", "Sunset unavailable (enter coordinates)")
      } else if !settings.validLocation {
        solar = localized("日落暂不可用，坐标无效", "Sunset unavailable (invalid coordinates)")
      } else {
        solar = localized("日落暂不可用，缺少太阳事件", "Sunset unavailable (missing solar events)")
      }
    } else {
      solar = localized("日落 ", "Sunset ") + ruleStatus(result.sunset)
    }
    status.stringValue =
      current + localized(" · 定时 ", " · Schedule ") + ruleStatus(result.timed)
      + " · " + solar
    let minute = floor(now.timeIntervalSince1970 / 60)
    guard previewMinute != minute || previewZone != zone || previewRules != settings else { return }
    previewMinute = minute
    previewZone = zone
    previewRules = settings
    let preview = settings.evaluate(
      now: now, zone: zone, manual: manual, suppressed: false, preview: true)
    if preview.hasNext != 0 {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = zone
      formatter.dateFormat = "yyyy-MM-dd HH:mm XXX"
      let instant = Date(timeIntervalSince1970: Double(preview.nextMinute) * 60)
      next.stringValue =
        localized("下次自动变化（预计）", "Next automatic change (est.) ")
        + formatter.string(from: instant)
    } else {
      next.stringValue = localized(
        "未来 48 小时没有预计的自动变化", "No automatic change expected within 48 hours")
    }
  }

  private func ruleStatus(_ code: Int32) -> String {
    switch code {
    case MATTE_RULE_UNAVAILABLE: localized("不可用", "unavailable")
    case MATTE_RULE_INACTIVE: localized("时段外", "outside hours")
    case MATTE_RULE_ACTIVE: localized("时段内", "within hours")
    default: localized("已禁用", "disabled")
    }
  }
}
