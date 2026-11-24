import Foundation

struct ScheduleSettings: Codable, Equatable {
  var timed = false
  var sunset = false
  var start = "21:00"
  var end = "06:00"
  var latitude = ""
  var longitude = ""

  init() {}

  init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    func string(_ key: CodingKeys, default fallback: String) -> String {
      guard fields.contains(key) else { return fallback }
      return (try? fields.decode(String.self, forKey: key)) ?? ""
    }
    timed = (try? fields.decode(Bool.self, forKey: .timed)) ?? false
    sunset = (try? fields.decode(Bool.self, forKey: .sunset)) ?? false
    start = string(.start, default: start)
    end = string(.end, default: end)
    latitude = string(.latitude, default: "")
    longitude = string(.longitude, default: "")
  }

  var blankLocation: Bool { latitude.trimmed.isEmpty && longitude.trimmed.isEmpty }
  var validLocation: Bool {
    (-90...90).contains(Self.coordinate(latitude))
      && (-180...180).contains(Self.coordinate(longitude))
  }

  var validTime: Bool {
    let startMinute = Self.minute(start)
    let endMinute = Self.minute(end)
    return startMinute >= 0 && endMinute >= 0 && startMinute != endMinute
  }

  private static func minute(_ text: String) -> Int32 {
    let bytes = Array(text.trimmed.utf8)
    guard bytes.count == 5, bytes[2] == 58,
      [bytes[0], bytes[1], bytes[3], bytes[4]].allSatisfy({ (48...57).contains($0) })
    else { return -1 }
    let hour = Int32(bytes[0] - 48) * 10 + Int32(bytes[1] - 48)
    let minute = Int32(bytes[3] - 48) * 10 + Int32(bytes[4] - 48)
    return hour < 24 && minute < 60 ? hour * 60 + minute : -1
  }

  private static func coordinate(_ text: String) -> Double {
    let text = text.trimmed
    guard text.utf8.allSatisfy({ (48...57).contains($0) || [43, 45, 46].contains($0) })
    else { return .nan }
    return Double(text) ?? .nan
  }

  func evaluate(
    now: Date, zone: TimeZone, manual: Bool, suppressed: Bool, preview: Bool = false
  ) -> MatteScheduleEvaluation {
    let rules = MatteRules(
      timed: timed ? 1 : 0, sunset: sunset ? 1 : 0, start: Self.minute(start),
      end: Self.minute(end), latitude: Self.coordinate(latitude),
      longitude: Self.coordinate(longitude))
    return withUnsafePointer(to: zone) { context in
      matte_schedule_evaluate(
        rules, Int64(floor(now.timeIntervalSince1970 / 60)),
        { minute, context in
          guard let context else { return -1 }
          let zone = context.assumingMemoryBound(to: TimeZone.self).pointee
          let seconds = minute * 60
          let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
          let secondsOfDay = ((seconds + Int64(offset)) % 86_400 + 86_400) % 86_400
          return Int32(secondsOfDay / 60)
        },
        context, manual ? 1 : 0, suppressed ? 1 : 0, preview ? 1 : 0)
    }
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
