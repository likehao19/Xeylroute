use std::{
    fs,
    io::{self, Read, Write},
    mem::size_of,
    net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream},
    os::windows::{
        ffi::OsStrExt,
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{ERROR_CANCELLED, WAIT_OBJECT_0, WAIT_TIMEOUT},
    System::{
        Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED},
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        Threading::WaitForSingleObject,
    },
    UI::{
        Shell::{
            ShellExecuteExW, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS,
            SHELLEXECUTEINFOW,
        },
        WindowsAndMessaging::SW_HIDE,
    },
};

pub const ARG: &str = "--routepilot-tun-worker";
const MAX_CONFIG_BYTES: usize = 8 * 1024 * 1024;

pub struct Worker {
    process: OwnedHandle,
    lease: TcpStream,
}

fn finished(process: &OwnedHandle, timeout: u32) -> io::Result<bool> {
    match unsafe { WaitForSingleObject(process.as_raw_handle(), timeout) } {
        WAIT_OBJECT_0 => Ok(true),
        WAIT_TIMEOUT => Ok(false),
        _ => Err(io::Error::last_os_error()),
    }
}

impl Worker {
    pub fn launch(dir: &Path, config: &[u8]) -> Result<Self, String> {
        if config.len() > MAX_CONFIG_BYTES {
            return Err("TUN 配置超过大小限制。".into());
        }
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|e| e.to_string())?;
        listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let port = listener.local_addr().map_err(|e| e.to_string())?.port();
        let mut random = [0_u8; 32];
        getrandom::fill(&mut random).map_err(|e| e.to_string())?;
        let token: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let file: Vec<_> = exe.as_os_str().encode_wide().chain([0]).collect();
        let verb: Vec<_> = "runas".encode_utf16().chain([0]).collect();
        // The directory is an absolute Windows path ending in "core".
        let args: Vec<_> = format!("{ARG} {port} {token} \"")
            .encode_utf16()
            .chain(dir.as_os_str().encode_wide())
            .chain([b'"' as u16, 0])
            .collect();
        let mut info = SHELLEXECUTEINFOW {
            cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
            fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI,
            lpVerb: verb.as_ptr(),
            lpFile: file.as_ptr(),
            lpParameters: args.as_ptr(),
            nShow: SW_HIDE,
            ..Default::default()
        };
        let error = unsafe {
            let initialized =
                CoInitializeEx(std::ptr::null(), COINIT_APARTMENTTHREADED as u32) >= 0;
            let result = ShellExecuteExW(&mut info);
            let error = (result == 0).then(io::Error::last_os_error);
            if initialized {
                CoUninitialize();
            }
            error
        };
        if let Some(error) = error {
            return Err(if error.raw_os_error() == Some(ERROR_CANCELLED as i32) {
                "已取消 Windows 授权，TUN 未开启。".into()
            } else {
                error.to_string()
            });
        }
        if info.hProcess.is_null() {
            return Err("Windows 未返回 TUN 后台进程。".into());
        }
        let process = unsafe { OwnedHandle::from_raw_handle(info.hProcess) };
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match listener.accept() {
                Ok((mut lease, _)) => {
                    lease
                        .set_read_timeout(Some(Duration::from_millis(350)))
                        .map_err(|e| e.to_string())?;
                    let mut received = [0_u8; 64];
                    if lease.read_exact(&mut received).is_ok() && received == token.as_bytes() {
                        lease
                            .set_write_timeout(Some(Duration::from_secs(5)))
                            .map_err(|e| e.to_string())?;
                        lease
                            .write_all(&(config.len() as u32).to_le_bytes())
                            .and_then(|_| lease.write_all(config))
                            .map_err(|e| e.to_string())?;
                        return Ok(Self { process, lease });
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error.to_string()),
            }
            if finished(&process, 40).map_err(|e| e.to_string())? {
                break;
            }
        }
        Err("TUN 后台未能启动，请查看 mihomo.log。".into())
    }

    pub fn running(&self) -> io::Result<bool> {
        finished(&self.process, 0).map(|exited| !exited)
    }

    pub fn stop(&self) -> io::Result<()> {
        let _ = self.lease.shutdown(Shutdown::Both);
        if finished(&self.process, 5000)? {
            Ok(())
        } else {
            Err(io::Error::new(io::ErrorKind::TimedOut, "TUN 后台尚未退出"))
        }
    }
}

pub fn run(mut args: impl Iterator<Item = std::ffi::OsString>) -> io::Result<()> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "Invalid TUN worker arguments");
    let port = args
        .next()
        .and_then(|s| s.to_str()?.parse::<u16>().ok())
        .filter(|port| *port > 0)
        .ok_or_else(invalid)?;
    let token = args
        .next()
        .and_then(|s| s.into_string().ok())
        .filter(|s| s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit()))
        .ok_or_else(invalid)?;
    let dir = args
        .next()
        .map(PathBuf::from)
        .filter(|p| p.is_absolute() && p.file_name().is_some_and(|n| n == "core"))
        .ok_or_else(invalid)?;
    if args.next().is_some() || unsafe { windows_sys::Win32::UI::Shell::IsUserAnAdmin() } == 0 {
        return Err(invalid());
    }
    let mut lease =
        TcpStream::connect_timeout(&(Ipv4Addr::LOCALHOST, port).into(), Duration::from_secs(3))?;
    lease.write_all(token.as_bytes())?;
    lease.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut size = [0; 4];
    lease.read_exact(&mut size)?;
    let length = u32::from_le_bytes(size) as usize;
    if length == 0 || length > MAX_CONFIG_BYTES {
        return Err(invalid());
    }
    let mut config = vec![0; length];
    lease.read_exact(&mut config)?;
    lease.set_read_timeout(Some(Duration::from_millis(200)))?;
    let log = fs::File::create(dir.join("mihomo.log"))?;
    let mut command = super::mihomo_command(&dir);
    command
        .args(["-f", "-"])
        .env_remove("SAFE_PATHS")
        .env_remove("SKIP_SAFE_PATH_CHECK")
        .stdin(Stdio::piped())
        .stderr(log.try_clone()?)
        .stdout(log);
    let (mut child, _job) = spawn_managed_core(command)?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(&config)?;
    }
    let mut byte = [0];
    loop {
        if child.try_wait()?.is_some() {
            return Ok(());
        }
        match lease.read(&mut byte) {
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) =>
            {
                continue
            }
            _ => break,
        }
    }
    disable_tun(&config);
    let _ = child.kill();
    child.wait()?;
    Ok(())
}

pub(crate) fn spawn_managed_core(mut command: Command) -> io::Result<(Child, OwnedHandle)> {
    let raw = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
    if raw.is_null() {
        return Err(io::Error::last_os_error());
    }
    let job = unsafe { OwnedHandle::from_raw_handle(raw) };
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if unsafe {
        SetInformationJobObject(
            job.as_raw_handle(),
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let mut child = command.spawn()?;
    if unsafe { AssignProcessToJobObject(job.as_raw_handle(), child.as_raw_handle()) } == 0 {
        let error = io::Error::last_os_error();
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }
    Ok((child, job))
}

#[cfg(test)]
#[test]
fn closing_job_stops_managed_child() {
    let mut command = Command::new("ping.exe");
    command
        .args(["-t", "127.0.0.1"])
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let (child, job) = spawn_managed_core(command).unwrap();
    drop(job);
    let result = unsafe { WaitForSingleObject(child.as_raw_handle(), 2000) };
    assert_eq!(result, WAIT_OBJECT_0);
}

fn disable_tun(config: &[u8]) {
    let Ok(config) = serde_json::from_slice::<serde_json::Value>(config) else {
        return;
    };
    let Some(endpoint) = config["external-controller"]
        .as_str()
        .and_then(|s| s.parse::<SocketAddr>().ok())
        .filter(|address| address.ip().is_loopback())
    else {
        return;
    };
    let Some(token) = config["secret"].as_str() else {
        return;
    };
    tauri::async_runtime::block_on(async {
        if let Ok(client) = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(2))
            .build()
        {
            let _ = client
                .patch(format!("http://{endpoint}/configs"))
                .bearer_auth(token)
                .json(&serde_json::json!({"tun":{"enable":false}}))
                .send()
                .await;
        }
    });
}
