use serde::Serialize;
use std::{collections::HashMap, io, mem::size_of, path::Path};
use windows_sys::Win32::{
    Foundation::{CloseHandle, FILETIME, HANDLE, INVALID_HANDLE_VALUE},
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, Thread32First, Thread32Next,
            PROCESSENTRY32W, TH32CS_SNAPPROCESS, TH32CS_SNAPTHREAD, THREADENTRY32,
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

fn query_process(pid: u32) -> Option<ProcessInfo> {
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if handle.is_null() {
        return None;
    }
    let handle = OwnedHandle(handle);
    let mut image = vec![0u16; 32768];
    let mut length = image.len() as u32;
    if unsafe { QueryFullProcessImageNameW(handle.0, 0, image.as_mut_ptr(), &mut length) } == 0 {
        return None;
    }
    let mut created = FILETIME::default();
    let mut exited = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    if unsafe { GetProcessTimes(handle.0, &mut created, &mut exited, &mut kernel, &mut user) } == 0
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

#[tauri::command]
pub async fn list_running_processes() -> Result<Vec<ProcessInfo>, String> {
    tauri::async_runtime::spawn_blocking(scan_processes)
        .await
        .map_err(|error| error.to_string())?
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

fn is_windows_component(path: &str, roots: &[String]) -> bool {
    let path = path.replace('\\', "/").to_lowercase();
    roots.iter().any(|root| {
        path.strip_prefix(root)
            .is_some_and(|tail| tail.starts_with('/'))
    })
}

fn scan_processes() -> Result<Vec<ProcessInfo>, String> {
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
                .or_insert_with(|| super::program_files::read(Path::new(&info.path)));
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

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadInfo {
    tid: u32,
    base_priority: i32,
}

#[tauri::command]
pub async fn list_process_threads(pid: u32, started_at: String) -> Result<Vec<ThreadInfo>, String> {
    tauri::async_runtime::spawn_blocking(move || scan_threads(pid, &started_at))
        .await
        .map_err(|error| error.to_string())?
}

fn scan_threads(pid: u32, started_at: &str) -> Result<Vec<ThreadInfo>, String> {
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

#[cfg(test)]
mod tests {
    #[test]
    fn hides_system_paths_and_preserves_app_owned_runtimes() {
        let roots = vec![
            "d:/windows".into(),
            "c:/program files (x86)/microsoft/edgewebview/application".into(),
        ];
        assert!(super::is_windows_component(
            r"D:\WINDOWS\System32\cmd.exe",
            &roots
        ));
        assert!(super::is_windows_component(
            r"D:\Windows\SystemApps\SearchHost.exe",
            &roots
        ));
        assert!(super::is_windows_component(
            r"C:\Program Files (x86)\Microsoft\EdgeWebView\Application\157\msedgewebview2.exe",
            &roots
        ));
        assert!(!super::is_windows_component(
            r"D:\Apps\Browser\msedgewebview2.exe",
            &roots
        ));
        assert!(!super::is_windows_component(
            r"D:\WindowsTools\terminal.exe",
            &roots
        ));
    }
    #[test]
    fn reports_a_real_process_identity() {
        let list = super::scan_processes().unwrap();
        let current = list.iter().find(|p| p.pid == std::process::id()).unwrap();
        assert!(std::path::Path::new(&current.path).is_absolute());
        assert!(current.started_at.parse::<u64>().unwrap() > 0);
        assert_eq!(
            current.started_at,
            super::query_process(current.pid).unwrap().started_at
        );
        assert!(current.thread_count > 0);
        let threads = super::scan_threads(current.pid, &current.started_at).unwrap();
        assert!(!threads.is_empty());
        assert!(super::scan_threads(current.pid, "0").is_err());
    }
}
