//! 系统托盘图标 + 右键菜单

use std::ffi::c_void;
use std::mem::size_of;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::locale::{menu_model, MenuNode, MenuRequest};

pub const WM_TRAY: u32 = WM_APP + 1;
const TRAY_UID: u32 = 1;
const CONTROL_CLASS: PCWSTR = w!("SuePaperControl");
const ICON_SIZE: i32 = 64;
const ICON_BGRA: &[u8; ICON_SIZE as usize * ICON_SIZE as usize * 4] =
    include_bytes!("../assets/app-icon-64.bgra");

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 创建隐藏的 control 窗口（接收托盘消息、定时器、WM_DISPLAYCHANGE）
pub unsafe fn create_app_icon() -> windows::core::Result<HICON> {
    let hdc = GetDC(HWND::default());
    if hdc.0.is_null() {
        return Err(windows::core::Error::from_win32());
    }

    let mut bmi = BITMAPINFO::default();
    bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
    bmi.bmiHeader.biWidth = ICON_SIZE;
    bmi.bmiHeader.biHeight = -ICON_SIZE;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB.0;

    let mut bits: *mut c_void = std::ptr::null_mut();
    let color = CreateDIBSection(hdc, &bmi, DIB_RGB_COLORS, &mut bits, HANDLE::default(), 0);
    ReleaseDC(HWND::default(), hdc);
    let color = color?;
    if bits.is_null() {
        let _ = DeleteObject(color);
        return Err(windows::core::Error::from_win32());
    }
    std::ptr::copy_nonoverlapping(ICON_BGRA.as_ptr(), bits.cast(), ICON_BGRA.len());

    let mask_bits = [0u8; ICON_SIZE as usize * ICON_SIZE as usize / 8];
    let mask = CreateBitmap(ICON_SIZE, ICON_SIZE, 1, 1, Some(mask_bits.as_ptr().cast()));
    if mask.0.is_null() {
        let _ = DeleteObject(color);
        return Err(windows::core::Error::from_win32());
    }
    let info = ICONINFO {
        fIcon: TRUE,
        hbmMask: mask,
        hbmColor: color,
        ..Default::default()
    };
    let icon = CreateIconIndirect(&info);
    let _ = DeleteObject(mask);
    let _ = DeleteObject(color);
    icon
}

pub unsafe fn create_control_window(
    wndproc: WNDPROC,
    icon: HICON,
    hinst: HINSTANCE,
    title: &str,
) -> windows::core::Result<HWND> {
    let wc = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        lpfnWndProc: wndproc,
        hInstance: hinst,
        hIcon: icon,
        hIconSm: icon,
        lpszClassName: CONTROL_CLASS,
        ..Default::default()
    };
    if RegisterClassExW(&wc) == 0 {
        return Err(windows::core::Error::from_win32());
    }
    let title = wide(title);
    CreateWindowExW(
        WINDOW_EX_STYLE::default(),
        CONTROL_CLASS,
        PCWSTR(title.as_ptr()),
        WS_OVERLAPPED,
        0,
        0,
        0,
        0,
        None,
        None,
        hinst,
        None,
    )
}

fn copy_tip(tip: &mut [u16; 128], tip_text: &str) {
    let tip_text = wide(tip_text);
    let n = tip_text.len().min(127);
    tip[..n].copy_from_slice(&tip_text[..n]);
}

pub unsafe fn set_window_title(hwnd: HWND, title: &str) {
    let title = wide(title);
    let _ = SetWindowTextW(hwnd, PCWSTR(title.as_ptr()));
}

pub unsafe fn set_tray_tip(hwnd: HWND, tip_text: &str) {
    let mut tip = [0u16; 128];
    copy_tip(&mut tip, tip_text);
    let nid = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: TRAY_UID,
        uFlags: NIF_TIP,
        szTip: tip,
        ..Default::default()
    };
    let _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
}

pub unsafe fn add_icon(hwnd: HWND, hicon: HICON, tip_text: &str) -> windows::core::Result<()> {
    let mut tip = [0u16; 128];
    copy_tip(&mut tip, tip_text);
    let nid = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: TRAY_UID,
        uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
        uCallbackMessage: WM_TRAY,
        hIcon: hicon,
        szTip: tip,
        ..Default::default()
    };
    Shell_NotifyIconW(NIM_ADD, &nid).ok()?;
    let version = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: TRAY_UID,
        Anonymous: NOTIFYICONDATAW_0 {
            uVersion: NOTIFYICON_VERSION_4,
        },
        ..Default::default()
    };
    let _ = Shell_NotifyIconW(NIM_SETVERSION, &version);
    Ok(())
}

pub unsafe fn remove_icon(hwnd: HWND) {
    let nid = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: TRAY_UID,
        ..Default::default()
    };
    let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
}

unsafe fn fill_menu(menu: HMENU, nodes: &[MenuNode]) {
    for node in nodes {
        match node {
            MenuNode::Separator => {
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
            }
            MenuNode::Command {
                id,
                label,
                checked,
                enabled,
            } => append(menu, *id, label, *checked, !*enabled),
            MenuNode::Submenu { label, items } => {
                let Ok(sub) = CreatePopupMenu() else {
                    continue;
                };
                fill_menu(sub, items);
                let label = wide(label);
                let _ = AppendMenuW(menu, MF_POPUP, sub.0 as usize, PCWSTR(label.as_ptr()));
            }
        }
    }
}

fn append(menu: HMENU, id: u16, text: &str, checked: bool, grayed: bool) {
    let text = wide(text);
    let mut flags = MF_STRING;
    if checked {
        flags |= MF_CHECKED;
    }
    if grayed {
        flags |= MF_GRAYED;
    }
    unsafe {
        let _ = AppendMenuW(menu, flags, id as usize, PCWSTR(text.as_ptr()));
    }
}

/// 弹出托盘菜单，返回用户选择的命令 ID（0 = 未选择）。
/// `request.foreground` 必须在弹菜单之前捕获（弹菜单会把前台切到本进程）。
/// 每次弹出都按当前语言整表重建，避免中英标签混在同一菜单里。
pub unsafe fn show_menu(owner: HWND, request: &MenuRequest<'_>) -> u32 {
    let menu = match CreatePopupMenu() {
        Ok(m) => m,
        Err(_) => return 0,
    };
    fill_menu(menu, &menu_model(request));

    let mut pt = POINT::default();
    let _ = GetCursorPos(&mut pt);
    // 必须先置前台，菜单才能在点击外部时正常关闭
    let _ = SetForegroundWindow(owner);
    let cmd = TrackPopupMenu(
        menu,
        TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
        pt.x,
        pt.y,
        0,
        owner,
        None,
    );
    let _ = PostMessageW(owner, WM_NULL, WPARAM(0), LPARAM(0));
    let _ = DestroyMenu(menu);
    cmd.0 as u32
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::locale::Language;
    use crate::ID_TONE_BASE;
    use sue_paper::tone::Tone;

    #[test]
    fn embedded_logo_creates_a_native_icon() {
        let icon = unsafe { create_app_icon() }.unwrap();
        assert!(!icon.0.is_null());
        unsafe {
            let _ = DestroyIcon(icon);
        }
    }

    #[test]
    fn native_tone_submenu_has_three_localized_choices_and_one_checkmark() {
        for (language, title, labels) in [
            (Language::ZhHans, "色调", ["原色", "浅暖", "暖纸"]),
            (
                Language::En,
                "Tone",
                ["Original", "Light Warm", "Warm Paper"],
            ),
        ] {
            for tone in Tone::ALL {
                let nodes = menu_model(&MenuRequest {
                    language,
                    enabled: true,
                    texture_index: 0,
                    intensity_index: 1,
                    tone,
                    foreground: None,
                    snoozed: false,
                    foreground_excluded: false,
                });
                let position = nodes
                    .iter()
                    .position(
                        |node| matches!(node, MenuNode::Submenu { label, .. } if label == title),
                    )
                    .unwrap() as i32;
                unsafe {
                    let menu = CreatePopupMenu().unwrap();
                    fill_menu(menu, &nodes);
                    let mut text = [0; 64];
                    let length =
                        GetMenuStringW(menu, position as u32, Some(&mut text), MF_BYPOSITION);
                    assert_eq!(String::from_utf16_lossy(&text[..length as usize]), title);
                    let submenu = GetSubMenu(menu, position);
                    assert!(!submenu.0.is_null());
                    assert_eq!(GetMenuItemCount(submenu), 3);
                    for (index, label) in labels.into_iter().enumerate() {
                        let id = u32::from(ID_TONE_BASE) + index as u32;
                        assert_eq!(GetMenuItemID(submenu, index as i32), id);
                        let length = GetMenuStringW(submenu, id, Some(&mut text), MF_BYCOMMAND);
                        assert_eq!(String::from_utf16_lossy(&text[..length as usize]), label);
                        let state = GetMenuState(submenu, id, MF_BYCOMMAND);
                        assert_eq!(state & MF_CHECKED.0 != 0, index as u8 == tone as u8);
                    }
                    DestroyMenu(menu).unwrap();
                }
            }
        }
    }
}
