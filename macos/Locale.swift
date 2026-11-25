import Foundation

enum AppLanguage: String {
  case zhHans = "zh-Hans"
  case en = "en"

  var menuTitle: String {
    switch self {
    case .zhHans: "中文"
    case .en: "English"
    }
  }

  static func resolved(
    saved: String?, preferred: [String] = Locale.preferredLanguages
  ) -> AppLanguage {
    if let saved, let language = AppLanguage(rawValue: saved) { return language }
    guard let identifier = preferred.first else { return .en }
    return fromIdentifier(identifier)
  }

  static func fromIdentifier(_ identifier: String) -> AppLanguage {
    let tag =
      identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: ".").first
      .map(String.init) ?? ""
    let simplified =
      tag.hasPrefix("zh-hans") || tag.hasPrefix("zh-cn") || tag.hasPrefix("zh-sg")
      || tag.hasPrefix("zh-chs")
    return simplified ? .zhHans : .en
  }
}

enum MenuNotice {
  case loadFailed
  case displaysFailed
  case saveFailed

  var logSummary: String {
    switch self {
    case .loadFailed: "Could not load settings; using defaults"
    case .displaysFailed: "Could not update displays"
    case .saveFailed: "Change not saved; check settings storage and app resources"
    }
  }
}

struct MenuText {
  let language: AppLanguage
  let product: String
  let toggle: String
  let textureMenu: String
  let textures: [String]
  let intensityMenu: String
  let intensities: [String]
  let snoozeMenu: String
  let snooze5: String
  let snooze15: String
  let resume: String
  let languageMenu: String
  let quit: String
  let loadFailed: String
  let displaysFailed: String
  let saveFailed: String

  static func resolved(
    saved: String?, preferred: [String] = Locale.preferredLanguages
  ) -> MenuText {
    make(AppLanguage.resolved(saved: saved, preferred: preferred))
  }

  static func make(_ language: AppLanguage) -> MenuText {
    let textures = Settings.textures.map { textureTitle(id: $0, language: language) }
    let intensities = Settings.intensityRange.map { "\($0)%" }
    switch language {
    case .zhHans:
      return MenuText(
        language: language,
        product: "柔纸",
        toggle: "启用纸张纹理",
        textureMenu: "纹理",
        textures: textures,
        intensityMenu: "强度",
        intensities: intensities,
        snoozeMenu: "打盹",
        snooze5: "暂停 5 分钟",
        snooze15: "暂停 15 分钟",
        resume: "立即恢复",
        languageMenu: "语言",
        quit: "退出柔纸",
        loadFailed: "未能读取设置，已改用默认值",
        displaysFailed: "未能更新显示器",
        saveFailed: "更改没有保存，请检查设置存储和应用资源")
    case .en:
      return MenuText(
        language: language,
        product: "MattePulp",
        toggle: "Enable paper texture",
        textureMenu: "Texture",
        textures: textures,
        intensityMenu: "Intensity",
        intensities: intensities,
        snoozeMenu: "Snooze",
        snooze5: "Snooze 5 minutes",
        snooze15: "Snooze 15 minutes",
        resume: "Resume now",
        languageMenu: "Language",
        quit: "Quit MattePulp",
        loadFailed: "Could not load settings; using defaults",
        displaysFailed: "Could not update displays",
        saveFailed: "Change not saved; check settings storage and app resources")
    }
  }

  static func textureTitle(id: String, language: AppLanguage) -> String {
    switch (id, language) {
    case ("ClassicMatte", .zhHans): "经典哑光"
    case ("ClassicMatte", .en): "Classic Matte"
    case ("WhisperWeave", .zhHans): "织物纹理"
    case ("WhisperWeave", .en): "Whisper Weave"
    case ("Parchment", .zhHans): "羊皮纸"
    case ("Parchment", .en): "Sunbaked Parchment"
    case ("VellumMist", .zhHans): "薄纱雾面"
    case ("VellumMist", .en): "Vellum Mist"
    default: id
    }
  }

  func exclusionTitle(name: String, excluded: Bool) -> String {
    switch (language, excluded) {
    case (.zhHans, true): "取消排除 \(name)"
    case (.zhHans, false): "排除 \(name)"
    case (.en, true): "Include \(name)"
    case (.en, false): "Exclude \(name)"
    }
  }

  func intensityTitle(_ percent: Int) -> String {
    "\(intensityMenu) - \(percent)%"
  }

  var toneMenu: String { language == .zhHans ? "色调" : "Tone" }

  func toneTitle(_ tone: PaperTone) -> String {
    switch (language, tone) {
    case (.zhHans, .original): "原色"
    case (.zhHans, .lightWarm): "浅暖"
    case (.zhHans, .warmPaper): "暖纸"
    case (.en, .original): "Original"
    case (.en, .lightWarm): "Light Warm"
    case (.en, .warmPaper): "Warm Paper"
    }
  }

  func notice(_ notice: MenuNotice) -> String {
    switch notice {
    case .loadFailed: loadFailed
    case .displaysFailed: displaysFailed
    case .saveFailed: saveFailed
    }
  }

  var unnamedApp: String {
    switch language {
    case .zhHans: "当前应用"
    case .en: "current app"
    }
  }

  var commandLabels: [String] {
    [
      product, toggle, textureMenu, intensityMenu, snoozeMenu, snooze5, snooze15, resume,
      toneMenu, languageMenu, quit, loadFailed, displaysFailed, saveFailed, unnamedApp,
    ] + textures + intensities + PaperTone.allCases.map(toneTitle)
  }
}
