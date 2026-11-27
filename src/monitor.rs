//! Display enumeration. Device interface paths are identities, never GDI handles or labels.
//! EnumDisplayDevices documents the per-monitor interface name, whose registration persists
//! across system starts. A changed device path is treated as a different, unselected display.
//! https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumdisplaydevicesw
//! https://learn.microsoft.com/en-us/windows-hardware/drivers/install/device-interface-classes

use std::collections::HashMap;
use std::mem::size_of;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{BOOL, LPARAM, RECT, TRUE};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::EDD_GET_DEVICE_INTERFACE_NAME;

#[derive(Clone, Debug)]
pub struct Display {
    pub rect: RECT,
    pub id: Option<String>,
    pub label: String,
}

fn wide_text(value: &[u16]) -> String {
    String::from_utf16_lossy(&value[..value.iter().position(|c| *c == 0).unwrap_or(value.len())])
}

pub fn displays() -> windows::core::Result<Vec<Display>> {
    unsafe extern "system" fn callback(
        hmon: HMONITOR,
        _: HDC,
        rect: *mut RECT,
        data: LPARAM,
    ) -> BOOL {
        let displays = &mut *(data.0 as *mut Vec<Display>);
        let mut info = MONITORINFOEXW::default();
        info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
        let mut candidates = Vec::new();
        if GetMonitorInfoW(hmon, &mut info.monitorInfo).as_bool() {
            let mut index = 0;
            loop {
                let mut device = DISPLAY_DEVICEW {
                    cb: size_of::<DISPLAY_DEVICEW>() as u32,
                    ..Default::default()
                };
                if !EnumDisplayDevicesW(
                    PCWSTR(info.szDevice.as_ptr()),
                    index,
                    &mut device,
                    EDD_GET_DEVICE_INTERFACE_NAME,
                )
                .as_bool()
                {
                    break;
                }
                if device.StateFlags & DISPLAY_DEVICE_ACTIVE != 0 {
                    let id = wide_text(&device.DeviceID).to_lowercase();
                    if !id.is_empty() {
                        candidates.push((id, wide_text(&device.DeviceString)));
                    }
                }
                index += 1;
            }
        }
        let (id, label) = if candidates.len() == 1 {
            let (id, label) = candidates.remove(0);
            (
                Some(id),
                if label.is_empty() {
                    "Display".into()
                } else {
                    label
                },
            )
        } else {
            (None, "Display".into())
        };
        displays.push(Display {
            rect: *rect,
            id,
            label,
        });
        TRUE
    }
    let mut result: Vec<Display> = Vec::new();
    unsafe {
        EnumDisplayMonitors(
            HDC::default(),
            None,
            Some(callback),
            LPARAM(&mut result as *mut Vec<Display> as isize),
        )
        .ok()?;
    }
    reject_ambiguous(&mut result);
    Ok(result)
}

fn reject_ambiguous(result: &mut [Display]) {
    let mut counts = HashMap::new();
    for id in result.iter().filter_map(|d| d.id.as_ref()) {
        *counts.entry(id.clone()).or_insert(0) += 1;
    }
    for display in result {
        if display.id.as_ref().is_some_and(|id| counts[id] != 1) {
            display.id = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicate_identity_is_rejected_without_changing_geometry() {
        let left = RECT {
            left: -1920,
            top: -200,
            right: 0,
            bottom: 880,
        };
        let right = RECT {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1080,
        };
        let mut displays = vec![
            Display {
                rect: left,
                id: Some("one".into()),
                label: "Same".into(),
            },
            Display {
                rect: right,
                id: Some("two".into()),
                label: "Same".into(),
            },
        ];
        reject_ambiguous(&mut displays);
        assert_eq!(displays[0].id.as_deref(), Some("one"));
        assert_eq!(displays[1].id.as_deref(), Some("two"));
        assert_eq!(displays[0].rect, left);
        displays[1].id = Some("one".into());
        reject_ambiguous(&mut displays);
        assert!(displays.iter().all(|d| d.id.is_none()));
        assert_eq!(displays[1].rect, right);
    }
}
