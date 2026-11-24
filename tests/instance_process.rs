//! 进程级单实例验收：最接近生产启动路径的测试。
//!
//! 用隔离的临时 APPDATA 启动真实可执行文件，验证同一设置目录互斥、
//! 不同设置目录并存，以及持有者退出后锁释放。锁本身的语义由
//! `src/instance.rs` 的单元测试直接覆盖；这里只看真实进程边界。

use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

/// 测试退出时确保子进程结束，避免残留实例挡住后续运行。
struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn spawn(appdata: &Path) -> ChildGuard {
    let child = Command::new(env!("CARGO_BIN_EXE_sue-paper"))
        .env("APPDATA", appdata)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn sue-paper");
    ChildGuard(child)
}

/// `secs` 秒后进程是否仍在运行；提前退出时打印状态，便于区分失败原因。
fn alive_after(child: &mut Child, secs: u64) -> bool {
    let deadline = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().expect("try_wait child") {
            eprintln!("child exited early: {status}");
            return false;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    child.try_wait().expect("try_wait child").is_none()
}

/// 等待进程退出（最多 `secs` 秒）。
fn wait_exit(child: &mut Child, secs: u64) -> Option<ExitStatus> {
    let deadline = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().expect("try_wait child") {
            return Some(status);
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    None
}

fn temp_appdata(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "mattepulp-instance-{tag}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ))
}

#[test]
fn two_instances_with_distinct_settings_directories_run_concurrently() {
    let first_dir = temp_appdata("distinct-first");
    let second_dir = temp_appdata("distinct-second");
    let mut first = spawn(&first_dir);
    assert!(
        alive_after(&mut first.0, 3),
        "first instance should stay running"
    );
    let mut second = spawn(&second_dir);
    assert!(
        alive_after(&mut second.0, 3),
        "instance with a different APPDATA settings directory must not be blocked"
    );
    assert!(first_dir.join("Sue-Paper").join("instance.lock").exists());
    assert!(second_dir.join("Sue-Paper").join("instance.lock").exists());
}

#[test]
fn same_settings_directory_second_instance_exits_quietly() {
    let dir = temp_appdata("same");
    let mut first = spawn(&dir);
    assert!(
        alive_after(&mut first.0, 3),
        "first instance should stay running"
    );
    let mut second = spawn(&dir);
    let status = wait_exit(&mut second.0, 15).expect("second instance should exit");
    assert!(
        status.success(),
        "duplicate instance must exit quietly with code 0, got {status}"
    );
    assert!(
        alive_after(&mut first.0, 1),
        "first instance should keep running"
    );
}

#[test]
fn exiting_the_first_instance_releases_the_lock() {
    let dir = temp_appdata("release");
    let mut first = spawn(&dir);
    assert!(
        alive_after(&mut first.0, 3),
        "first instance should stay running"
    );
    first.0.kill().expect("kill first instance");
    first.0.wait().expect("reap first instance");
    let mut second = spawn(&dir);
    assert!(
        alive_after(&mut second.0, 3),
        "lock must be released once the holder exits"
    );
}
