//! 前台应用检测：用于"应用排除列表"——指定应用在前台时自动隐藏纹理。

use windows::core::PWSTR;
use windows::Win32::Foundation::{CloseHandle, HWND};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

/// 返回当前前台窗口所属进程的可执行文件名（小写），如 "notepad.exe"
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Foreground {
    pub path: String,
    pub name: String,
}

pub fn foreground_is_own() -> bool {
    unsafe {
        let hwnd = GetForegroundWindow();
        let mut pid = 0;
        if !hwnd.0.is_null() {
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
        }
        pid != 0 && pid == std::process::id()
    }
}

pub fn foreground_process() -> Option<Foreground> {
    unsafe {
        let hwnd: HWND = GetForegroundWindow();
        if hwnd.0.is_null() {
            return None;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == 0 {
            return None;
        }
        if pid == std::process::id() {
            return None;
        }
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        // Win32 extended-length paths can be much longer than MAX_PATH.
        let mut buf = [0u16; 32_768];
        let mut len = buf.len() as u32;
        let result = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(buf.as_mut_ptr()),
            &mut len,
        );
        let _ = CloseHandle(process);
        result.ok()?;
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        let path = path.to_lowercase();
        let name = path.rsplit('\\').next()?.to_string();
        if name.is_empty() {
            return None;
        }
        Some(Foreground { path, name })
    }
}
