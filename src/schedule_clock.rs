use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use sue_paper::schedule::{self, Evaluation, Rules};
use windows::Win32::Foundation::{FILETIME, SYSTEMTIME};
use windows::Win32::System::Time::{
    FileTimeToSystemTime, GetDynamicTimeZoneInformation, SystemTimeToFileTime,
    SystemTimeToTzSpecificLocalTimeEx, DYNAMIC_TIME_ZONE_INFORMATION,
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ScheduleSettings {
    pub timed: bool,
    pub sunset: bool,
    pub start: String,
    pub end: String,
    pub latitude: String,
    pub longitude: String,
}

impl Default for ScheduleSettings {
    fn default() -> Self {
        Self {
            timed: false,
            sunset: false,
            start: "21:00".into(),
            end: "06:00".into(),
            latitude: String::new(),
            longitude: String::new(),
        }
    }
}

impl ScheduleSettings {
    pub fn from_document(value: &serde_json::Value) -> Self {
        let defaults = Self::default();
        let read_string = |key, fallback: String| {
            value
                .get(key)
                .map_or(fallback, |field| field.as_str().unwrap_or("").into())
        };
        Self {
            timed: value
                .get("timed")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false),
            sunset: value
                .get("sunset")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false),
            start: read_string("start", defaults.start),
            end: read_string("end", defaults.end),
            latitude: read_string("latitude", defaults.latitude),
            longitude: read_string("longitude", defaults.longitude),
        }
    }

    pub fn valid_time(&self) -> bool {
        let start = parse_minute(&self.start);
        let end = parse_minute(&self.end);
        start >= 0 && end >= 0 && start != end
    }

    pub fn blank_location(&self) -> bool {
        self.latitude.trim().is_empty() && self.longitude.trim().is_empty()
    }

    pub fn valid_location(&self) -> bool {
        (-90.0..=90.0).contains(&parse_coordinate(&self.latitude))
            && (-180.0..=180.0).contains(&parse_coordinate(&self.longitude))
    }

    pub fn evaluate(
        &self,
        clock: &Clock,
        manual: bool,
        suppressed: bool,
        preview: bool,
    ) -> Evaluation {
        schedule::evaluate(
            Rules {
                timed: i32::from(self.timed),
                sunset: i32::from(self.sunset),
                start: parse_minute(&self.start),
                end: parse_minute(&self.end),
                latitude: parse_coordinate(&self.latitude),
                longitude: parse_coordinate(&self.longitude),
            },
            clock.minute,
            |instant| {
                clock
                    .local(instant)
                    .map(|time| i32::from(time.wHour) * 60 + i32::from(time.wMinute))
            },
            manual,
            suppressed,
            preview,
        )
    }
}

fn parse_minute(text: &str) -> i32 {
    if let [a @ b'0'..=b'9', b @ b'0'..=b'9', b':', c @ b'0'..=b'9', d @ b'0'..=b'9'] =
        *text.trim().as_bytes()
    {
        let hour = (a - b'0') * 10 + b - b'0';
        let minute = (c - b'0') * 10 + d - b'0';
        if hour < 24 && minute < 60 {
            return i32::from(hour) * 60 + i32::from(minute);
        }
    }
    -1
}

fn parse_coordinate(text: &str) -> f64 {
    let text = text.trim();
    if !text
        .bytes()
        .all(|byte| matches!(byte, b'0'..=b'9' | b'.' | b'+' | b'-'))
    {
        return f64::NAN;
    }
    text.parse().unwrap_or(f64::NAN)
}

const TICKS_PER_MINUTE: u64 = 60 * 10_000_000;
const WINDOWS_EPOCH_MINUTES: i64 = 194_074_560;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Clock {
    pub minute: i64,
    zone: Option<DYNAMIC_TIME_ZONE_INFORMATION>,
}

impl Clock {
    pub fn now() -> Self {
        let minute = match SystemTime::now().duration_since(UNIX_EPOCH) {
            Ok(duration) => (duration.as_secs() / 60) as i64,
            Err(error) => {
                let duration = error.duration();
                -((duration.as_secs() / 60) as i64)
                    - i64::from(duration.as_secs() % 60 != 0 || duration.subsec_nanos() != 0)
            }
        };
        let mut zone = DYNAMIC_TIME_ZONE_INFORMATION::default();
        let valid = unsafe { GetDynamicTimeZoneInformation(&mut zone) } != u32::MAX;
        Self {
            minute,
            zone: valid.then_some(zone),
        }
    }

    fn local(&self, minute: i64) -> Option<SYSTEMTIME> {
        let zone = self.zone.as_ref()?;
        let ticks = u64::try_from(minute.checked_add(WINDOWS_EPOCH_MINUTES)?)
            .ok()?
            .checked_mul(TICKS_PER_MINUTE)?;
        let utc_file = FILETIME {
            dwLowDateTime: ticks as u32,
            dwHighDateTime: (ticks >> 32) as u32,
        };
        let mut utc = SYSTEMTIME::default();
        let mut local = SYSTEMTIME::default();
        unsafe {
            FileTimeToSystemTime(&utc_file, &mut utc).ok()?;
            SystemTimeToTzSpecificLocalTimeEx(Some(zone), &utc, &mut local).ok()?;
        }
        Some(local)
    }

    pub fn format_local(&self, minute: i64) -> Option<String> {
        let local = self.local(minute)?;
        let mut file = FILETIME::default();
        unsafe { SystemTimeToFileTime(&local, &mut file).ok()? };
        let ticks = (u64::from(file.dwHighDateTime) << 32) | u64::from(file.dwLowDateTime);
        let offset = (ticks / TICKS_PER_MINUTE) as i64 - WINDOWS_EPOCH_MINUTES - minute;
        let sign = if offset < 0 { '-' } else { '+' };
        let offset = offset.abs();
        Some(format!(
            "{:04}-{:02}-{:02} {:02}:{:02} UTC{sign}{:02}:{:02}",
            local.wYear,
            local.wMonth,
            local.wDay,
            local.wHour,
            local.wMinute,
            offset / 60,
            offset % 60
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::System::Time::EnumDynamicTimeZoneInformation;

    #[test]
    fn native_wall_clock_matches_shared_dst_fixture() {
        let mut zone = DYNAMIC_TIME_ZONE_INFORMATION::default();
        let expected_key: Vec<_> = "Eastern Standard Time".encode_utf16().collect();
        let zone = (0..)
            .map_while(|index| {
                (unsafe { EnumDynamicTimeZoneInformation(index, &mut zone) } == 0).then_some(zone)
            })
            .find(|zone| {
                let end = zone
                    .TimeZoneKeyName
                    .iter()
                    .position(|&code| code == 0)
                    .unwrap_or(128);
                zone.TimeZoneKeyName[..end] == expected_key
            })
            .expect("Windows Eastern time zone");
        for row in include_str!("../tests/schedule-zone.csv").lines() {
            let (instant, wall) = row.split_once(',').unwrap();
            let minute = instant.parse().unwrap();
            let wall: u16 = wall.parse().unwrap();
            let clock = Clock {
                minute,
                zone: Some(zone),
            };
            let time = clock.local(minute).unwrap();
            assert_eq!(time.wHour * 60 + time.wMinute, wall);
            let rules = ScheduleSettings {
                timed: true,
                start: format!("{:02}:{:02}", wall / 60, wall % 60),
                end: "04:00".into(),
                ..ScheduleSettings::default()
            };
            assert_eq!(rules.evaluate(&clock, true, false, false).visible, 1);
        }
    }
}
