use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{FromRawHandle, OwnedHandle};

use windows::core::{Error, Interface, Result, BSTR, HRESULT, PWSTR, VARIANT};
use windows::Win32::Foundation::{
    LocalFree, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_INSUFFICIENT_BUFFER, E_FAIL,
    E_INVALIDARG, HANDLE, HLOCAL, RPC_E_CHANGED_MODE, VARIANT_BOOL, VARIANT_FALSE,
};
use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
    COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::TaskScheduler::{
    IExecAction, ILogonTrigger, IRegisteredTask, ITaskDefinition, ITaskFolder, ITaskService,
    TaskScheduler, TASK_ACTION_EXEC, TASK_CREATE, TASK_LOGON_INTERACTIVE_TOKEN, TASK_RUNLEVEL_LUA,
    TASK_TRIGGER_LOGON,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

const SOURCE: &str = "com.suebwj.sue-paper.login";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Off,
    On,
    Blocked,
    Unavailable,
}

trait Registration {
    fn status(&self) -> Result<State>;
    fn register(&self) -> Result<()>;
    fn unregister(&self) -> Result<()>;
}

pub fn status() -> State {
    match Scheduler::connect().and_then(|scheduler| scheduler.status()) {
        Ok(state) => state,
        Err(error) => {
            eprintln!("read launch at login failed: {error}");
            State::Unavailable
        }
    }
}

pub fn change(enabled: bool) -> bool {
    match Scheduler::connect().and_then(|scheduler| set_enabled(&scheduler, enabled)) {
        Ok(()) => true,
        Err(error) => {
            eprintln!("change launch at login failed: {error}");
            false
        }
    }
}

fn set_enabled(registration: &impl Registration, enabled: bool) -> Result<()> {
    let expected = if enabled { State::On } else { State::Off };
    match (registration.status()?, enabled) {
        (State::On, true) | (State::Off, false) => return Ok(()),
        (State::Off, true) => registration.register()?,
        (State::On | State::Blocked, false) => registration.unregister()?,
        _ => return Err(E_FAIL.into()),
    }
    if registration.status()? != expected {
        return Err(E_FAIL.into());
    }
    Ok(())
}

struct Apartment(bool);

impl Apartment {
    fn enter() -> Result<Self> {
        let result = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
        if result == RPC_E_CHANGED_MODE {
            return Ok(Self(false));
        }
        result.ok()?;
        Ok(Self(true))
    }
}

impl Drop for Apartment {
    fn drop(&mut self) {
        if self.0 {
            unsafe { CoUninitialize() }
        }
    }
}

struct Scheduler {
    service: ITaskService,
    folder: ITaskFolder,
    sid: BSTR,
    name: BSTR,
    executable: BSTR,
    _apartment: Apartment,
}

impl Scheduler {
    fn connect() -> Result<Self> {
        let apartment = Apartment::enter()?;
        let sid = user_sid()?;
        let name = task_name(&sid);
        let executable =
            std::env::current_exe().map_err(|error| Error::new(E_FAIL, error.to_string()))?;
        let executable =
            BSTR::from_wide(&executable.as_os_str().encode_wide().collect::<Vec<_>>())?;
        unsafe {
            let service: ITaskService =
                CoCreateInstance(&TaskScheduler, None, CLSCTX_INPROC_SERVER)?;
            let empty = VARIANT::default();
            service.Connect(&empty, &empty, &empty, &empty)?;
            let folder = service.GetFolder(&BSTR::from("\\"))?;
            Ok(Self {
                service,
                folder,
                sid,
                name,
                executable,
                _apartment: apartment,
            })
        }
    }

    fn owned_task(&self) -> Result<Option<(IRegisteredTask, ITaskDefinition)>> {
        unsafe {
            let task = match self.folder.GetTask(&self.name) {
                Ok(task) => task,
                Err(error) if error.code() == HRESULT::from_win32(ERROR_FILE_NOT_FOUND.0) => {
                    return Ok(None)
                }
                Err(error) => return Err(error),
            };
            let definition = task.Definition()?;
            let mut source = BSTR::new();
            definition.RegistrationInfo()?.Source(&mut source)?;
            if source != SOURCE {
                return Err(ERROR_ALREADY_EXISTS.to_hresult().into());
            }
            Ok(Some((task, definition)))
        }
    }

    fn definition(&self, executable: &BSTR) -> Result<ITaskDefinition> {
        // The scheduler expands variables in an Exec action. Register only a literal path.
        if executable.as_wide().contains(&(b'%' as u16)) {
            return Err(E_INVALIDARG.into());
        }
        unsafe {
            let definition = self.service.NewTask(0)?;
            definition
                .RegistrationInfo()?
                .SetSource(&BSTR::from(SOURCE))?;
            let principal = definition.Principal()?;
            principal.SetUserId(&self.sid)?;
            principal.SetLogonType(TASK_LOGON_INTERACTIVE_TOKEN)?;
            principal.SetRunLevel(TASK_RUNLEVEL_LUA)?;
            let trigger = definition
                .Triggers()?
                .Create(TASK_TRIGGER_LOGON)?
                .cast::<ILogonTrigger>()?;
            trigger.SetUserId(&self.sid)?;
            let action = definition
                .Actions()?
                .Create(TASK_ACTION_EXEC)?
                .cast::<IExecAction>()?;
            // The executable and arguments use separate scheduler fields.
            action.SetPath(executable)?;
            let settings = definition.Settings()?;
            settings.SetDisallowStartIfOnBatteries(VARIANT_FALSE)?;
            settings.SetStopIfGoingOnBatteries(VARIANT_FALSE)?;
            settings.SetExecutionTimeLimit(&BSTR::from("PT0S"))?;
            settings.SetPriority(5)?;
            Ok(definition)
        }
    }
}

impl Registration for Scheduler {
    fn status(&self) -> Result<State> {
        let Some((task, definition)) = self.owned_task()? else {
            return Ok(State::Off);
        };
        unsafe {
            if !task.Enabled()?.as_bool() {
                return Ok(State::Blocked);
            }
            let triggers = definition.Triggers()?;
            let actions = definition.Actions()?;
            let mut trigger_count = 0;
            let mut action_count = 0;
            triggers.Count(&mut trigger_count)?;
            actions.Count(&mut action_count)?;
            if trigger_count != 1 || action_count != 1 {
                return Ok(State::Blocked);
            }
            let (Ok(trigger), Ok(action)) = (
                triggers.get_Item(1)?.cast::<ILogonTrigger>(),
                actions.get_Item(1)?.cast::<IExecAction>(),
            ) else {
                return Ok(State::Blocked);
            };
            let mut enabled = VARIANT_BOOL::default();
            let mut path = BSTR::new();
            let mut arguments = BSTR::new();
            trigger.Enabled(&mut enabled)?;
            action.Path(&mut path)?;
            action.Arguments(&mut arguments)?;
            if enabled.as_bool() && path == self.executable && arguments.is_empty() {
                Ok(State::On)
            } else {
                Ok(State::Blocked)
            }
        }
    }

    fn register(&self) -> Result<()> {
        let definition = self.definition(&self.executable)?;
        unsafe {
            let empty = VARIANT::default();
            self.folder.RegisterTaskDefinition(
                &self.name,
                &definition,
                TASK_CREATE.0,
                &VARIANT::from(self.sid.clone()),
                &empty,
                TASK_LOGON_INTERACTIVE_TOKEN,
                &empty,
            )?;
        }
        Ok(())
    }

    fn unregister(&self) -> Result<()> {
        if self.owned_task()?.is_some() {
            unsafe { self.folder.DeleteTask(&self.name, 0)? };
        }
        Ok(())
    }
}

fn task_name(sid: &BSTR) -> BSTR {
    BSTR::from(format!("MattePulp-LaunchAtLogin-{sid}"))
}

fn user_sid() -> Result<BSTR> {
    unsafe {
        let mut handle = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut handle)?;
        let _token = OwnedHandle::from_raw_handle(handle.0);
        let mut size = 0;
        let error = match GetTokenInformation(handle, TokenUser, None, 0, &mut size) {
            Ok(()) => return Err(E_FAIL.into()),
            Err(error) => error,
        };
        if error.code() != HRESULT::from_win32(ERROR_INSUFFICIENT_BUFFER.0) {
            return Err(error);
        }
        let mut buffer = vec![0usize; (size as usize).div_ceil(size_of::<usize>())];
        GetTokenInformation(
            handle,
            TokenUser,
            Some(buffer.as_mut_ptr().cast()),
            size,
            &mut size,
        )?;
        let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
        let mut text = PWSTR::null();
        ConvertSidToStringSidW(user.User.Sid, &mut text)?;
        let sid = BSTR::from_wide(text.as_wide());
        let _ = LocalFree(HLOCAL(text.0.cast()));
        sid
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::fs;
    use std::path::Path;

    struct Fixture<'a> {
        directory: &'a Path,
        fail: bool,
        writes: Cell<u32>,
    }

    impl Registration for Fixture<'_> {
        fn status(&self) -> Result<State> {
            match fs::read(self.directory.join("mattepulp")) {
                Ok(bytes) if bytes == b"enabled" => Ok(State::On),
                Ok(_) => Ok(State::Blocked),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(State::Off),
                Err(_) => Err(E_FAIL.into()),
            }
        }

        fn register(&self) -> Result<()> {
            self.writes.set(self.writes.get() + 1);
            if self.fail {
                return Err(E_FAIL.into());
            }
            fs::write(self.directory.join("mattepulp"), b"enabled").unwrap();
            Ok(())
        }

        fn unregister(&self) -> Result<()> {
            self.writes.set(self.writes.get() + 1);
            if self.fail {
                return Err(E_FAIL.into());
            }
            fs::remove_file(self.directory.join("mattepulp")).unwrap();
            Ok(())
        }
    }

    #[test]
    fn registration_round_trips_without_touching_another_app() {
        let dir =
            std::env::temp_dir().join(format!("mattepulp-login-tests-{}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("another-app"), b"enabled").unwrap();
        let mut store = Fixture {
            directory: &dir,
            fail: true,
            writes: Cell::new(0),
        };
        assert_eq!(store.status().unwrap(), State::Off);
        set_enabled(&store, false).unwrap();
        assert_eq!(store.writes.get(), 0);
        assert!(set_enabled(&store, true).is_err());
        assert_eq!(store.status().unwrap(), State::Off);

        store.fail = false;
        set_enabled(&store, true).unwrap();
        set_enabled(&store, true).unwrap();
        assert_eq!(store.writes.get(), 2);
        let mut reopened = Fixture {
            directory: &dir,
            fail: true,
            writes: Cell::new(0),
        };
        assert_eq!(reopened.status().unwrap(), State::On);
        assert!(set_enabled(&reopened, false).is_err());
        assert_eq!(reopened.status().unwrap(), State::On);
        fs::write(dir.join("mattepulp"), b"system-disabled").unwrap();
        assert_eq!(reopened.status().unwrap(), State::Blocked);
        assert!(set_enabled(&reopened, true).is_err());
        reopened.fail = false;
        set_enabled(&reopened, false).unwrap();
        set_enabled(&reopened, false).unwrap();
        assert_eq!(reopened.writes.get(), 2);
        assert_eq!(reopened.status().unwrap(), State::Off);
        assert_eq!(fs::read(dir.join("another-app")).unwrap(), b"enabled");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn write_without_observable_registration_is_a_failure() {
        struct Unchanged;
        impl Registration for Unchanged {
            fn status(&self) -> Result<State> {
                Ok(State::Off)
            }
            fn register(&self) -> Result<()> {
                Ok(())
            }
            fn unregister(&self) -> Result<()> {
                unreachable!()
            }
        }
        assert!(set_enabled(&Unchanged, true).is_err());
        assert_ne!(
            task_name(&BSTR::from("S-1-5-21-1")),
            task_name(&BSTR::from("S-1-5-21-2"))
        );
    }

    #[test]
    fn native_task_definition_separates_executable_path_from_arguments() -> Result<()> {
        let scheduler = Scheduler::connect()?;
        let executable = BSTR::from(r"C:\Paper Test\柔纸\sue-paper.exe");
        let definition = scheduler.definition(&executable)?;
        unsafe {
            let action = definition.Actions()?.get_Item(1)?.cast::<IExecAction>()?;
            let mut path = BSTR::new();
            let mut arguments = BSTR::new();
            action.Path(&mut path)?;
            action.Arguments(&mut arguments)?;
            assert_eq!(path, executable);
            assert!(arguments.is_empty());
            let trigger = definition
                .Triggers()?
                .get_Item(1)?
                .cast::<ILogonTrigger>()?;
            let mut user = BSTR::new();
            trigger.UserId(&mut user)?;
            assert_eq!(user, scheduler.sid);
        }
        Ok(())
    }
}
