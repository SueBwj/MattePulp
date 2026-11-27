import Foundation

enum PaperTone: String, CaseIterable, Codable {
  case original = "Original"
  case lightWarm = "LightWarm"
  case warmPaper = "WarmPaper"
}

struct AppProfile: Codable, Equatable {
  var identity: String
  var texture: String?
  var intensity: Int?

  init(identity: String, texture: String? = nil, intensity: Int? = nil) {
    self.identity = identity
    self.texture = texture
    self.intensity = intensity
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    identity = try values.decode(String.self, forKey: .identity)
    texture = try? values.decode(String.self, forKey: .texture)
    intensity = try? values.decode(Int.self, forKey: .intensity)
  }
}

private struct DecodableProfile: Decodable {
  let value: AppProfile?
  init(from decoder: Decoder) throws { value = try? AppProfile(from: decoder) }
}

struct Settings: Codable, Equatable {
  static let textures = ["ClassicMatte", "WhisperWeave", "Parchment", "VellumMist"]
  static let intensityRange = 15...30
  static let defaultIntensity = 20
  var enabled = true
  var texture = "ClassicMatte"
  var intensity = 20
  var tone = PaperTone.original
  // Bundle identifiers, or executable URLs for apps without a bundle identifier.
  var exclusions: [String] = []
  var profiles: [AppProfile] = []
  /// Saved interface language. Nil follows the system UI language.
  var language: String?
  var schedule = ScheduleSettings()

  init() {}

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    texture = try values.decodeIfPresent(String.self, forKey: .texture) ?? "ClassicMatte"
    intensity = try values.decodeIfPresent(Int.self, forKey: .intensity) ?? Self.defaultIntensity
    tone = (try? values.decode(PaperTone.self, forKey: .tone)) ?? .original
    exclusions = try values.decodeIfPresent([String].self, forKey: .exclusions) ?? []
    profiles =
      (try? values.decode([DecodableProfile].self, forKey: .profiles))?.compactMap(\.value) ?? []
    language = try values.decodeIfPresent(String.self, forKey: .language)
    schedule = (try? values.decode(ScheduleSettings.self, forKey: .schedule)) ?? ScheduleSettings()
    normalize()
  }

  mutating func normalize() {
    if !Self.textures.contains(texture) { texture = "ClassicMatte" }
    if !Self.intensityRange.contains(intensity) { intensity = Self.defaultIntensity }
    if let language, AppLanguage(rawValue: language) == nil { self.language = nil }
    var seen = Set<String>()
    profiles = profiles.compactMap { profile in
      var profile = profile
      profile.identity = profile.identity.trimmingCharacters(in: .whitespacesAndNewlines)
      let fileURL = URL(string: profile.identity)
      let isPath = fileURL?.isFileURL == true && fileURL?.path.hasPrefix("/") == true
      let isBundle =
        !profile.identity.isEmpty
        && profile.identity.unicodeScalars.allSatisfy {
          CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-."
          ).contains($0)
        }
      guard isPath || isBundle, seen.insert(profile.identity).inserted else { return nil }
      if let texture = profile.texture, !Self.textures.contains(texture) { profile.texture = nil }
      if let intensity = profile.intensity, !Self.intensityRange.contains(intensity) {
        profile.intensity = nil
      }
      return profile
    }
    exclusions = Array(
      Set(
        exclusions.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    ).sorted()
  }

  func appearance(for identity: String?) -> (texture: String, intensity: Int) {
    let profile = profiles.first { $0.identity == identity }
    return (profile?.texture ?? texture, profile?.intensity ?? intensity)
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
