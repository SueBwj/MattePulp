//! 设置持久化：%APPDATA%/Sue-Paper/settings.json

use std::fs::OpenOptions;
use std::io::{self, Write};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Deserializer, Serialize};
use sue_paper::tone::Tone;
use windows::core::PCWSTR;
use windows::Win32::Storage::FileSystem::{
    MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
};

use crate::locale::{self, Language};
use crate::schedule_clock::ScheduleSettings;
use crate::texture::TextureKind;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppProfile {
    pub identity: String,
    #[serde(default)]
    pub texture: Option<TextureKind>,
    #[serde(default)]
    pub intensity: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Settings {
    pub enabled: bool,
    pub texture: TextureKind,
    /// 目标不透明度，百分比（15..30）
    pub intensity: u32,
    pub tone: Tone,
    /// 排除列表：进程可执行文件名（小写），如 "photoshop.exe"
    pub exclusions: Vec<String>,
    pub profiles: Vec<AppProfile>,
    /// 用户选定的界面语言。缺省时跟随系统 UI 语言。
    #[serde(
        skip_serializing_if = "Option::is_none",
        serialize_with = "locale::serialize_language"
    )]
    pub language: Option<Language>,
    pub schedule: ScheduleSettings,
}

impl<'de> Deserialize<'de> for Settings {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        let fields = value
            .as_object()
            .ok_or_else(|| serde::de::Error::custom("expected a settings object"))?;
        let mut settings = Self::default();
        if let Some(value) = fields.get("enabled").and_then(|v| v.as_bool()) {
            settings.enabled = value;
        }
        if let Some(value) = fields
            .get("texture")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
        {
            settings.texture = value;
        }
        if let Some(value) = fields
            .get("intensity")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
        {
            settings.intensity = value;
        }
        if let Some(value) = fields
            .get("tone")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
        {
            settings.tone = value;
        }
        if let Some(value) = fields
            .get("exclusions")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
        {
            settings.exclusions = value;
        }
        if let Some(profiles) = fields.get("profiles").and_then(|v| v.as_array()) {
            settings.profiles = profiles
                .iter()
                .filter_map(|v| {
                    Some(AppProfile {
                        identity: v.get("identity")?.as_str()?.to_string(),
                        texture: v
                            .get("texture")
                            .and_then(|v| serde_json::from_value(v.clone()).ok()),
                        intensity: v
                            .get("intensity")
                            .and_then(|v| serde_json::from_value(v.clone()).ok()),
                    })
                })
                .collect();
        }
        settings.language = fields
            .get("language")
            .and_then(|v| locale::deserialize_language(v.clone()).ok())
            .flatten();
        if let Some(value) = fields.get("schedule") {
            settings.schedule = ScheduleSettings::from_document(value);
        }
        Ok(settings)
    }
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            enabled: true,
            texture: TextureKind::ClassicMatte,
            intensity: 20,
            tone: Tone::Original,
            exclusions: Vec::new(),
            profiles: Vec::new(),
            language: None,
            schedule: ScheduleSettings::default(),
        }
    }
}

/// 现有设置目录：%APPDATA%/Sue-Paper（APPDATA 缺失时相对当前目录）。
/// 单实例锁也以该目录为身份，与 settings.json 的解析保持一致。
pub(crate) fn settings_dir() -> PathBuf {
    let base = std::env::var("APPDATA").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(base).join("Sue-Paper")
}

fn settings_path() -> PathBuf {
    settings_dir().join("settings.json")
}

fn legacy_settings_path() -> PathBuf {
    let base = std::env::var("APPDATA").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(base)
        .join("paperman-rs")
        .join("settings.json")
}

impl Settings {
    pub fn load() -> Self {
        let current = settings_path();
        let legacy = legacy_settings_path();
        Self::load_from_paths(&current, &legacy)
    }

    fn load_from_paths(current: &Path, legacy: &Path) -> Self {
        let (path, migrate) = if current.exists() {
            (current, false)
        } else {
            (legacy, true)
        };
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let settings = serde_json::from_str::<Self>(&text)
                    .map(Self::normalized)
                    .unwrap_or_default();
                if migrate {
                    let _ = save_to_path(current, &settings);
                }
                settings
            }
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) -> io::Result<()> {
        save_to_path(&settings_path(), self)
    }

    pub fn change_tone(&mut self, tone: Tone) -> io::Result<bool> {
        self.change_tone_at(tone, &settings_path())
    }

    fn change_tone_at(&mut self, tone: Tone, path: &Path) -> io::Result<bool> {
        if self.tone == tone {
            return Ok(false);
        }
        let mut updated = self.clone();
        updated.tone = tone;
        save_to_path(path, &updated)?;
        *self = updated;
        Ok(true)
    }

    fn normalized(mut self) -> Self {
        if !matches!(self.intensity, 15 | 20 | 25 | 30) {
            self.intensity = Self::default().intensity;
        }
        self.exclusions = self
            .exclusions
            .into_iter()
            .map(|name| name.trim().to_lowercase())
            .filter(|name| !name.is_empty())
            .collect();
        let mut seen = std::collections::HashSet::new();
        self.profiles.retain_mut(|profile| {
            profile.identity = profile.identity.trim().to_lowercase();
            if !matches!(profile.intensity, None | Some(15 | 20 | 25 | 30)) {
                profile.intensity = None;
            }
            // Only absolute image paths are valid identities, never a basename.
            let bytes = profile.identity.as_bytes();
            let absolute = (bytes.len() >= 3 && bytes[1] == b':' && bytes[2] == b'\\')
                || profile.identity.starts_with("\\\\");
            absolute && seen.insert(profile.identity.clone())
        });
        self.exclusions.sort_unstable();
        self.exclusions.dedup();
        self
    }

    pub fn appearance(&self, identity: Option<&str>) -> (TextureKind, u32) {
        let profile = identity.and_then(|id| self.profiles.iter().find(|p| p.identity == id));
        (
            profile.and_then(|p| p.texture).unwrap_or(self.texture),
            profile.and_then(|p| p.intensity).unwrap_or(self.intensity),
        )
    }

    pub fn update_profiles(&mut self, profiles: Vec<AppProfile>) -> io::Result<()> {
        self.update_profiles_at(profiles, &settings_path())
    }

    fn update_profiles_at(&mut self, profiles: Vec<AppProfile>, path: &Path) -> io::Result<()> {
        let mut updated = self.clone();
        updated.profiles = profiles;
        save_to_path(path, &updated)?;
        *self = updated;
        Ok(())
    }

    /// Adds `name`, or removes it when it is already stored.
    /// Refuses to add this process's own file name. An existing own-process entry can still be removed.
    pub fn toggle_exclusion(&mut self, name: &str, own: Option<&str>) -> bool {
        if let Some(index) = self.exclusions.iter().position(|entry| entry == name) {
            self.exclusions.remove(index);
            return true;
        }
        if own == Some(name) {
            return false;
        }
        self.exclusions.push(name.to_string());
        true
    }
}

fn save_to_path(path: &Path, settings: &Settings) -> io::Result<()> {
    let settings = settings.clone().normalized();
    let text = serde_json::to_vec_pretty(&settings).map_err(io::Error::other)?;

    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let temp = path.with_extension(format!("{}.tmp", std::process::id()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temp)?;
        file.write_all(&text)?;
        file.sync_all()?;

        let from: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
        let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        unsafe {
            MoveFileExW(
                PCWSTR(from.as_ptr()),
                PCWSTR(to.as_ptr()),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
            .map_err(io::Error::other)
        }
    })();

    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::locale::Language;

    #[test]
    fn profiles_are_partial_path_scoped_and_atomic() {
        let text = r#"{"texture":"Parchment","intensity":25,"profiles":[{"identity":"C:\\One\\app.exe","texture":"VellumMist"},{"identity":"C:\\Two\\app.exe","intensity":15},{"identity":"app.exe","intensity":30},{"identity":"C:\\Bad\\app.exe","texture":"Unknown","intensity":99}]}"#;
        let mut settings = serde_json::from_str::<Settings>(text).unwrap().normalized();
        assert_eq!(settings.profiles.len(), 3);
        assert_eq!(
            settings.appearance(Some(r"c:\one\app.exe")),
            (TextureKind::VellumMist, 25)
        );
        assert_eq!(
            settings.appearance(Some(r"c:\two\app.exe")),
            (TextureKind::Parchment, 15)
        );
        assert_eq!(
            settings.appearance(Some(r"c:\bad\app.exe")),
            (TextureKind::Parchment, 25)
        );
        assert_eq!(settings.appearance(None), (TextureKind::Parchment, 25));
        assert_eq!(
            (settings.texture, settings.intensity),
            (TextureKind::Parchment, 25)
        );
        let dir = std::env::temp_dir().join(format!("mattepulp-profiles-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings.json");
        save_to_path(&path, &settings).unwrap();
        let original = settings.clone();
        let backup = dir.join("backup.json");
        std::fs::rename(&path, &backup).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(settings.update_profiles_at(vec![], &path).is_err());
        assert_eq!(settings, original);
        std::fs::remove_dir(&path).unwrap();
        std::fs::rename(&backup, &path).unwrap();
        let mut edited = settings.profiles.clone();
        edited[0].intensity = Some(30);
        edited.remove(1);
        settings.update_profiles_at(edited, &path).unwrap();
        assert_eq!(
            Settings::load_from_paths(&path, &dir.join("none")),
            settings
        );
        assert_eq!(
            settings.appearance(Some(r"c:\one\app.exe")),
            (TextureKind::VellumMist, 30)
        );
        assert_eq!(
            settings.appearance(Some(r"c:\two\app.exe")),
            (TextureKind::Parchment, 25)
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn missing_fields_use_defaults() {
        let settings: Settings = serde_json::from_str(r#"{"enabled":false}"#).unwrap();
        assert!(!settings.enabled);
        assert_eq!(settings.texture, TextureKind::ClassicMatte);
        assert_eq!(settings.intensity, 20);
        assert_eq!(settings.language, None);
        assert_eq!(settings.schedule, ScheduleSettings::default());
    }

    #[test]
    fn unknown_texture_preserves_other_settings() {
        let text = r#"{"enabled":false,"texture":"FutureTexture","intensity":25,"exclusions":[" Foo.EXE "],"language":"en","future":true}"#;
        let settings = serde_json::from_str::<Settings>(text)
            .map(Settings::normalized)
            .unwrap_or_default();
        assert!(!settings.enabled);
        assert_eq!(settings.texture, TextureKind::ClassicMatte);
        assert_eq!(settings.intensity, 25);
        assert_eq!(settings.exclusions, ["foo.exe"]);
        assert_eq!(settings.language, Some(Language::En));
    }

    #[test]
    fn invalid_fields_fall_back_independently() {
        for field in ["enabled", "texture", "intensity", "exclusions", "language"] {
            let mut value = serde_json::json!({
                "enabled": false, "texture": "Parchment", "intensity": 30,
                "exclusions": ["notes.exe"], "language": "en"
            });
            value[field] = serde_json::json!({"invalid": true});
            let settings: Settings = serde_json::from_value(value).unwrap();
            assert_eq!(settings.enabled, field == "enabled", "{field}");
            assert_eq!(
                settings.texture,
                if field == "texture" {
                    TextureKind::ClassicMatte
                } else {
                    TextureKind::Parchment
                },
                "{field}"
            );
            assert_eq!(
                settings.intensity,
                if field == "intensity" { 20 } else { 30 },
                "{field}"
            );
            assert_eq!(
                settings.exclusions,
                if field == "exclusions" {
                    vec![]
                } else {
                    vec!["notes.exe"]
                },
                "{field}"
            );
            assert_eq!(
                settings.language,
                if field == "language" {
                    None
                } else {
                    Some(Language::En)
                },
                "{field}"
            );
        }
    }

    #[test]
    fn load_migrates_legacy_settings_and_rejects_invalid_documents() {
        let dir = std::env::temp_dir().join(format!(
            "mattepulp-load-test-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let current = dir.join("Sue-Paper/settings.json");
        let legacy = dir.join("paperman-rs/settings.json");
        std::fs::create_dir_all(legacy.parent().unwrap()).unwrap();
        for (texture, intensity) in [
            ("ClassicMatte", 15),
            ("WhisperWeave", 20),
            ("Parchment", 25),
            ("VellumMist", 30),
        ] {
            std::fs::write(
                &legacy,
                format!(r#"{{"enabled":false,"texture":"{texture}","intensity":{intensity}}}"#),
            )
            .unwrap();
            let loaded = Settings::load_from_paths(&current, &legacy);
            assert!(!loaded.enabled);
            assert_eq!(loaded.intensity, intensity);
            assert_eq!(serde_json::to_value(loaded.texture).unwrap(), texture);
            assert_eq!(Settings::load_from_paths(&current, &legacy), loaded);
            std::fs::remove_file(&current).unwrap();
        }
        for text in ["{", "[]", "null", "42"] {
            std::fs::write(&current, text).unwrap();
            assert_eq!(
                Settings::load_from_paths(&current, &legacy),
                Settings::default()
            );
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn normalization_repairs_user_config() {
        let settings = Settings {
            intensity: 99,
            exclusions: vec![" Foo.EXE ".into(), "foo.exe".into(), "".into()],
            language: Some(Language::En),
            ..Settings::default()
        }
        .normalized();
        assert_eq!(settings.intensity, 20);
        assert_eq!(settings.exclusions, ["foo.exe"]);
        assert_eq!(settings.language, Some(Language::En));
    }

    #[test]
    fn schedule_round_trips_after_failed_save_without_resetting_existing_fields() {
        let dir =
            std::env::temp_dir().join(format!("mattepulp-schedule-retry-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings.json");
        let legacy = dir.join("unused-legacy.json");
        std::fs::write(
            &path,
            r#"{"enabled":false,"intensity":30,"exclusions":["demo.exe"],"language":"en","schedule":{"timed":true,"start":42,"sunset":true,"latitude":"bad","longitude":"0"}}"#,
        )
        .unwrap();
        let mut updated = Settings::load_from_paths(&path, &legacy);
        assert!(!updated.enabled && updated.intensity == 30);
        assert_eq!(updated.exclusions, ["demo.exe"]);
        assert_eq!(updated.language, Some(Language::En));
        assert!(!updated.schedule.valid_time() && !updated.schedule.valid_location());
        updated.schedule.start = "21:00".into();
        assert!(updated.schedule.valid_time());
        let backup = dir.join("backup.json");
        std::fs::rename(&path, &backup).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(save_to_path(&path, &updated).is_err());
        assert!(!Settings::load_from_paths(&backup, &legacy)
            .schedule
            .valid_time());
        std::fs::remove_dir(&path).unwrap();
        std::fs::rename(&backup, &path).unwrap();
        save_to_path(&path, &updated).unwrap();
        assert_eq!(Settings::load_from_paths(&path, &legacy), updated);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn exclusion_toggle_adds_and_removes_without_adding_this_process() {
        let mut settings = Settings::default();
        assert!(settings.toggle_exclusion("photos.exe", Some("sue-paper.exe")));
        assert_eq!(settings.exclusions, ["photos.exe"]);
        assert!(!settings.toggle_exclusion("sue-paper.exe", Some("sue-paper.exe")));
        assert_eq!(settings.exclusions, ["photos.exe"]);
        settings.exclusions.push("sue-paper.exe".into());
        assert!(settings.toggle_exclusion("sue-paper.exe", Some("sue-paper.exe")));
        assert_eq!(settings.exclusions, ["photos.exe"]);
        assert!(settings.toggle_exclusion("photos.exe", Some("sue-paper.exe")));
        assert!(settings.exclusions.is_empty());
    }

    #[test]
    fn language_choice_is_saved_and_unknown_values_do_not_reset_other_fields() {
        let chosen = Settings {
            enabled: false,
            intensity: 30,
            language: Some(Language::ZhHans),
            ..Settings::default()
        };
        let json = serde_json::to_string(&chosen).unwrap();
        assert!(json.contains("\"language\":\"zh-Hans\""));
        let loaded: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(loaded, chosen);

        let legacy = r#"{"enabled":false,"texture":"Parchment","intensity":25}"#;
        let old: Settings = serde_json::from_str(legacy).unwrap();
        assert!(!old.enabled);
        assert_eq!(old.texture, TextureKind::Parchment);
        assert_eq!(old.intensity, 25);
        assert_eq!(old.language, None);

        let unknown = r#"{"enabled":false,"intensity":15,"language":"zh-Hant"}"#;
        let fallback: Settings = serde_json::from_str(unknown).unwrap();
        assert!(!fallback.enabled);
        assert_eq!(fallback.intensity, 15);
        assert_eq!(fallback.language, None);
        assert!(!serde_json::to_string(&Settings::default())
            .unwrap()
            .contains("language"));
    }

    #[test]
    fn invalid_tone_falls_back_without_losing_other_fields() {
        let old = r#"{"enabled":false,"texture":"Parchment","intensity":25,"exclusions":["demo.exe"],"language":"en","schedule":{"timed":true,"start":"21:00","end":"22:00"}}"#;
        let expected: Settings = serde_json::from_str(old).unwrap();
        assert_eq!(expected.tone, Tone::Original);
        assert_eq!(expected.texture, TextureKind::Parchment);
        assert_eq!(expected.intensity, 25);
        assert_eq!(expected.language, Some(Language::En));
        assert_eq!(expected.exclusions, ["demo.exe"]);
        assert!(!expected.enabled && expected.schedule.timed && expected.schedule.valid_time());
        for invalid in ["null", "[]", "42", "{}", r#""Sepia""#] {
            let text = format!(r#"{},"tone":{invalid}}}"#, &old[..old.len() - 1]);
            assert_eq!(serde_json::from_str::<Settings>(&text).unwrap(), expected);
        }
    }

    #[test]
    fn tone_commit_preserves_state_on_failure_and_reopens_after_retry() {
        let dir = std::env::temp_dir().join(format!("mattepulp-tone-{}", std::process::id()));
        let path = dir.join("settings.json");
        let backup = dir.join("backup.json");
        let legacy = dir.join("unused-legacy.json");
        let mut settings = Settings {
            texture: TextureKind::VellumMist,
            intensity: 15,
            ..Settings::default()
        };
        assert!(settings.change_tone_at(Tone::LightWarm, &path).unwrap());
        assert_eq!(Settings::load_from_paths(&path, &legacy), settings);
        std::fs::rename(&path, &backup).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(settings.change_tone_at(Tone::WarmPaper, &path).is_err());
        assert_eq!(settings.tone, Tone::LightWarm);
        assert_eq!(Settings::load_from_paths(&backup, &legacy), settings);
        std::fs::remove_dir(&path).unwrap();
        std::fs::rename(&backup, &path).unwrap();
        assert!(settings.change_tone_at(Tone::WarmPaper, &path).unwrap());
        assert!(!settings.change_tone_at(Tone::WarmPaper, &path).unwrap());
        assert_eq!(Settings::load_from_paths(&path, &legacy), settings);
        assert!(settings.change_tone_at(Tone::Original, &path).unwrap());
        assert_eq!(Settings::load_from_paths(&path, &legacy), settings);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn atomic_save_replaces_existing_file() {
        let dir = std::env::temp_dir().join(format!(
            "mattepulp-settings-test-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let path = dir.join("settings.json");
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::write(&path, b"old").unwrap();
        let expected = Settings {
            enabled: false,
            ..Settings::default()
        };
        save_to_path(&path, &expected).unwrap();
        let actual: Settings = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(actual, expected);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
