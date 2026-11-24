//! 托盘菜单语言：简体中文或英文，整份菜单只用其中一种。
//! 未保存选择时跟随 Windows UI 语言；不是简体中文则用英文。

use serde::{Deserialize, Deserializer, Serializer};
use windows::Win32::Globalization::{
    GetUserDefaultLocaleName, GetUserDefaultUILanguage, LCIDToLocaleName,
};

use crate::texture::KIND_NAMES;
use crate::{
    ID_EXCLUDE, ID_EXIT, ID_INT_BASE, ID_LANG_EN, ID_LANG_ZH, ID_RESUME, ID_SCHEDULE, ID_SNOOZE_15,
    ID_SNOOZE_5, ID_TEX_BASE, ID_TOGGLE, INTENSITIES,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Language {
    ZhHans,
    En,
}

impl Language {
    pub fn from_tag(value: &str) -> Option<Self> {
        match value {
            "zh-Hans" => Some(Self::ZhHans),
            "en" => Some(Self::En),
            _ => None,
        }
    }

    pub fn tag(self) -> &'static str {
        match self {
            Self::ZhHans => "zh-Hans",
            Self::En => "en",
        }
    }
}

pub fn serialize_language<S>(language: &Option<Language>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    match language {
        Some(language) => serializer.serialize_str(language.tag()),
        None => serializer.serialize_none(),
    }
}

pub fn deserialize_language<'de, D>(deserializer: D) -> Result<Option<Language>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<String>::deserialize(deserializer)?;
    Ok(value.as_deref().and_then(Language::from_tag))
}

/// `zh-Hans`、`zh-CN`、`zh-SG` 和 `zh-CHS` 视为简体中文。
/// 繁体中文以及其他 UI 语言使用英文。
pub fn language_from_locale_name(name: &str) -> Language {
    let tag = name
        .trim()
        .trim_matches('\0')
        .to_ascii_lowercase()
        .replace('_', "-");
    let tag = tag.split('.').next().unwrap_or("");
    let simplified = tag.starts_with("zh-hans")
        || tag.starts_with("zh-cn")
        || tag.starts_with("zh-sg")
        || tag.starts_with("zh-chs");
    if simplified {
        Language::ZhHans
    } else {
        Language::En
    }
}

pub fn effective_language(selected: Option<Language>) -> Language {
    selected.unwrap_or_else(system_language)
}

pub fn system_language() -> Language {
    language_from_locale_name(&ui_locale_name().unwrap_or_default())
}

fn ui_locale_name() -> Option<String> {
    let mut buffer = [0u16; 85];
    let written =
        unsafe { LCIDToLocaleName(u32::from(GetUserDefaultUILanguage()), Some(&mut buffer), 0) };
    locale_text(&buffer, written).or_else(|| {
        let written = unsafe { GetUserDefaultLocaleName(&mut buffer) };
        locale_text(&buffer, written)
    })
}

fn locale_text(buffer: &[u16], written: i32) -> Option<String> {
    if written <= 1 {
        return None;
    }
    let end = (written as usize - 1).min(buffer.len());
    String::from_utf16(&buffer[..end])
        .ok()
        .filter(|name| !name.is_empty())
}

pub struct MenuCopy {
    pub product: &'static str,
    pub toggle_on: &'static str,
    pub toggle_off: &'static str,
    pub texture_menu: &'static str,
    pub intensity_menu: &'static str,
    pub snooze_menu: &'static str,
    pub snooze_5: &'static str,
    pub snooze_15: &'static str,
    pub resume: &'static str,
    pub exclude_empty: &'static str,
    pub language_menu: &'static str,
    pub schedule_title: &'static str,
    pub quit: &'static str,
}

pub fn menu_copy(language: Language) -> MenuCopy {
    match language {
        Language::ZhHans => MenuCopy {
            product: "柔纸",
            toggle_on: "✔ 启用纸张纹理",
            toggle_off: "　启用纸张纹理",
            texture_menu: "纹理",
            intensity_menu: "强度",
            snooze_menu: "打盹",
            snooze_5: "暂停 5 分钟",
            snooze_15: "暂停 15 分钟",
            resume: "立即恢复",
            exclude_empty: "排除当前应用",
            language_menu: "语言",
            schedule_title: "定时与日落",
            quit: "退出",
        },
        Language::En => MenuCopy {
            product: "MattePulp",
            toggle_on: "✔ Enable paper texture",
            toggle_off: "　Enable paper texture",
            texture_menu: "Texture",
            intensity_menu: "Intensity",
            snooze_menu: "Snooze",
            snooze_5: "Snooze 5 minutes",
            snooze_15: "Snooze 15 minutes",
            resume: "Resume now",
            exclude_empty: "Exclude current app",
            language_menu: "Language",
            schedule_title: "Schedule & Sunset",
            quit: "Quit",
        },
    }
}

fn texture_label(language: Language, index: usize) -> String {
    let (english, chinese) = split_catalog_name(KIND_NAMES[index]);
    match language {
        Language::ZhHans => chinese.to_string(),
        Language::En => english.to_string(),
    }
}

/// Mac 目录仍保存「English 中文」整句。Windows 菜单只取其中一边。
fn split_catalog_name(name: &str) -> (&str, &str) {
    let index = name
        .char_indices()
        .find(|(_, ch)| ('\u{4E00}'..='\u{9FFF}').contains(ch))
        .map(|(index, _)| index)
        .expect("catalog name includes a Chinese label");
    (name[..index].trim(), name[index..].trim())
}

pub fn exclude_label(language: Language, name: &str) -> String {
    match language {
        Language::ZhHans => format!("排除当前应用 ({name})"),
        Language::En => format!("Exclude current app ({name})"),
    }
}

pub fn include_label(language: Language, name: &str) -> String {
    match language {
        Language::ZhHans => format!("取消排除当前应用 ({name})"),
        Language::En => format!("Include current app ({name})"),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MenuNode {
    Separator,
    Command {
        id: u16,
        label: String,
        checked: bool,
        enabled: bool,
    },
    Submenu {
        label: String,
        items: Vec<MenuNode>,
    },
}

#[derive(Clone, Copy)]
pub struct MenuRequest<'a> {
    pub language: Language,
    pub enabled: bool,
    pub texture_index: usize,
    pub intensity_index: usize,
    pub foreground: Option<&'a str>,
    pub snoozed: bool,
    pub foreground_excluded: bool,
}

pub fn menu_model(request: &MenuRequest<'_>) -> Vec<MenuNode> {
    let MenuRequest {
        language,
        enabled,
        texture_index,
        intensity_index,
        foreground,
        snoozed,
        foreground_excluded,
    } = *request;
    let copy = menu_copy(language);
    debug_assert_eq!(KIND_NAMES.len(), 4);
    debug_assert_eq!(INTENSITIES, [15, 20, 25, 30]);

    let textures = KIND_NAMES
        .iter()
        .enumerate()
        .map(|(index, _)| MenuNode::Command {
            id: ID_TEX_BASE + index as u16,
            label: texture_label(language, index),
            checked: index == texture_index,
            enabled: true,
        })
        .collect();
    let intensities = INTENSITIES
        .iter()
        .enumerate()
        .map(|(index, value)| MenuNode::Command {
            id: ID_INT_BASE + index as u16,
            label: format!("{value}%"),
            checked: index == intensity_index,
            enabled: true,
        })
        .collect();
    let exclude = match foreground {
        Some(name) => MenuNode::Command {
            id: ID_EXCLUDE,
            label: if foreground_excluded {
                include_label(language, name)
            } else {
                exclude_label(language, name)
            },
            checked: foreground_excluded,
            enabled: true,
        },
        None => MenuNode::Command {
            id: ID_EXCLUDE,
            label: copy.exclude_empty.to_string(),
            checked: false,
            enabled: false,
        },
    };
    let mut snooze_items = vec![
        MenuNode::Command {
            id: ID_SNOOZE_5,
            label: copy.snooze_5.to_string(),
            checked: false,
            enabled: true,
        },
        MenuNode::Command {
            id: ID_SNOOZE_15,
            label: copy.snooze_15.to_string(),
            checked: false,
            enabled: true,
        },
    ];
    if snoozed {
        snooze_items.push(MenuNode::Command {
            id: ID_RESUME,
            label: copy.resume.to_string(),
            checked: false,
            enabled: true,
        });
    }

    vec![
        MenuNode::Command {
            id: ID_TOGGLE,
            label: if enabled {
                copy.toggle_on.to_string()
            } else {
                copy.toggle_off.to_string()
            },
            checked: enabled,
            enabled: true,
        },
        MenuNode::Separator,
        MenuNode::Submenu {
            label: copy.texture_menu.to_string(),
            items: textures,
        },
        MenuNode::Submenu {
            label: copy.intensity_menu.to_string(),
            items: intensities,
        },
        MenuNode::Submenu {
            label: copy.snooze_menu.to_string(),
            items: snooze_items,
        },
        MenuNode::Submenu {
            label: copy.language_menu.to_string(),
            items: vec![
                MenuNode::Command {
                    id: ID_LANG_ZH,
                    label: "中文".to_string(),
                    checked: language == Language::ZhHans,
                    enabled: true,
                },
                MenuNode::Command {
                    id: ID_LANG_EN,
                    label: "English".to_string(),
                    checked: language == Language::En,
                    enabled: true,
                },
            ],
        },
        MenuNode::Separator,
        MenuNode::Command {
            id: ID_SCHEDULE,
            label: format!("{}…", copy.schedule_title.replace('&', "&&")),
            checked: false,
            enabled: true,
        },
        exclude,
        MenuNode::Separator,
        MenuNode::Command {
            id: ID_EXIT,
            label: copy.quit.to_string(),
            checked: false,
            enabled: true,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simplified_chinese_locales_select_chinese_and_other_locales_select_english() {
        for name in [
            "zh-CN",
            "zh-cn",
            "zh_CN",
            "zh-Hans",
            "zh-Hans-CN",
            "ZH-SG",
            "zh-CHS",
            "zh-CN.UTF-8",
        ] {
            assert_eq!(language_from_locale_name(name), Language::ZhHans, "{name}");
        }
        for name in [
            "",
            "zh",
            "zh-TW",
            "zh-HK",
            "zh-MO",
            "zh-Hant",
            "zh-Hant-TW",
            "en-US",
            "ja-JP",
        ] {
            assert_eq!(language_from_locale_name(name), Language::En, "{name}");
        }
    }

    #[test]
    fn explicit_choice_beats_the_system_default() {
        assert_eq!(effective_language(Some(Language::En)), Language::En);
        assert_eq!(effective_language(Some(Language::ZhHans)), Language::ZhHans);
    }

    #[test]
    fn persisted_tags_round_trip_and_reject_unknown_values() {
        assert_eq!(Language::from_tag(Language::En.tag()), Some(Language::En));
        assert_eq!(
            Language::from_tag(Language::ZhHans.tag()),
            Some(Language::ZhHans)
        );
        assert_eq!(Language::from_tag("zh-CN"), None);
        assert_eq!(Language::from_tag("zh-Hant"), None);
    }

    #[test]
    fn system_language_uses_the_windows_ui_locale_name() {
        let name = ui_locale_name().expect("Windows UI locale name");
        assert_eq!(system_language(), language_from_locale_name(&name));
    }

    #[test]
    fn menu_uses_one_language_and_keeps_intensity_steps() {
        let chinese = opened(Language::ZhHans, true, 1, 2, None, false, false);
        let english = opened(Language::En, false, 1, 2, None, false, false);
        let chinese_commands = command_labels(&chinese);
        let english_commands = command_labels(&english);

        assert!(
            chinese_commands.chars().all(|ch| !ch.is_ascii_alphabetic()),
            "{chinese_commands}"
        );
        assert!(
            english_commands.chars().all(|ch| !is_cjk(ch)),
            "{english_commands}"
        );
        assert_eq!(intensity_labels(&chinese), ["15%", "20%", "25%", "30%"]);
        assert_eq!(intensity_labels(&english), ["15%", "20%", "25%", "30%"]);
        assert_eq!(
            language_entries(&chinese),
            vec![
                (ID_LANG_ZH, "中文".to_string(), true),
                (ID_LANG_EN, "English".to_string(), false),
            ]
        );
        assert_eq!(
            language_entries(&english),
            vec![
                (ID_LANG_ZH, "中文".to_string(), false),
                (ID_LANG_EN, "English".to_string(), true),
            ]
        );
    }

    #[test]
    fn rebuilding_the_menu_replaces_every_translated_label() {
        let foreground = Some("notes.exe");
        let chinese = opened(Language::ZhHans, true, 0, 0, foreground, false, false);
        let english = opened(Language::En, true, 0, 0, foreground, false, false);
        let chinese_labels = command_labels(&chinese);
        let english_labels = command_labels(&english);
        assert_ne!(chinese_labels, english_labels);
        assert!(chinese_labels.contains("启用纸张纹理"));
        assert!(chinese_labels.contains("排除当前应用 (notes.exe)"));
        assert!(english_labels.contains("Enable paper texture"));
        assert!(english_labels.contains("Exclude current app (notes.exe)"));
        assert_eq!(menu_copy(Language::ZhHans).product, "柔纸");
        assert_eq!(menu_copy(Language::En).product, "MattePulp");
    }

    #[test]
    fn checked_marks_follow_current_texture_intensity_and_power_state() {
        let menu = opened(Language::En, true, 2, 3, None, false, false);
        assert!(command_checked(&menu, ID_TOGGLE));
        assert!(command_checked(&menu, ID_TEX_BASE + 2));
        assert!(!command_checked(&menu, ID_TEX_BASE));
        assert!(command_checked(&menu, ID_INT_BASE + 3));
        assert!(!command_checked(&menu, ID_INT_BASE));
        assert!(!command_enabled(&menu, ID_EXCLUDE));
        assert!(command_label(&menu, ID_RESUME).is_none());
    }

    #[test]
    fn snoozed_menu_offers_resume_and_an_excluded_app_can_be_included() {
        let awake = opened(Language::En, true, 0, 1, Some("photos.exe"), false, false);
        assert!(command_label(&awake, ID_RESUME).is_none());
        assert_eq!(
            command_label(&awake, ID_EXCLUDE).as_deref(),
            Some("Exclude current app (photos.exe)")
        );
        assert!(!command_checked(&awake, ID_EXCLUDE));
        assert_eq!(intensity_labels(&awake), ["15%", "20%", "25%", "30%"]);

        let snoozed = opened(Language::En, true, 0, 1, Some("photos.exe"), true, true);
        assert_eq!(
            command_label(&snoozed, ID_RESUME).as_deref(),
            Some("Resume now")
        );
        assert!(command_enabled(&snoozed, ID_RESUME));
        assert_eq!(
            command_label(&snoozed, ID_EXCLUDE).as_deref(),
            Some("Include current app (photos.exe)")
        );
        assert!(command_checked(&snoozed, ID_EXCLUDE));

        let chinese = opened(Language::ZhHans, true, 0, 1, Some("photos.exe"), true, true);
        assert_eq!(
            command_label(&chinese, ID_RESUME).as_deref(),
            Some("立即恢复")
        );
        assert_eq!(
            command_label(&chinese, ID_EXCLUDE).as_deref(),
            Some("取消排除当前应用 (photos.exe)")
        );
        assert!(
            command_labels(&chinese)
                .replace("photos.exe", "")
                .chars()
                .all(|ch| !ch.is_ascii_alphabetic()),
            "{}",
            command_labels(&chinese)
        );
        assert!(
            command_labels(&snoozed).chars().all(|ch| !is_cjk(ch)),
            "{}",
            command_labels(&snoozed)
        );
    }

    fn opened(
        language: Language,
        enabled: bool,
        texture_index: usize,
        intensity_index: usize,
        foreground: Option<&str>,
        snoozed: bool,
        foreground_excluded: bool,
    ) -> Vec<MenuNode> {
        menu_model(&MenuRequest {
            language,
            enabled,
            texture_index,
            intensity_index,
            foreground,
            snoozed,
            foreground_excluded,
        })
    }

    fn is_cjk(ch: char) -> bool {
        ('\u{4E00}'..='\u{9FFF}').contains(&ch)
    }

    fn command_labels(nodes: &[MenuNode]) -> String {
        let mut labels = Vec::new();
        collect_commands(nodes, &mut labels);
        labels
            .into_iter()
            .filter(|(id, _)| !matches!(*id, ID_LANG_ZH | ID_LANG_EN))
            .map(|(_, label)| label)
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn intensity_labels(nodes: &[MenuNode]) -> Vec<String> {
        let mut labels = Vec::new();
        collect_commands(nodes, &mut labels);
        labels
            .into_iter()
            .filter(|(id, _)| (ID_INT_BASE..ID_INT_BASE + INTENSITIES.len() as u16).contains(id))
            .map(|(_, label)| label)
            .collect()
    }

    fn language_entries(nodes: &[MenuNode]) -> Vec<(u16, String, bool)> {
        let mut labels = Vec::new();
        collect_commands(nodes, &mut labels);
        labels
            .into_iter()
            .filter(|(id, _)| matches!(*id, ID_LANG_ZH | ID_LANG_EN))
            .map(|(id, label)| {
                let checked = command_checked(nodes, id);
                (id, label, checked)
            })
            .collect()
    }

    fn command_label(nodes: &[MenuNode], wanted: u16) -> Option<String> {
        for node in nodes {
            match node {
                MenuNode::Command { id, label, .. } if *id == wanted => return Some(label.clone()),
                MenuNode::Submenu { items, .. } => {
                    if let Some(label) = command_label(items, wanted) {
                        return Some(label);
                    }
                }
                _ => {}
            }
        }
        None
    }

    fn command_checked(nodes: &[MenuNode], wanted: u16) -> bool {
        command_flag(nodes, wanted).0
    }

    fn command_enabled(nodes: &[MenuNode], wanted: u16) -> bool {
        command_flag(nodes, wanted).1
    }

    fn command_flag(nodes: &[MenuNode], wanted: u16) -> (bool, bool) {
        for node in nodes {
            match node {
                MenuNode::Command {
                    id,
                    checked,
                    enabled,
                    ..
                } if *id == wanted => return (*checked, *enabled),
                MenuNode::Submenu { items, .. } if contains_id(items, wanted) => {
                    return command_flag(items, wanted);
                }
                _ => {}
            }
        }
        (false, false)
    }

    fn contains_id(nodes: &[MenuNode], wanted: u16) -> bool {
        nodes.iter().any(|node| match node {
            MenuNode::Command { id, .. } => *id == wanted,
            MenuNode::Submenu { items, .. } => contains_id(items, wanted),
            MenuNode::Separator => false,
        })
    }

    fn collect_commands(nodes: &[MenuNode], out: &mut Vec<(u16, String)>) {
        for node in nodes {
            match node {
                MenuNode::Separator => {}
                MenuNode::Command { id, label, .. } => out.push((*id, label.clone())),
                MenuNode::Submenu { label, items } => {
                    out.push((0, label.clone()));
                    collect_commands(items, out);
                }
            }
        }
    }
}
