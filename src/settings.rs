//! 设置持久化：%APPDATA%/Sue-Paper/settings.json

use std::fs::OpenOptions;
use std::io::{self, Write};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use windows::core::PCWSTR;
use windows::Win32::Storage::FileSystem::{
    MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
};

use crate::locale::{self, Language};
use crate::texture::TextureKind;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub enabled: bool,
    pub texture: TextureKind,
    /// 目标不透明度，百分比（15..30）
    pub intensity: u32,
    /// 排除列表：进程可执行文件名（小写），如 "photoshop.exe"
    pub exclusions: Vec<String>,
    /// 用户选定的界面语言。缺省时跟随系统 UI 语言。
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "locale::serialize_language",
        deserialize_with = "locale::deserialize_language"
    )]
    pub language: Option<Language>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            enabled: true,
            texture: TextureKind::ClassicMatte,
            intensity: 20,
            exclusions: Vec::new(),
            language: None,
        }
    }
}

fn settings_path() -> PathBuf {
    let base = std::env::var("APPDATA").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(base).join("Sue-Paper").join("settings.json")
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
        let (path, migrate) = if current.exists() {
            (current.clone(), false)
        } else {
            (legacy, true)
        };
        match std::fs::read_to_string(&path) {
            Ok(text) => {
                let settings = serde_json::from_str::<Self>(&text)
                    .map(Self::normalized)
                    .unwrap_or_default();
                if migrate {
                    let _ = save_to_path(&current, &settings);
                }
                settings
            }
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) -> io::Result<()> {
        save_to_path(&settings_path(), self)
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
        self.exclusions.sort_unstable();
        self.exclusions.dedup();
        self
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
    fn missing_fields_use_defaults() {
        let settings: Settings = serde_json::from_str(r#"{"enabled":false}"#).unwrap();
        assert!(!settings.enabled);
        assert_eq!(settings.texture, TextureKind::ClassicMatte);
        assert_eq!(settings.intensity, 20);
        assert_eq!(settings.language, None);
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
