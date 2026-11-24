//! Shared scheduling policy. The hosts provide their current local wall clock
//! for each UTC minute, including both sides of an offset transition.

const DAY: i64 = 24 * 60;
const PREVIEW_MINUTES: i64 = 2 * DAY;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Rules {
    pub timed: i32,
    pub sunset: i32,
    pub start: i32,
    pub end: i32,
    pub latitude: f64,
    pub longitude: f64,
}

pub const OFF: i32 = 0;
pub const UNAVAILABLE: i32 = 1;
pub const INACTIVE: i32 = 2;
pub const ACTIVE: i32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Evaluation {
    pub timed: i32,
    pub sunset: i32,
    pub visible: i32,
    pub has_next: i32,
    pub next_minute: i64,
}

impl Evaluation {
    fn automatic(self) -> Option<bool> {
        if self.timed == ACTIVE || self.sunset == ACTIVE {
            Some(true)
        } else if self.timed == INACTIVE || self.sunset == INACTIVE {
            Some(false)
        } else {
            None
        }
    }
}

pub fn evaluate(
    rules: Rules,
    now: i64,
    local_minute: impl Fn(i64) -> Option<i32>,
    manual: bool,
    suppressed: bool,
    preview: bool,
) -> Evaluation {
    let timed_valid = (0..DAY as i32).contains(&rules.start)
        && (0..DAY as i32).contains(&rules.end)
        && rules.start != rules.end;
    let solar_days = if rules.sunset != 0
        && (-90.0..=90.0).contains(&rules.latitude)
        && (-180.0..=180.0).contains(&rules.longitude)
    {
        // A longitude can move civil solar events across UTC midnight. Keep
        // adjoining days for both ends of the entire preview.
        let first_day = now.div_euclid(DAY) - 2;
        let count = if preview { 7 } else { 5 };
        (first_day..first_day + count)
            .map(|day| solar_day(day, rules.latitude, rules.longitude))
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let at = |instant| {
        let timed = if rules.timed == 0 {
            OFF
        } else if let Some(minute) = timed_valid
            .then(|| local_minute(instant))
            .flatten()
            .filter(|minute| (0..DAY as i32).contains(minute))
        {
            let active = if rules.start < rules.end {
                (rules.start..rules.end).contains(&minute)
            } else {
                minute >= rules.start || minute < rules.end
            };
            if active {
                ACTIVE
            } else {
                INACTIVE
            }
        } else {
            UNAVAILABLE
        };
        let sunset = if rules.sunset == 0 {
            OFF
        } else {
            solar_state(&solar_days, instant)
        };
        Evaluation {
            timed,
            sunset,
            visible: 0,
            has_next: 0,
            next_minute: 0,
        }
    };
    let mut current = at(now);
    let automatic = current.automatic();
    current.visible = i32::from(manual && !suppressed && automatic.unwrap_or(true));
    if preview && ((rules.timed != 0 && timed_valid) || solar_days.iter().any(Option::is_some)) {
        if let Some(next) =
            (now + 1..=now + PREVIEW_MINUTES).find(|instant| at(*instant).automatic() != automatic)
        {
            current.has_next = 1;
            current.next_minute = next;
        }
    }
    current
}

fn solar_state(days: &[Option<(i64, i64)>], now: i64) -> i32 {
    if days
        .iter()
        .flatten()
        .any(|&(rise, set)| (rise..set).contains(&now))
    {
        return INACTIVE;
    }
    for pair in days.windows(2) {
        if let [Some((_, set)), Some((rise, _))] = pair {
            if (*set..*rise).contains(&now) {
                return ACTIVE;
            }
        }
    }
    UNAVAILABLE
}

// Gregorian year start in Unix days. Euclidean division handles dates before 1970.
fn year_start(year: i64) -> i64 {
    let leap_days_before = |year: i64| {
        let prior = year - 1;
        prior.div_euclid(4) - prior.div_euclid(100) + prior.div_euclid(400)
    };
    365 * (year - 1970) + leap_days_before(year) - leap_days_before(1970)
}

fn solar_day(day: i64, latitude: f64, longitude: f64) -> Option<(i64, i64)> {
    let mut year = 1970 + day.div_euclid(365);
    while year_start(year) > day {
        year -= 1;
    }
    while year_start(year + 1) <= day {
        year += 1;
    }
    let start = year_start(year);
    let year_length = year_start(year + 1) - start;
    // NOAA Global Monitoring Laboratory, General Solar Position Calculations.
    // Evaluate the fractional year at the longitude's approximate solar noon.
    let gamma = std::f64::consts::TAU * (day as f64 - start as f64 - longitude / 360.0)
        / year_length as f64;
    let (sin, cos) = gamma.sin_cos();
    let (sin2, cos2) = (2.0 * gamma).sin_cos();
    let (sin3, cos3) = (3.0 * gamma).sin_cos();
    let eq_time =
        229.18 * (0.000075 + 0.001868 * cos - 0.032077 * sin - 0.014615 * cos2 - 0.040849 * sin2);
    let declination = 0.006918 - 0.399912 * cos + 0.070257 * sin - 0.006758 * cos2
        + 0.000907 * sin2
        - 0.002697 * cos3
        + 0.00148 * sin3;
    let lat = latitude.to_radians();
    let angle = (90.833_f64.to_radians().cos() - lat.sin() * declination.sin())
        / (lat.cos() * declination.cos());
    if !(-1.0..=1.0).contains(&angle) {
        return None;
    }
    let delta = 4.0 * angle.acos().to_degrees();
    let noon = 720.0 - 4.0 * longitude - eq_time;
    let rise = day * DAY + (noon - delta).round() as i64;
    let set = day * DAY + (noon + delta).round() as i64;
    (rise < set).then_some((rise, set))
}

#[cfg(target_os = "macos")]
#[no_mangle]
extern "C" fn matte_schedule_evaluate(
    rules: Rules,
    now: i64,
    local_minute: extern "C" fn(i64, *const std::ffi::c_void) -> i32,
    context: *const std::ffi::c_void,
    manual: i32,
    suppressed: i32,
    preview: i32,
) -> Evaluation {
    evaluate(
        rules,
        now,
        |instant| Some(local_minute(instant, context)),
        manual != 0,
        suppressed != 0,
        preview != 0,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const EQUINOX: i64 = 20_532 * DAY; // 2026-03-20 00:00 UTC
    const DEFAULTS: Rules = Rules {
        timed: 0,
        sunset: 0,
        start: 21 * 60,
        end: 6 * 60,
        latitude: f64::NAN,
        longitude: f64::NAN,
    };

    fn utc(minute: i64) -> Option<i32> {
        Some(minute.rem_euclid(DAY) as i32)
    }

    fn check(rules: Rules, now: i64) -> Evaluation {
        evaluate(rules, now, utc, true, false, true)
    }

    #[test]
    fn defaults_and_invalid_rules_follow_manual_state() {
        for manual in [false, true] {
            for suppressed in [false, true] {
                let evaluate_at = |rules| {
                    evaluate(
                        rules,
                        EQUINOX,
                        |_| panic!("no valid clock rule"),
                        manual,
                        suppressed,
                        true,
                    )
                };
                let defaults = evaluate_at(DEFAULTS);
                assert_eq!(
                    (defaults.timed, defaults.sunset, defaults.has_next),
                    (OFF, OFF, 0)
                );
                assert_eq!(defaults.visible != 0, manual && !suppressed);
                let invalid = evaluate_at(Rules {
                    timed: 1,
                    start: 360,
                    sunset: 1,
                    ..DEFAULTS
                });
                assert_eq!(
                    (invalid.timed, invalid.sunset, invalid.has_next),
                    (UNAVAILABLE, UNAVAILABLE, 0)
                );
                assert_eq!(invalid.visible, defaults.visible);
            }
        }
    }

    #[test]
    fn midnight_and_ordinary_intervals_include_the_start_only() {
        let overnight = Rules {
            timed: 1,
            ..DEFAULTS
        };
        for (minute, state, next) in [
            (20 * 60 + 59, INACTIVE, 21 * 60),
            (21 * 60, ACTIVE, 30 * 60),
            (24 * 60, ACTIVE, 30 * 60),
            (30 * 60, INACTIVE, 45 * 60),
        ] {
            let result = check(overnight, EQUINOX + minute);
            assert_eq!(result.timed, state);
            assert_eq!((result.has_next, result.next_minute), (1, EQUINOX + next));
        }
        let daytime = Rules {
            timed: 1,
            start: 480,
            end: 1020,
            ..DEFAULTS
        };
        assert_eq!(check(daytime, EQUINOX + 479).next_minute, EQUINOX + 480);
        assert_eq!(check(daytime, EQUINOX + 480).visible, 1);
        assert_eq!(check(daytime, EQUINOX + 1020).visible, 0);
    }

    #[test]
    fn overlapping_and_separate_rules_use_the_union() {
        let day = EQUINOX.div_euclid(DAY);
        let (rise, set) = solar_day(day, 0.0, 0.0).unwrap();
        let (tomorrow_rise, _) = solar_day(day + 1, 0.0, 0.0).unwrap();
        assert!((EQUINOX + 350..=EQUINOX + 380).contains(&rise));
        assert!((EQUINOX + 1070..=EQUINOX + 1100).contains(&set));
        let solar = Rules {
            sunset: 1,
            latitude: 0.0,
            longitude: 0.0,
            ..DEFAULTS
        };
        assert_eq!(check(solar, set - 1).next_minute, set);
        assert_eq!(check(solar, set).sunset, ACTIVE);
        assert_eq!(check(solar, tomorrow_rise).sunset, INACTIVE);
        let overlap = Rules { timed: 1, ..solar };
        assert_eq!(check(overlap, set - 1).visible, 0);
        assert_eq!(check(overlap, set).next_minute, tomorrow_rise);
        assert_eq!(check(overlap, tomorrow_rise - 1).visible, 1);
        assert_eq!(check(overlap, tomorrow_rise).visible, 0);
        let disjoint = Rules {
            timed: 1,
            start: 720,
            end: 780,
            ..solar
        };
        assert_eq!(check(disjoint, EQUINOX + 719).next_minute, EQUINOX + 720);
        assert_eq!(check(disjoint, EQUINOX + 720).next_minute, EQUINOX + 780);
        assert_eq!(check(disjoint, EQUINOX + 780).next_minute, set);
        let full_day = Rules {
            timed: 1,
            start: 345,
            end: 1110,
            ..solar
        };
        assert_eq!(check(full_day, set).has_next, 0);
        for (manual, suppress) in [(false, false), (true, true), (false, true)] {
            assert_eq!(
                evaluate(overlap, set, utc, manual, suppress, false).visible,
                0
            );
        }
    }

    #[test]
    fn polar_and_missing_events_fall_back_without_disabling_daily_schedule() {
        let solstice = (EQUINOX / DAY + 93) * DAY;
        for (lat, lon) in [(f64::NAN, f64::NAN), (91.0, 0.0), (89.0, 0.0), (-89.0, 0.0)] {
            let solar = Rules {
                sunset: 1,
                latitude: lat,
                longitude: lon,
                ..DEFAULTS
            };
            let daytime = solstice + 720;
            assert_eq!(
                (check(solar, daytime).sunset, check(solar, daytime).visible),
                (UNAVAILABLE, 1)
            );
            assert_eq!(check(Rules { timed: 1, ..solar }, daytime).visible, 0);
            assert_eq!(check(Rules { timed: 1, ..solar }, solstice).visible, 1);
        }
        assert_eq!(solar_state(&[Some((300, 1100)), None], 1100), UNAVAILABLE);
        assert_eq!(solar_state(&[None, Some((1740, 2540))], 1739), UNAVAILABLE);
    }

    #[test]
    fn utc_date_rollover_and_leap_years_keep_solar_events_ordered() {
        assert_eq!(year_start(1969), -365);
        assert_eq!(year_start(1970), 0);
        assert_eq!(year_start(2000), 10_957);
        assert_eq!(year_start(2001) - year_start(2000), 366);
        assert_eq!(year_start(2101) - year_start(2100), 365);
        for longitude in [179.9, -179.9] {
            let day = EQUINOX / DAY;
            let (rise, set) = solar_day(day, 0.0, longitude).unwrap();
            let (next_rise, _) = solar_day(day + 1, 0.0, longitude).unwrap();
            let rules = Rules {
                sunset: 1,
                latitude: 0.0,
                longitude,
                ..DEFAULTS
            };
            assert!(
                !(EQUINOX..EQUINOX + DAY).contains(&rise)
                    || !(EQUINOX..EQUINOX + DAY).contains(&set)
            );
            assert_eq!(check(rules, rise).sunset, INACTIVE);
            assert_eq!(check(rules, set).next_minute, next_rise);
            assert_eq!(check(rules, next_rise).sunset, INACTIVE);
        }
    }

    #[test]
    fn repeated_wall_minutes_apply_twice_and_skipped_minutes_are_never_active() {
        let rules = Rules {
            timed: 1,
            start: 90,
            end: 105,
            ..DEFAULTS
        };
        let repeat = |minute| utc(if minute < 120 { minute } else { minute - 60 });
        for (now, visible, next) in [(89, 0, 90), (90, 1, 105), (105, 0, 150), (150, 1, 165)] {
            let result = evaluate(rules, now, repeat, true, false, true);
            assert_eq!((result.visible, result.next_minute), (visible, next));
        }
        let jump = |minute| utc(if minute < 120 { minute } else { minute + 60 });
        let skipped = Rules {
            start: 135,
            end: 165,
            ..rules
        };
        let result = evaluate(skipped, 119, jump, true, false, true);
        assert_eq!((result.visible, result.next_minute), (0, DAY + 75));
        let straddles = Rules {
            start: 105,
            end: 150,
            ..rules
        };
        let result = evaluate(straddles, 119, jump, true, false, true);
        assert_eq!((result.visible, result.next_minute), (1, 120));
    }

    #[test]
    fn fresh_snapshot_handles_restart_skipped_ticks_and_changed_zone() {
        let timed = Rules {
            timed: 1,
            ..DEFAULTS
        };
        let before = EQUINOX + 1200;
        let after_waking = EQUINOX + 1380;
        assert_eq!(check(timed, before).visible, 0);
        assert_eq!(check(timed, after_waking).visible, 1);
        assert_eq!(
            check(timed, after_waking),
            check(Rules { ..timed }, after_waking)
        );
        let new_zone = |minute| utc(minute - 180);
        assert_eq!(
            evaluate(timed, after_waking, new_zone, true, false, false).visible,
            0
        );
    }
}
