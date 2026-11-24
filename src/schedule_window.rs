use std::cell::RefCell;

use sue_paper::schedule::{Evaluation, ACTIVE, INACTIVE, UNAVAILABLE};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::locale::Language;
use crate::schedule_clock::{Clock, ScheduleSettings};

const TIMED: u16 = 101;
const START: u16 = 102;
const END: u16 = 103;
const SUNSET: u16 = 104;
const LATITUDE: u16 = 105;
const LONGITUDE: u16 = 106;
const STATUS: u16 = 107;
const NEXT: u16 = 108;
const MESSAGE: u16 = 109;

struct Panel {
    hwnd: HWND,
    language: Language,
    preview: Option<(Clock, ScheduleSettings)>,
}

thread_local! {
    static PANEL: RefCell<Option<Panel>> = const { RefCell::new(None) };
}

fn localized<'a>(language: Language, zh: &'a str, en: &'a str) -> &'a str {
    match language {
        Language::ZhHans => zh,
        Language::En => en,
    }
}

pub unsafe fn open(
    owner: HWND,
    language: Language,
    settings: &ScheduleSettings,
) -> windows::core::Result<()> {
    if let Some(hwnd) = handle() {
        let _ = SetForegroundWindow(hwnd);
        return Ok(());
    }
    let hwnd = create(owner, language, settings)?;
    PANEL.with(|panel| {
        *panel.borrow_mut() = Some(Panel {
            hwnd,
            language,
            preview: None,
        })
    });
    let _ = ShowWindow(hwnd, SW_SHOW);
    let _ = SetForegroundWindow(hwnd);
    Ok(())
}

pub fn handle() -> Option<HWND> {
    PANEL.with(|panel| panel.borrow().as_ref().map(|panel| panel.hwnd))
}

unsafe fn create(
    owner: HWND,
    language: Language,
    settings: &ScheduleSettings,
) -> windows::core::Result<HWND> {
    let template = template(language);
    let hinstance = HINSTANCE(GetModuleHandleW(PCWSTR::null())?.0);
    let hwnd = CreateDialogIndirectParamW(
        hinstance,
        template.as_ptr().cast(),
        owner,
        Some(procedure),
        LPARAM(0),
    )?;
    for (id, checked) in [(TIMED, settings.timed), (SUNSET, settings.sunset)] {
        if let Ok(button) = GetDlgItem(hwnd, i32::from(id)) {
            SendMessageW(button, BM_SETCHECK, WPARAM(usize::from(checked)), LPARAM(0));
        }
    }
    for (id, value) in [
        (START, &settings.start),
        (END, &settings.end),
        (LATITUDE, &settings.latitude),
        (LONGITUDE, &settings.longitude),
    ] {
        set_text(hwnd, id, value);
    }
    Ok(hwnd)
}

struct DialogTemplate(Vec<u16>);

impl DialogTemplate {
    fn dword(&mut self, value: u32) {
        self.0.extend([value as u16, (value >> 16) as u16]);
    }

    fn text(&mut self, value: &str) {
        self.0.extend(value.encode_utf16().chain(Some(0)));
    }

    fn item(&mut self, id: u16, class: u16, style: u32, bounds: [u16; 4], label: &str) {
        if !self.0.len().is_multiple_of(2) {
            self.0.push(0);
        }
        self.0[4] += 1;
        self.dword((WS_CHILD | WS_VISIBLE).0 | style);
        self.dword(0);
        self.0.extend(bounds);
        self.0.extend([id, 0xffff, class]);
        self.text(label);
        self.0.push(0);
    }
}

fn template(language: Language) -> Vec<u32> {
    let t = |zh, en| localized(language, zh, en);
    let mut dlg = DialogTemplate(Vec::new());
    dlg.dword((WS_POPUP | WS_CAPTION | WS_SYSMENU).0 | (DS_CENTER | DS_SETFONT) as u32);
    dlg.dword(0);
    dlg.0.extend([0, 0, 0, 288, 218, 0, 0]);
    dlg.text(super::locale::menu_copy(language).schedule_title);
    dlg.0.push(9);
    dlg.text("Segoe UI");
    const BUTTON: u16 = 0x80;
    const EDIT: u16 = 0x81;
    const STATIC: u16 = 0x82;
    let checkbox = WS_TABSTOP.0 | BS_AUTOCHECKBOX as u32;
    dlg.item(
        TIMED,
        BUTTON,
        checkbox,
        [12, 12, 256, 14],
        t("启用定时", "Enable daily schedule"),
    );
    for (id, y, label) in [
        (START, 30, t("开始时间（24 小时）", "&Start time (24-hour)")),
        (END, 48, t("结束时间（24 小时）", "&End time (24-hour)")),
        (LATITUDE, 86, t("纬度", "&Latitude")),
        (LONGITUDE, 104, t("经度", "L&ongitude")),
    ] {
        if id == LATITUDE {
            dlg.item(
                SUNSET,
                BUTTON,
                checkbox,
                [12, 69, 256, 14],
                t("启用日落", "Enable sunset to sunrise"),
            );
        }
        dlg.item(u16::MAX, STATIC, 0, [14, y + 2, 105, 12], label);
        let edit = WS_BORDER.0 | WS_TABSTOP.0 | ES_AUTOHSCROLL as u32;
        dlg.item(id, EDIT, edit, [122, y, 100, 14], "");
    }
    dlg.item(
        u16::MAX,
        STATIC,
        0,
        [12, 124, 264, 20],
        t(
            "任一规则符合时自动覆盖。坐标仅保存在本机。",
            "Either rule can allow coverage. Coordinates stay on this device.",
        ),
    );
    dlg.item(STATUS, STATIC, 0, [12, 145, 264, 20], "");
    dlg.item(NEXT, STATIC, 0, [12, 166, 264, 12], "");
    dlg.item(MESSAGE, STATIC, 0, [12, 180, 264, 12], "");
    dlg.item(
        IDCANCEL.0 as u16,
        BUTTON,
        WS_TABSTOP.0,
        [160, 192, 54, 14],
        t("关闭", "Close"),
    );
    dlg.item(
        IDOK.0 as u16,
        BUTTON,
        WS_TABSTOP.0 | BS_DEFPUSHBUTTON as u32,
        [222, 192, 54, 14],
        t("保存", "Save"),
    );
    dlg.0
        .chunks(2)
        .map(|words| u32::from(words[0]) | (u32::from(*words.get(1).unwrap_or(&0)) << 16))
        .collect()
}

unsafe fn set_text(hwnd: HWND, id: u16, text: &str) {
    let wide: Vec<_> = text.encode_utf16().chain(Some(0)).collect();
    let _ = SetDlgItemTextW(hwnd, i32::from(id), PCWSTR(wide.as_ptr()));
}

unsafe fn get_text(hwnd: HWND, id: u16) -> String {
    let Ok(field) = GetDlgItem(hwnd, i32::from(id)) else {
        return String::new();
    };
    let mut buffer = vec![0; GetWindowTextLengthW(field).max(0) as usize + 1];
    let length = GetDlgItemTextW(hwnd, i32::from(id), &mut buffer) as usize;
    String::from_utf16_lossy(&buffer[..length])
}

unsafe fn apply(hwnd: HWND, language: Language, save: impl FnOnce(ScheduleSettings) -> bool) {
    let checked = |id| {
        GetDlgItem(hwnd, id)
            .is_ok_and(|button| SendMessageW(button, BM_GETCHECK, WPARAM(0), LPARAM(0)).0 == 1)
    };
    let draft = ScheduleSettings {
        timed: checked(i32::from(TIMED)),
        sunset: checked(i32::from(SUNSET)),
        start: get_text(hwnd, START),
        end: get_text(hwnd, END),
        latitude: get_text(hwnd, LATITUDE),
        longitude: get_text(hwnd, LONGITUDE),
    };
    let t = |zh, en| localized(language, zh, en);
    let invalid_time = draft.timed && !draft.valid_time();
    let invalid_location = draft.sunset && !draft.blank_location() && !draft.valid_location();
    let message = if !save(draft) {
        t("保存失败。请重试。", "Could not save. Try again.")
    } else if invalid_time {
        t(
            "请输入不同的开始和结束时间，格式为 HH:mm。",
            "Enter two different times in HH:mm format.",
        )
    } else if invalid_location {
        t(
            "纬度须为 −90 至 90，经度须为 −180 至 180，或清空两项。",
            "Latitude −90 to 90, longitude −180 to 180, or clear both.",
        )
    } else {
        ""
    };
    set_text(hwnd, MESSAGE, message);
}

unsafe extern "system" fn procedure(hwnd: HWND, message: u32, wp: WPARAM, _: LPARAM) -> isize {
    match message {
        WM_INITDIALOG => return 1,
        WM_COMMAND if (wp.0 >> 16) as u32 == BN_CLICKED => match (wp.0 & 0xffff) as i32 {
            id if id == IDOK.0 => {
                let language =
                    PANEL.with(|panel| panel.borrow().as_ref().map(|panel| panel.language));
                if let Some(language) = language {
                    apply(hwnd, language, super::save_schedule);
                }
            }
            id if id == IDCANCEL.0 => {
                let _ = DestroyWindow(hwnd);
            }
            _ => return 0,
        },
        WM_CLOSE => {
            let _ = DestroyWindow(hwnd);
        }
        WM_NCDESTROY => {
            PANEL.with(|panel| {
                let mut panel = panel.borrow_mut();
                if panel.as_ref().is_some_and(|panel| panel.hwnd == hwnd) {
                    *panel = None;
                }
            });
            return 0;
        }
        _ => return 0,
    }
    1
}

pub unsafe fn refresh(
    result: Evaluation,
    settings: &ScheduleSettings,
    clock: &Clock,
    manual: bool,
    snoozed: bool,
    excluded: bool,
) {
    PANEL.with(|panel| {
        let mut panel = panel.borrow_mut();
        let Some(panel) = panel.as_mut() else { return };
        let t = |zh, en| localized(panel.language, zh, en);
        let current = if !manual {
            t("手动关闭", "Manually disabled")
        } else if snoozed {
            t("打盹中", "Snoozed")
        } else if excluded {
            t("前台应用已排除", "Frontmost app is excluded")
        } else if result.visible != 0 {
            t("覆盖已开启", "Coverage on")
        } else {
            t("覆盖已关闭", "Coverage off")
        };
        let rule_status = |code| match code {
            UNAVAILABLE => t("不可用", "unavailable"),
            INACTIVE => t("时段外", "outside hours"),
            ACTIVE => t("时段内", "within hours"),
            _ => t("已禁用", "disabled"),
        };
        let solar = if result.sunset != UNAVAILABLE {
            format!("{}{}", t("日落 ", "Sunset "), rule_status(result.sunset))
        } else if settings.blank_location() {
            t(
                "日落暂不可用，请输入坐标",
                "Sunset unavailable (enter coordinates)",
            )
            .to_string()
        } else if !settings.valid_location() {
            t(
                "日落暂不可用，坐标无效",
                "Sunset unavailable (invalid coordinates)",
            )
            .to_string()
        } else {
            t(
                "日落暂不可用，缺少太阳事件",
                "Sunset unavailable (missing solar events)",
            )
            .to_string()
        };
        let status = format!(
            "{current} · {}{} · {solar}",
            t("定时 ", "Schedule "),
            rule_status(result.timed)
        );
        set_text(panel.hwnd, STATUS, &status);
        if panel
            .preview
            .as_ref()
            .is_none_or(|(previous_clock, previous_settings)| {
                previous_clock != clock || previous_settings != settings
            })
        {
            panel.preview = Some((clock.clone(), settings.clone()));
            let preview = settings.evaluate(clock, manual, false, true);
            let next = if preview.has_next != 0 {
                clock.format_local(preview.next_minute)
            } else {
                None
            };
            let label = match next {
                Some(next) => format!(
                    "{}{next}",
                    t("下次自动变化（预计） ", "Next automatic change (est.) ")
                ),
                None => t(
                    "未来 48 小时没有预计的自动变化",
                    "No automatic change expected within 48 hours",
                )
                .to_string(),
            };
            set_text(panel.hwnd, NEXT, &label);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn native_dialog_edits_independent_rules_and_retries_same_draft() {
        unsafe {
            let hwnd = create(HWND::default(), Language::En, &ScheduleSettings::default()).unwrap();
            assert_eq!(get_text(hwnd, START), "21:00");
            assert_eq!(get_text(hwnd, END), "06:00");
            let button = GetDlgItem(hwnd, i32::from(TIMED)).unwrap();
            SendMessageW(button, BM_SETCHECK, WPARAM(1), LPARAM(0));
            set_text(hwnd, LATITUDE, "invalid");
            let attempts = Cell::new(0);
            let save = |draft: ScheduleSettings| {
                assert!(draft.timed && !draft.sunset);
                assert!(draft.valid_time());
                assert_eq!(draft.latitude, "invalid");
                attempts.set(attempts.get() + 1);
                attempts.get() > 1
            };
            apply(hwnd, Language::En, save);
            assert_eq!(get_text(hwnd, MESSAGE), "Could not save. Try again.");
            apply(hwnd, Language::En, save);
            assert!(get_text(hwnd, MESSAGE).is_empty());
            let sunset = GetDlgItem(hwnd, i32::from(SUNSET)).unwrap();
            SendMessageW(sunset, BM_SETCHECK, WPARAM(1), LPARAM(0));
            apply(hwnd, Language::En, |draft| {
                assert!(draft.timed && draft.sunset);
                assert!(!draft.valid_location());
                true
            });
            assert!(get_text(hwnd, MESSAGE).contains("clear both"));
            SendMessageW(hwnd, WM_CLOSE, WPARAM(0), LPARAM(0));
            assert!(!IsWindow(hwnd).as_bool());
        }
    }
}
