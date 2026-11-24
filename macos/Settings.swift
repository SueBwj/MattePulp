import Foundation

struct Settings: Codable, Equatable {
  static let textures = ["ClassicMatte", "WhisperWeave", "Parchment", "VellumMist"]
  static let intensityRange = 15...30
  static let defaultIntensity = 20
  var enabled = true
  var texture = "ClassicMatte"
  var intensity = 20
  // Bundle identifiers, or executable URLs for apps without a bundle identifier.
  var exclusions: [String] = []
  /// Saved interface language. Nil follows the system UI language.
  var language: String?
  var schedule = ScheduleSettings()

  init() {}

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    texture = try values.decodeIfPresent(String.self, forKey: .texture) ?? "ClassicMatte"
    intensity = try values.decodeIfPresent(Int.self, forKey: .intensity) ?? Self.defaultIntensity
    exclusions = try values.decodeIfPresent([String].self, forKey: .exclusions) ?? []
    language = try values.decodeIfPresent(String.self, forKey: .language)
    schedule = (try? values.decode(ScheduleSettings.self, forKey: .schedule)) ?? ScheduleSettings()
    normalize()
  }

  mutating func normalize() {
    if !Self.textures.contains(texture) { texture = "ClassicMatte" }
    if !Self.intensityRange.contains(intensity) { intensity = Self.defaultIntensity }
    if let language, AppLanguage(rawValue: language) == nil { self.language = nil }
    exclusions = Array(
      Set(
        exclusions.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    ).sorted()
  }

  static func load(from url: URL) throws -> Settings {
    guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
    return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
  }

  func save(to url: URL) throws {
    var normalized = self
    normalized.normalize()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(normalized).write(to: url, options: .atomic)
  }
}

struct Visibility {
  var snoozeUntil: Date?

  func isSnoozed(at now: Date) -> Bool { snoozeUntil.map { $0 > now } ?? false }

  func isVisible(
    settings: Settings, foreground: String?, now: Date = Date(), zone: TimeZone = .current
  ) -> Bool {
    settings.schedule.evaluate(
      now: now, zone: zone, manual: settings.enabled,
      suppressed: isSnoozed(at: now) || settings.exclusions.contains(foreground ?? "")
    ).visible != 0
  }
}
