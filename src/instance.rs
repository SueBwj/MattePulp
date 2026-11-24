//! Windows 单实例锁：以现有设置目录为身份，语义对齐 macOS 的
//! `instance.lock` + `flock(LOCK_EX | LOCK_NB)` 启动路径。
//!
//! 锁文件是设置目录内的 `instance.lock`：首次运行时创建，长期保留，
//! 进程从不删除。占用期间句柄由 [`InstanceLock`] RAII 保管，正常退出、
//! 早期初始化失败或进程崩溃时释放。指向同一真实目录的路径别名（大小写、
//! 连接点、符号链接、8.3 短名）都会打开同一锁文件，仍然互斥；不同设置
//! 目录互不阻塞，可以并存。

use std::fs::{File, OpenOptions};
use std::io;
use std::os::windows::fs::OpenOptionsExt;
use std::path::Path;

use windows::core::{Error, HRESULT};
use windows::Win32::Foundation::{ERROR_INVALID_PARAMETER, ERROR_SHARING_VIOLATION};

/// 与 macOS 一致的锁文件名，位于现有设置目录内。
const LOCK_FILE_NAME: &str = "instance.lock";

/// `acquire` 的结果。
pub enum Acquired {
    /// 本实例持有锁，直到 [`InstanceLock`] 被 drop。
    Held(InstanceLock),
    /// 同一设置目录已有实例在运行：按既有行为安静退出。
    AlreadyRunning,
}

/// 已持有的单实例锁；`Drop` 关闭底层句柄并释放占用。
pub struct InstanceLock {
    /// 只需句柄保持打开，字段本身不读取。
    _file: File,
}

/// 以 `settings_dir` 为身份获取单实例锁。
///
/// 先确保设置目录存在（对齐 macOS 的 `createDirectory`）。`share_mode(0)`
/// 表示持有期间不允许并发打开：同目录的第二个实例会得到共享冲突，
/// 返回 [`Acquired::AlreadyRunning`]；其余错误按启动失败上抛。
pub fn acquire(settings_dir: &Path) -> windows::core::Result<Acquired> {
    std::fs::create_dir_all(settings_dir).map_err(io_error)?;
    match OpenOptions::new()
        .create(true)
        // 锁文件只在缺失时创建，内容从不改写。
        .truncate(false)
        .write(true)
        .share_mode(0)
        .open(settings_dir.join(LOCK_FILE_NAME))
    {
        Ok(file) => Ok(Acquired::Held(InstanceLock { _file: file })),
        Err(error) if error.raw_os_error() == Some(ERROR_SHARING_VIOLATION.0 as i32) => {
            Ok(Acquired::AlreadyRunning)
        }
        Err(error) => Err(io_error(error)),
    }
}

/// 目录创建与锁文件打开失败转换为 windows 错误，沿用现有失败处理。
fn io_error(error: io::Error) -> Error {
    let code = error
        .raw_os_error()
        .unwrap_or(ERROR_INVALID_PARAMETER.0 as i32) as u32;
    Error::from_hresult(HRESULT::from_win32(code))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "mattepulp-instance-lock-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ))
    }

    #[test]
    fn same_directory_rejects_then_release_allows_the_next_instance() {
        let dir = temp_dir("same");
        let first = acquire(&dir).unwrap();
        assert!(matches!(first, Acquired::Held(_)));
        assert!(matches!(acquire(&dir).unwrap(), Acquired::AlreadyRunning));
        drop(first);
        let second = acquire(&dir).unwrap();
        assert!(matches!(second, Acquired::Held(_)));
        drop(second);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn different_directories_lock_independently() {
        let first_dir = temp_dir("independent-first");
        let second_dir = temp_dir("independent-second");
        let first = acquire(&first_dir).unwrap();
        let second = acquire(&second_dir).unwrap();
        assert!(matches!(first, Acquired::Held(_)));
        assert!(matches!(second, Acquired::Held(_)));
        drop((first, second));
        std::fs::remove_dir_all(&first_dir).unwrap();
        std::fs::remove_dir_all(&second_dir).unwrap();
    }

    #[test]
    fn aliases_of_one_real_directory_still_conflict() {
        let dir = temp_dir("alias");
        let first = acquire(&dir).unwrap();
        assert!(matches!(first, Acquired::Held(_)));

        // 无 shell 的确定性别名：预建子目录后经 nested/.. 折回同一真实目录。
        // 先用 canonicalize 核对两个路径确实指向同一目录，再验证锁仍互斥。
        // 连接点、符号链接、8.3 短名等别名机制同理，但未在本测试中实测。
        let alias = dir.join("nested").join("..");
        std::fs::create_dir_all(dir.join("nested")).unwrap();
        assert_eq!(alias.canonicalize().unwrap(), dir.canonicalize().unwrap());
        assert!(matches!(acquire(&alias).unwrap(), Acquired::AlreadyRunning));

        drop(first);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn lock_failures_other_than_sharing_violation_fail_startup() {
        // 锁文件位置被目录占用：打开得到拒绝访问，而不是共享冲突。
        let blocked = temp_dir("blocked");
        std::fs::create_dir_all(&blocked).unwrap();
        std::fs::create_dir(blocked.join(LOCK_FILE_NAME)).unwrap();
        assert!(acquire(&blocked).is_err());
        std::fs::remove_dir_all(&blocked).unwrap();

        // 设置目录无法创建：父路径是一个普通文件。
        let parent = temp_dir("blocked-parent");
        std::fs::create_dir_all(&parent).unwrap();
        let file = parent.join("blocker");
        std::fs::write(&file, b"").unwrap();
        assert!(acquire(&file).is_err());
        std::fs::remove_dir_all(&parent).unwrap();
    }
}
