use std::{
    fs,
    io::{self, Read, Write},
    net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

pub const ARG: &str = "--routepilot-tun-worker";
const MAX_CONFIG_BYTES: usize = 8 * 1024 * 1024;

pub struct ManagedChild {
    child: Child,
    #[cfg(windows)]
    _job: std::os::windows::io::OwnedHandle,
}

impl ManagedChild {
    pub fn try_wait(&mut self) -> io::Result<Option<std::process::ExitStatus>> {
        self.child.try_wait()
    }

    pub fn terminate(&mut self) -> io::Result<()> {
        let _ = self.child.kill();
        let _ = self.child.wait();
        Ok(())
    }
}

impl Drop for ManagedChild {
    fn drop(&mut self) {
        if matches!(self.child.try_wait(), Ok(None)) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

#[cfg(windows)]
pub(crate) fn spawn_managed_core(mut command: Command) -> io::Result<ManagedChild> {
    use std::mem::size_of;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

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
    Ok(ManagedChild { child, _job: job })
}

#[cfg(not(windows))]
pub(crate) fn spawn_managed_core(mut command: Command) -> io::Result<ManagedChild> {
    let child = command.spawn()?;
    Ok(ManagedChild { child })
}

#[cfg(windows)]
pub struct Worker {
    process: std::os::windows::io::OwnedHandle,
    lease: TcpStream,
}

#[cfg(not(windows))]
pub struct Worker {
    lease: TcpStream,
}

#[cfg(windows)]
fn finished(process: &std::os::windows::io::OwnedHandle, timeout: u32) -> io::Result<bool> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::{
        Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT},
        System::Threading::WaitForSingleObject,
    };
    match unsafe { WaitForSingleObject(process.as_raw_handle(), timeout) } {
        WAIT_OBJECT_0 => Ok(true),
        WAIT_TIMEOUT => Ok(false),
        _ => Err(io::Error::last_os_error()),
    }
}

#[cfg(not(windows))]
fn shell_quote(raw: &str) -> String {
    format!("'{}'", raw.replace('\'', "'\\''"))
}

#[cfg(target_os = "macos")]
fn applescript_escape(raw: &str) -> String {
    raw.replace('\\', "\\\\").replace('"', "\\\"")
}

fn accept_lease(
    listener: &TcpListener,
    token: &str,
    config: &[u8],
    deadline: Instant,
    mut exited: impl FnMut() -> Result<bool, String>,
) -> Result<TcpStream, String> {
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
                    let _ = lease.set_nonblocking(true);
                    return Ok(lease);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => return Err(error.to_string()),
        }
        if exited()? {
            break;
        }
        std::thread::sleep(Duration::from_millis(40));
    }
    Err("TUN 后台未能启动，请查看 mihomo.log。".into())
}

impl Worker {
    #[cfg(windows)]
    pub fn launch(dir: &Path, config: &[u8]) -> Result<Self, String> {
        use std::mem::size_of;
        use std::os::windows::{ffi::OsStrExt, io::FromRawHandle};
        use windows_sys::Win32::{
            Foundation::ERROR_CANCELLED,
            System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED},
            UI::{
                Shell::{
                    ShellExecuteExW, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS,
                    SHELLEXECUTEINFOW,
                },
                WindowsAndMessaging::SW_HIDE,
            },
        };

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
        let process = unsafe { std::os::windows::io::OwnedHandle::from_raw_handle(info.hProcess) };
        let lease = accept_lease(
            &listener,
            &token,
            config,
            Instant::now() + Duration::from_secs(6),
            || finished(&process, 0).map_err(|e| e.to_string()),
        )?;
        Ok(Self { process, lease })
    }

    #[cfg(target_os = "macos")]
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
        let shell_cmd = format!(
            "{} {} {} {} {} >/dev/null 2>&1 &",
            shell_quote(&exe.to_string_lossy()),
            ARG,
            port,
            token,
            shell_quote(&dir.to_string_lossy()),
        );
        let script = format!(
            "do shell script \"{}\" with administrator privileges",
            applescript_escape(&shell_cmd)
        );
        let output = Command::new("/usr/bin/osascript")
            .args(["-e", &script])
            .output()
            .map_err(|e| format!("无法弹出 macOS 授权窗口：{e}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(if stderr.contains("-128") || stderr.contains("canceled") {
                "已取消 macOS 授权，TUN 未开启。".into()
            } else {
                format!("macOS TUN 提权失败：{}", stderr.trim())
            });
        }
        let lease = accept_lease(
            &listener,
            &token,
            config,
            Instant::now() + Duration::from_secs(8),
            || Ok(false),
        )?;
        Ok(Self { lease })
    }

    #[cfg(all(not(windows), not(target_os = "macos")))]
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
        let shell_cmd = format!(
            "{} {} {} {} {} >/dev/null 2>&1 &",
            shell_quote(&exe.to_string_lossy()),
            ARG,
            port,
            token,
            shell_quote(&dir.to_string_lossy()),
        );
        let output = Command::new("pkexec")
            .args(["/bin/sh", "-c", &shell_cmd])
            .output()
            .map_err(|e| format!("无法调用 pkexec 启动 TUN：{e}"))?;
        if !output.status.success() {
            return Err("已取消授权或 Linux TUN 提权失败。".into());
        }
        let lease = accept_lease(
            &listener,
            &token,
            config,
            Instant::now() + Duration::from_secs(8),
            || Ok(false),
        )?;
        Ok(Self { lease })
    }

    #[cfg(windows)]
    pub fn running(&self) -> io::Result<bool> {
        finished(&self.process, 0).map(|exited| !exited)
    }

    #[cfg(not(windows))]
    pub fn running(&self) -> io::Result<bool> {
        let mut byte = [0u8; 1];
        match self.lease.peek(&mut byte) {
            Ok(0) => Ok(false),
            Ok(_) => Ok(true),
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => Ok(true),
            Err(_) => Ok(false),
        }
    }

    #[cfg(windows)]
    pub fn stop(&self) -> io::Result<()> {
        let _ = self.lease.shutdown(Shutdown::Both);
        if finished(&self.process, 5000)? {
            Ok(())
        } else {
            Err(io::Error::new(io::ErrorKind::TimedOut, "TUN 后台尚未退出"))
        }
    }

    #[cfg(not(windows))]
    pub fn stop(&self) -> io::Result<()> {
        let _ = self.lease.shutdown(Shutdown::Both);
        // Give the elevated worker a short window to PATCH tun.enable=false and kill Mihomo.
        std::thread::sleep(Duration::from_millis(320));
        Ok(())
    }
}

fn is_privileged() -> bool {
    #[cfg(windows)]
    {
        unsafe { windows_sys::Win32::UI::Shell::IsUserAnAdmin() != 0 }
    }
    #[cfg(not(windows))]
    {
        Command::new("/usr/bin/id")
            .arg("-u")
            .output()
            .ok()
            .and_then(|out| String::from_utf8(out.stdout).ok())
            .is_some_and(|uid| uid.trim() == "0")
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
    if args.next().is_some() || !is_privileged() {
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
    let mut managed = spawn_managed_core(command)?;
    if let Some(mut stdin) = managed.child.stdin.take() {
        stdin.write_all(&config)?;
    }
    let mut byte = [0];
    loop {
        if managed.try_wait()?.is_some() {
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
    managed.terminate()?;
    Ok(())
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

#[cfg(all(test, windows))]
#[test]
fn closing_job_stops_managed_child() {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::{Foundation::WAIT_OBJECT_0, System::Threading::WaitForSingleObject};

    let mut command = Command::new("ping.exe");
    command
        .args(["-t", "127.0.0.1"])
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let managed = spawn_managed_core(command).unwrap();
    let handle = managed.child.as_raw_handle();
    drop(managed);
    let result = unsafe { WaitForSingleObject(handle, 2000) };
    assert_eq!(result, WAIT_OBJECT_0);
}

#[cfg(all(test, not(windows)))]
#[test]
fn shell_quote_handles_spaces_and_quotes() {
    assert_eq!(
        shell_quote("/Users/a/Library/Application Support/app's/core"),
        "'/Users/a/Library/Application Support/app'\\''s/core'"
    );
}
