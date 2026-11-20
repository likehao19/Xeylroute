use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessInfo {
    pid: u32,
    name: String,
    exe: String,
    path: String,
    started_at: String,
    thread_count: u32,
    icon: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadInfo {
    tid: u32,
    base_priority: i32,
}

#[tauri::command]
pub async fn list_running_processes() -> Result<Vec<ProcessInfo>, String> {
    tauri::async_runtime::spawn_blocking(platform::scan_processes)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn list_process_threads(pid: u32, started_at: String) -> Result<Vec<ThreadInfo>, String> {
    tauri::async_runtime::spawn_blocking(move || platform::scan_threads(pid, &started_at))
        .await
        .map_err(|error| error.to_string())?
}

#[cfg(windows)]
mod platform {
    use super::{ProcessInfo, ThreadInfo};
    use std::{collections::HashMap, io, mem::size_of, path::Path};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, FILETIME, HANDLE, INVALID_HANDLE_VALUE},
        System::{
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, Thread32First,
                Thread32Next, PROCESSENTRY32W, TH32CS_SNAPPROCESS, TH32CS_SNAPTHREAD,
                THREADENTRY32,
            },
            Threading::{
                GetProcessTimes, OpenProcess, QueryFullProcessImageNameW,
                PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
    };

    struct OwnedHandle(HANDLE);

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            unsafe { CloseHandle(self.0) };
        }
    }

    pub(crate) fn query_process(pid: u32) -> Option<ProcessInfo> {
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if handle.is_null() {
            return None;
        }
        let handle = OwnedHandle(handle);
        let mut image = vec![0u16; 32768];
        let mut length = image.len() as u32;
        if unsafe { QueryFullProcessImageNameW(handle.0, 0, image.as_mut_ptr(), &mut length) } == 0
        {
            return None;
        }
        let mut created = FILETIME::default();
        let mut exited = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        if unsafe { GetProcessTimes(handle.0, &mut created, &mut exited, &mut kernel, &mut user) }
            == 0
        {
            return None;
        }
        let path = String::from_utf16(&image[..length as usize]).ok()?;
        let exe = Path::new(&path).file_name()?.to_str()?.to_owned();
        let name = Path::new(&exe).file_stem()?.to_str()?.to_owned();
        let ticks = (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime);
        Some(ProcessInfo {
            pid,
            name,
            exe,
            path,
            started_at: ticks.to_string(),
            thread_count: 0,
            icon: None,
        })
    }

    fn windows_component_roots() -> Vec<String> {
        let normalize = |path: &str| path.replace('\\', "/").trim_end_matches('/').to_lowercase();
        let mut roots = vec![normalize(
            &std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into()),
        )];
        for name in ["ProgramFiles", "ProgramFiles(x86)"] {
            if let Ok(path) = std::env::var(name) {
                roots.push(format!(
                    "{}/microsoft/edgewebview/application",
                    normalize(&path)
                ));
            }
        }
        roots
    }

    pub(crate) fn is_windows_component(path: &str, roots: &[String]) -> bool {
        let path = path.replace('\\', "/").to_lowercase();
        roots.iter().any(|root| {
            path.strip_prefix(root)
                .is_some_and(|tail| tail.starts_with('/'))
        })
    }

    pub fn scan_processes() -> Result<Vec<ProcessInfo>, String> {
        let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
        if snapshot == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error().to_string());
        }
        let snapshot = OwnedHandle(snapshot);
        let mut entry = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        if unsafe { Process32FirstW(snapshot.0, &mut entry) } == 0 {
            return Err(io::Error::last_os_error().to_string());
        }
        let mut items = Vec::new();
        let mut metadata = HashMap::new();
        let hidden_roots = windows_component_roots();
        loop {
            if let Some(mut info) = query_process(entry.th32ProcessID)
                .filter(|process| !is_windows_component(&process.path, &hidden_roots))
            {
                info.thread_count = entry.cntThreads;
                let (name, icon) = metadata
                    .entry(info.path.to_lowercase())
                    .or_insert_with(|| crate::program_files::read(Path::new(&info.path)));
                if let Some(name) = name {
                    info.name.clone_from(name);
                }
                info.icon.clone_from(icon);
                items.push(info);
            }
            if unsafe { Process32NextW(snapshot.0, &mut entry) } == 0 {
                break;
            }
        }
        items.sort_by(|a, b| {
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then(a.pid.cmp(&b.pid))
        });
        Ok(items)
    }

    pub fn scan_threads(pid: u32, started_at: &str) -> Result<Vec<ThreadInfo>, String> {
        let current = || query_process(pid).is_some_and(|process| process.started_at == started_at);
        if !current() {
            return Err("该进程已退出或重新启动，请刷新列表。".into());
        }
        let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
        if snapshot == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error().to_string());
        }
        let snapshot = OwnedHandle(snapshot);
        let mut entry = THREADENTRY32 {
            dwSize: size_of::<THREADENTRY32>() as u32,
            ..Default::default()
        };
        let mut threads = Vec::new();
        let mut found = unsafe { Thread32First(snapshot.0, &mut entry) };
        while found != 0 {
            if entry.th32OwnerProcessID == pid {
                threads.push(ThreadInfo {
                    tid: entry.th32ThreadID,
                    base_priority: entry.tpBasePri,
                });
            }
            entry.dwSize = size_of::<THREADENTRY32>() as u32;
            found = unsafe { Thread32Next(snapshot.0, &mut entry) };
        }
        if !current() {
            return Err("该进程已退出或重新启动，请刷新列表。".into());
        }
        threads.sort_by_key(|thread| thread.tid);
        Ok(threads)
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::{ProcessInfo, ThreadInfo};
    use std::{collections::HashMap, path::Path, process::Command};

    const SYSTEM_ROOTS: &[&str] = &[
        "/System/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/sbin/",
        "/Library/Apple/",
    ];

    pub(crate) fn is_macos_system_component(path: &str) -> bool {
        !path.starts_with('/') || SYSTEM_ROOTS.iter().any(|root| path.starts_with(root))
    }

    fn thread_counts() -> HashMap<u32, u32> {
        let mut counts = HashMap::new();
        let Ok(output) = Command::new("/bin/ps").args(["-M", "-axo", "pid="]).output() else {
            return counts;
        };
        if !output.status.success() {
            return counts;
        }
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            if let Ok(pid) = line.trim().parse::<u32>() {
                *counts.entry(pid).or_insert(0) += 1;
            }
        }
        counts
    }

    pub(crate) fn parse_ps_line(line: &str) -> Option<(u32, String, String)> {
        // Format from `ps -axo pid=,lstart=,comm=`:
        //   1234 Thu Nov 19 22:10:05 2026 /Applications/Chrome.app/Contents/MacOS/Chrome
        let trimmed = line.trim_start();
        let mut parts = trimmed.splitn(7, char::is_whitespace);
        let pid = parts.next()?.parse::<u32>().ok()?;
        let rest = trimmed[trimmed.find(char::is_whitespace)?..].trim_start();
        let mut tokens = Vec::with_capacity(5);
        let mut cursor = rest;
        for _ in 0..5 {
            let end = cursor.find(char::is_whitespace)?;
            tokens.push(&cursor[..end]);
            cursor = cursor[end..].trim_start();
        }
        if cursor.is_empty() {
            return None;
        }
        Some((pid, tokens.join(" "), cursor.to_owned()))
    }

    pub fn scan_processes() -> Result<Vec<ProcessInfo>, String> {
        let output = Command::new("/bin/ps")
            .args(["-axo", "pid=,lstart=,comm="])
            .output()
            .map_err(|err| format!("无法读取 macOS 进程列表：{err}"))?;
        if !output.status.success() {
            return Err("读取 macOS 进程列表失败。".into());
        }
        let counts = thread_counts();
        let mut items = Vec::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let Some((pid, started_at, path)) = parse_ps_line(line) else {
                continue;
            };
            if is_macos_system_component(&path) {
                continue;
            }
            let Some(exe) = Path::new(&path).file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            let default_name = Path::new(exe)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or(exe)
                .to_owned();
            let (bundle_name, icon) = crate::program_files::read(Path::new(&path));
            items.push(ProcessInfo {
                pid,
                name: bundle_name.unwrap_or(default_name),
                exe: exe.to_owned(),
                path,
                started_at,
                thread_count: counts.get(&pid).copied().unwrap_or(1),
                icon,
            });
        }
        items.sort_by(|a, b| {
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then(a.pid.cmp(&b.pid))
        });
        Ok(items)
    }

    fn process_started_at(pid: u32) -> Option<String> {
        let output = Command::new("/bin/ps")
            .args(["-p", &pid.to_string(), "-o", "lstart="])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let value = String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        (!value.is_empty()).then_some(value)
    }

    pub fn scan_threads(pid: u32, started_at: &str) -> Result<Vec<ThreadInfo>, String> {
        if process_started_at(pid).as_deref() != Some(started_at) {
            return Err("该进程已退出或重新启动，请刷新列表。".into());
        }
        let output = Command::new("/bin/ps")
            .args(["-M", "-p", &pid.to_string(), "-o", "pri="])
            .output()
            .map_err(|err| err.to_string())?;
        if !output.status.success() {
            return Err("无法读取该进程的线程列表。".into());
        }
        let threads: Vec<ThreadInfo> = String::from_utf8_lossy(&output.stdout)
            .lines()
            .enumerate()
            .filter_map(|(index, line)| {
                let pri = line.trim().parse::<i32>().ok()?;
                Some(ThreadInfo {
                    tid: (index + 1) as u32,
                    base_priority: pri,
                })
            })
            .collect();
        if process_started_at(pid).as_deref() != Some(started_at) {
            return Err("该进程已退出或重新启动，请刷新列表。".into());
        }
        Ok(threads)
    }
}

#[cfg(all(not(windows), not(target_os = "macos")))]
mod platform {
    use super::{ProcessInfo, ThreadInfo};
    use std::{fs, path::Path};

    fn read_stat(pid: u32) -> Option<(String, u32)> {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let (_, tail) = stat.rsplit_once(") ")?;
        let fields: Vec<&str> = tail.split_whitespace().collect();
        let threads = fields.get(17)?.parse::<u32>().ok().unwrap_or(1);
        let started_at = fields.get(19)?.to_string();
        Some((started_at, threads))
    }

    pub fn scan_processes() -> Result<Vec<ProcessInfo>, String> {
        let mut items = Vec::new();
        for entry in fs::read_dir("/proc").map_err(|e| e.to_string())?.flatten() {
            let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() else {
                continue;
            };
            let Ok(exe_path) = fs::read_link(entry.path().join("exe")) else {
                continue;
            };
            let path = exe_path.to_string_lossy().into_owned();
            if path.starts_with("/usr/lib/systemd") || path.starts_with("/sbin/") {
                continue;
            }
            let Some((started_at, thread_count)) = read_stat(pid) else {
                continue;
            };
            let exe = Path::new(&path)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or(&path)
                .to_owned();
            let name = Path::new(&exe)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or(&exe)
                .to_owned();
            items.push(ProcessInfo {
                pid,
                name,
                exe,
                path,
                started_at,
                thread_count,
                icon: None,
            });
        }
        items.sort_by(|a, b| {
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then(a.pid.cmp(&b.pid))
        });
        Ok(items)
    }

    pub fn scan_threads(pid: u32, started_at: &str) -> Result<Vec<ThreadInfo>, String> {
        if read_stat(pid).map(|(s, _)| s).as_deref() != Some(started_at) {
            return Err("该进程已退出或重新启动，请刷新列表。".into());
        }
        let mut threads = Vec::new();
        for entry in fs::read_dir(format!("/proc/{pid}/task"))
            .map_err(|e| e.to_string())?
            .flatten()
        {
            if let Ok(tid) = entry.file_name().to_string_lossy().parse::<u32>() {
                threads.push(ThreadInfo {
                    tid,
                    base_priority: 0,
                });
            }
        }
        threads.sort_by_key(|t| t.tid);
        Ok(threads)
    }
}

#[cfg(test)]
mod tests {
    #[cfg(windows)]
    #[test]
    fn verifies_real_windows_process_creation_time_before_reading_threads() {
        let pid = std::process::id();
        let process = super::platform::query_process(pid).unwrap();
        assert_eq!(process.pid, pid);
        assert!(std::path::Path::new(&process.path).is_absolute());
        assert!(process.started_at.parse::<u64>().unwrap() > 0);
        assert!(!super::platform::scan_threads(pid, &process.started_at).unwrap().is_empty());
        assert!(super::platform::scan_threads(pid, "0").is_err());
    }

    #[cfg(windows)]
    #[test]
    fn hides_system_paths_and_preserves_app_owned_runtimes() {
        let roots = vec![
            "d:/windows".into(),
            "c:/program files (x86)/microsoft/edgewebview/application".into(),
        ];
        assert!(super::platform::is_windows_component(
            r"D:\WINDOWS\System32\cmd.exe",
            &roots
        ));
        assert!(!super::platform::is_windows_component(
            r"D:\Apps\Browser\msedgewebview2.exe",
            &roots
        ));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parses_macos_ps_and_filters_system_daemons() {
        let line = "  4321 Thu Nov 19 22:10:05 2026 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
        let (pid, started, path) = super::platform::parse_ps_line(line).unwrap();
        assert_eq!(pid, 4321);
        assert_eq!(started, "Thu Nov 19 22:10:05 2026");
        assert_eq!(
            path,
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        );
        assert!(!super::platform::is_macos_system_component(&path));
        assert!(super::platform::is_macos_system_component(
            "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        ));
        assert!(super::platform::is_macos_system_component(
            "/usr/libexec/trustd"
        ));
    }
}
