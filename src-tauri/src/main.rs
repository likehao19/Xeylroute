#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod connection_log;
mod fixed_socks;
mod listener_ports;
mod mihomo_api;
mod processes;
mod profile;
mod profile_backup;
mod rule_conditions;
mod program_files;
mod runtime_tuning;
mod share_links;
mod system_proxy;
mod tray;
mod tun_worker;

use mihomo_api::{Controller, LiveController};
use serde::Serialize;
use serde_json::Value;
use std::{
    fs,
    net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};
use tauri::{AppHandle, Manager, RunEvent, State};

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

pub(crate) const CORE_BINARY: &str = if cfg!(windows) {
    "mihomo.exe"
} else {
    "mihomo"
};

fn platform_name() -> &'static str {
    if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

#[derive(Default)]
struct Core(Mutex<Option<CoreProcess>>);

enum CoreProcess {
    #[cfg(not(target_os = "macos"))]
    Local(tun_worker::ManagedChild),
    #[cfg(target_os = "macos")]
    Local(std::process::Child),
    Tun(tun_worker::Worker),
}

struct CoreAccess {
    _lock: Option<fs::File>,
    error: Option<String>,
}

fn require_core_access(app: &AppHandle) -> Result<(), String> {
    match &app.state::<CoreAccess>().error {
        Some(error) => Err(error.clone()),
        None => Ok(()),
    }
}

/// Where the Mihomo executable lives. A release ships it beside the application executable (a
/// Tauri sidecar fetched by `npm run core`); a copy installed by hand into the data directory is
/// the fallback, so existing set-ups keep working.
pub(crate) fn core_binary(dir: &Path) -> Option<PathBuf> {
    let bundled = std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.join(format!("xeylroute-{CORE_BINARY}"))));
    bundled
        .into_iter()
        .chain(std::iter::once(dir.join(CORE_BINARY)))
        .find(|path| path.is_file())
}

pub(crate) fn mihomo_command(dir: &Path) -> Command {
    let mut command = Command::new(core_binary(dir).unwrap_or_else(|| dir.join(CORE_BINARY)));
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_uppercase()
            .starts_with("CLASH_")
        {
            command.env_remove(key);
        }
    }
    command.arg("-d").arg(dir);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CoreStatus {
    app_data: String,
    platform: &'static str,
    available: bool,
    configured: bool,
    running: bool,
    system_proxy: bool,
    tun: bool,
    tun_scope: String,
    selected_tun_available: bool,
    http_port: Option<u16>,
    dns_mode: Option<&'static str>,
    tun_dns_hijack: bool,
}

fn core_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|err| err.to_string())?
        .join("core");
    fs::create_dir_all(&dir).map_err(|err| err.to_string())?;
    Ok(dir)
}

fn running(child: &mut Option<CoreProcess>) -> Result<bool, String> {
    if let Some(process) = child {
        let alive = match process {
            CoreProcess::Local(managed) => managed.try_wait().map(|status| status.is_none()),
            CoreProcess::Tun(worker) => worker.running(),
        }
        .map_err(|err| err.to_string())?;
        if alive {
            return Ok(true);
        }
        *child = None;
    }
    Ok(false)
}

type Stamp = (std::time::SystemTime, u64);

fn stamp(path: &Path) -> Option<Stamp> {
    let metadata = fs::metadata(path).ok()?;
    Some((metadata.modified().ok()?, metadata.len()))
}

/// What the running core was started with, read from the generated runtime configuration.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct RuntimeFacts {
    tun: bool,
    dns_mode: Option<&'static str>,
    tun_dns_hijack: bool,
    /// A port that accepts HTTP proxy requests (the mixed port, else the HTTP port).
    http: Option<u16>,
    /// A port that accepts SOCKS5 (the mixed port, else the SOCKS port).
    socks: Option<u16>,
}

fn parse_runtime_facts(config: &Value) -> RuntimeFacts {
    let port = |key: &str| {
        config
            .get(key)
            .and_then(Value::as_u64)
            .and_then(|port| u16::try_from(port).ok())
            .filter(|port| *port > 0)
    };
    RuntimeFacts {
        tun: config["tun"]["enable"] == true,
        dns_mode: Some(if config["dns"]["enable"] != true {
            "off"
        } else {
            match config["dns"]["enhanced-mode"].as_str() {
                Some("fake-ip") => "fake-ip",
                Some("redir-host") => "redir-host",
                _ => "enabled",
            }
        }),
        tun_dns_hijack: config["tun"]["enable"] == true
            && config["tun"]["dns-hijack"].as_array().is_some_and(|rules| !rules.is_empty()),
        http: port("mixed-port").or_else(|| port("port")),
        socks: port("mixed-port").or_else(|| port("socks-port")),
    }
}

/// The interface polls status every two seconds. Both files it depends on grow to megabytes once
/// a subscription is inlined, so their derived facts are kept until the file changes on disk.
struct DiskFacts {
    runtime: Option<(Stamp, RuntimeFacts)>,
    scope: Option<(Stamp, String)>,
}

static DISK_FACTS: Mutex<DiskFacts> = Mutex::new(DiskFacts {
    runtime: None,
    scope: None,
});

fn runtime_facts(dir: &Path) -> RuntimeFacts {
    let path = dir.join("routepilot-validated.json");
    let Some(current) = stamp(&path) else {
        return RuntimeFacts::default();
    };
    if let Ok(cache) = DISK_FACTS.lock() {
        if let Some((seen, facts)) = cache.runtime {
            if seen == current {
                return facts;
            }
        }
    }
    let facts = fs::read(&path)
        .ok()
        .and_then(|data| serde_json::from_slice::<Value>(&data).ok())
        .map(|config| parse_runtime_facts(&config))
        .unwrap_or_default();
    if let Ok(mut cache) = DISK_FACTS.lock() {
        cache.runtime = Some((current, facts));
    }
    facts
}

fn configured_tun_scope(dir: &Path) -> String {
    let Some(current) = stamp(&dir.join("mihomo.json")) else {
        return "all".into();
    };
    if let Ok(cache) = DISK_FACTS.lock() {
        if let Some((seen, scope)) = &cache.scope {
            if *seen == current {
                return scope.clone();
            }
        }
    }
    let scope = configured_profile(dir)
        .map(|config| profile::tun_scope(&config).to_owned())
        .unwrap_or_else(|_| "all".into());
    if let Ok(mut cache) = DISK_FACTS.lock() {
        cache.scope = Some((current, scope.clone()));
    }
    scope
}

fn http_port(dir: &Path) -> Option<u16> {
    runtime_facts(dir).http
}

fn status(dir: &Path, child: &mut Option<CoreProcess>) -> Result<CoreStatus, String> {
    let is_running = running(child)?;
    let facts = runtime_facts(dir);
    Ok(CoreStatus {
        app_data: dir.display().to_string(),
        platform: platform_name(),
        available: core_binary(dir).is_some(),
        configured: dir.join("mihomo.json").is_file(),
        running: is_running,
        tun: is_running && facts.tun,
        tun_scope: configured_tun_scope(dir),
        selected_tun_available: selected_tun_available(dir),
        system_proxy: system_proxy::is_owned_cached(dir)?,
        http_port: facts.http,
        dns_mode: facts.dns_mode.filter(|_| is_running),
        tun_dns_hijack: is_running && facts.tun_dns_hijack,
    })
}

fn validate_config(input: &str) -> Result<Vec<u16>, String> {
    let root: Value = serde_json::from_str(input).map_err(|err| err.to_string())?;
    let config = root
        .as_object()
        .ok_or("Expected a JSON configuration object")?;
    for key in [
        "listeners",
        "external-controller",
        "external-controller-tls",
        "external-controller-pipe",
        "external-controller-unix",
        "external-ui",
        "redir-port",
        "tproxy-port",
        "iptables",
        "experimental",
    ] {
        if config.contains_key(key) {
            return Err(format!(
                "{key} is outside the local listener verification scope"
            ));
        }
    }
    if let Some(dns) = config.get("dns") {
        if !dns.is_object() {
            return Err("Invalid dns configuration object".into());
        }
    }
    if config
        .get("tun")
        .is_some_and(|tun| tun.get("enable") != Some(&Value::Bool(false)))
    {
        return Err("TUN must be disabled in the local listener verification".into());
    }
    if config
        .get("allow-lan")
        .is_some_and(|value| value != &Value::Bool(false))
        || config
            .get("bind-address")
            .is_some_and(|value| value.as_str() != Some("127.0.0.1"))
    {
        return Err("Only loopback listeners are supported in this verification".into());
    }
    let mut ports = Vec::new();
    for key in ["port", "socks-port", "mixed-port"] {
        if let Some(value) = config.get(key) {
            let port = value
                .as_u64()
                .filter(|port| *port <= 65535)
                .ok_or_else(|| format!("Invalid {key}"))?;
            if port > 0 {
                if ports.contains(&(port as u16)) {
                    return Err("Proxy ports must be distinct".into());
                }
                ports.push(port as u16);
            }
        }
    }
    if ports.is_empty() {
        return Err("Configure at least one local proxy port".into());
    }
    for binding in fixed_socks::bindings(&root)? {
        if binding.port == 0 || ports.contains(&binding.port) {
            return Err(format!("固定 SOCKS5 端口 {} 无效或与其他监听端口重复。", binding.port));
        }
        ports.push(binding.port);
    }
    Ok(ports)
}

fn sanitize_imported_config(input: &str) -> Result<Value, String> {
    let mut root: Value = serde_json::from_str(input)
        .or_else(|_| serde_yaml_ng::from_str::<Value>(input))
        .map_err(|err| format!("配置解析失败（支持 JSON / YAML）：{err}"))?;
    let map = root
        .as_object_mut()
        .ok_or("配置文件顶层必须为对象（Mapping / JSON Object）。")?;
    for key in [
        "listeners",
        "external-controller",
        "external-controller-tls",
        "external-controller-pipe",
        "external-controller-unix",
        "external-ui",
        "secret",
        "redir-port",
        "tproxy-port",
        "iptables",
        "experimental",
    ] {
        map.remove(key);
    }
    map.insert("allow-lan".into(), Value::Bool(false));
    map.insert("bind-address".into(), Value::String("127.0.0.1".into()));
    if map.contains_key("tun") {
        map.insert("tun".into(), serde_json::json!({ "enable": false }));
    }
    let has_port = ["port", "socks-port", "mixed-port"]
        .iter()
        .any(|k| map.get(*k).and_then(Value::as_u64).is_some_and(|p| p > 0));
    if !has_port {
        map.insert("mixed-port".into(), serde_json::json!(7890));
    }
    Ok(root)
}

#[tauri::command]
async fn core_status(app: AppHandle) -> Result<CoreStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let state = app.state::<Core>();
        let mut process = state.0.lock().map_err(|err| err.to_string())?;
        if !running(&mut process)? {
            system_proxy::restore(&dir)?;
        }
        status(&dir, &mut process)
    })
    .await
    .map_err(|err| err.to_string())?
}

#[tauri::command]
async fn start_local_core(app: AppHandle) -> Result<CoreStatus, String> {
    tauri::async_runtime::spawn_blocking(move || start_core(&app, false))
        .await
        .map_err(|err| err.to_string())?
}

#[tauri::command]
async fn start_global_tun(app: AppHandle) -> Result<CoreStatus, String> {
    tauri::async_runtime::spawn_blocking(move || start_core(&app, true))
        .await
        .map_err(|err| err.to_string())?
}

fn start_core(app: &AppHandle, tun: bool) -> Result<CoreStatus, String> {
    require_core_access(app)?;
    let dir = core_dir(app)?;
    let state = app.state::<Core>();
    let mut process = state.0.lock().map_err(|err| err.to_string())?;
    let previous = status(&dir, &mut process)?;
    if previous.running {
        return Ok(previous);
    }
    if !previous.available || !previous.configured {
        return Err("代理服务尚未准备好。".into());
    }
    let config = dir.join("mihomo.json");
    let contents = fs::read_to_string(&config).map_err(|err| err.to_string())?;
    let ports = validate_config(&contents)?;
    let mut reservations = Vec::new();
    for &port in &ports {
        reservations.push(TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)).map_err(|err| {
            eprintln!("Local port {port} is unavailable: {err}");
            format!("本地代理端口 {port} 无法监听，请在设置中更换端口。")
        })?);
    }
    let configured: Value = serde_json::from_str(&contents).map_err(|err| err.to_string())?;
    for binding in fixed_socks::bindings(&configured)? {
        fixed_socks::check_udp_port(binding.port)?;
    }
    let mut normalized = runtime_config(&configured, tun)?;
    normalized["bind-address"] = Value::String("127.0.0.1".into());
    normalized["allow-lan"] = Value::Bool(false);
    if normalized.get("profile").is_none() {
        normalized["profile"] = serde_json::json!({});
    }
    if let Some(settings) = normalized["profile"].as_object_mut() {
        settings.insert("store-selected".into(), Value::Bool(true));
    }
    if tun {
        if profile::tun_scope(&configured) == "selected" && !selected_tun_available(&dir) {
            return Err("指定软件 TUN 需要 Windows x64 和随安装包提供的签名驱动。".into());
        }
        normalized["tun"] = tun_config(&configured)?;
    }
    let management = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|err| err.to_string())?;
    let endpoint = management.local_addr().map_err(|err| err.to_string())?;
    let probe = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|err| err.to_string())?;
    let probe_port = probe.local_addr().map_err(|err| err.to_string())?.port();
    let mut secret = [0_u8; 32];
    getrandom::fill(&mut secret).map_err(|err| err.to_string())?;
    let token = secret
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let controller = Controller::new(endpoint, token.clone(), probe_port)?;
    controller.add_probe_listener(&mut normalized)?;
    normalized["external-controller"] = Value::String(endpoint.to_string());
    normalized["secret"] = Value::String(token);
    let preview = dir.join("routepilot-validated.json");
    let runtime = normalized.to_string();
    fs::write(&preview, &runtime).map_err(|err| err.to_string())?;
    drop(reservations);
    drop(management);
    drop(probe);
    *process = Some(if tun {
        CoreProcess::Tun(tun_worker::Worker::launch(&dir, runtime.as_bytes())?)
    } else {
        #[cfg(target_os = "macos")]
        let managed = Command::new(std::env::current_exe().map_err(|e| e.to_string())?)
            .arg("--routepilot-local-worker").arg(&dir).stdin(Stdio::piped())
            .spawn().map_err(|e| e.to_string())?;
        #[cfg(not(target_os = "macos"))]
        let managed = spawn_local_core(&dir).map_err(|e| e.to_string())?;
        CoreProcess::Local(managed)
    });
    let deadline = Instant::now() + Duration::from_secs(if tun { 12 } else { 3 });
    while Instant::now() < deadline {
        if !running(&mut process)? {
            return Err("代理服务启动失败，请重试。".into());
        }
        if ports
            .iter()
            .chain(std::iter::once(&endpoint.port()))
            .chain(std::iter::once(&probe_port))
            .all(|port| {
                TcpStream::connect_timeout(
                    &SocketAddrV4::new(Ipv4Addr::LOCALHOST, *port).into(),
                    Duration::from_millis(100),
                )
                .is_ok()
            })
        {
            if tun {
                let ready = tauri::async_runtime::block_on(controller.request(
                    reqwest::Method::GET,
                    &["configs"],
                    &[],
                    None,
                ))
                .is_ok_and(|config| tun_matches(&config["tun"], &normalized["tun"]));
                if !ready {
                    thread::sleep(Duration::from_millis(120));
                    continue;
                }
            }
            *app.state::<LiveController>()
                .0
                .lock()
                .map_err(|err| err.to_string())? = Some(controller.clone());
            let handle = app.clone();
            tauri::async_runtime::spawn(async move {
                if let Ok(response) = controller.log_stream().await {
                    connection_log::collect(handle, response).await;
                }
            });
            return status(&dir, &mut process);
        }
        thread::sleep(Duration::from_millis(60));
    }
    terminate(&mut process)?;
    Err(if tun {
        "TUN 启动失败，请重试。"
    } else {
        "代理服务启动失败，请重试。"
    }
    .into())
}

fn spawn_local_core(dir: &Path) -> std::io::Result<tun_worker::ManagedChild> {
    let log = fs::File::create(dir.join("mihomo.log"))?;
    let mut command = mihomo_command(dir);
    command.arg("-f").arg(dir.join("routepilot-validated.json"))
        .stdin(Stdio::null()).stderr(log.try_clone()?).stdout(log);
    tun_worker::spawn_managed_core(command)
}

#[cfg(target_os = "macos")]
fn local_worker(dir: &Path) -> std::io::Result<()> {
    use std::io::Read;
    use std::sync::mpsc::{channel, RecvTimeoutError};
    let mut core = spawn_local_core(dir)?;
    // The desktop owns the only writer. Even SIGKILL closes it, allowing this
    // process to reap its own child without persisting or guessing any PIDs.
    let (tx, rx) = channel();
    thread::spawn(move || {
        let _ = std::io::stdin().read(&mut [0]);
        let _ = tx.send(());
    });
    while rx.recv_timeout(Duration::from_millis(200)) == Err(RecvTimeoutError::Timeout) {
        if core.try_wait()?.is_some() { break; }
    }
    core.terminate()?;
    let lock = fs::File::options().read(true).write(true).open(dir.join("routepilot.lock"))?;
    if lock.try_lock().is_ok() {
        // When the desktop is alive it handles recovery under its existing lock.
        system_proxy::restore(dir).map_err(std::io::Error::other)?;
    }
    Ok(())
}

fn selected_tun_available(dir: &Path) -> bool {
    cfg!(all(windows, target_arch = "x86_64"))
        && core_binary(dir).is_some_and(|binary| {
            binary.parent().is_some_and(|folder| {
                folder.join("WinDivert.dll").is_file() && folder.join("WinDivert64.sys").is_file()
            })
        })
}

fn tun_config(configured: &Value) -> Result<Value, String> {
    let mut tun = runtime_tuning::tun_inbound();
    if profile::tun_scope(configured) != "selected" {
        return Ok(tun);
    }
    if !cfg!(all(windows, target_arch = "x86_64")) {
        return Err("当前平台支持全局 TUN。指定软件 TUN 需要 Windows x64。".into());
    }
    tun["stack"] = serde_json::json!("gvisor");
    tun["auto-route"] = serde_json::json!(false);
    tun["auto-detect-interface"] = serde_json::json!(false);
    tun["windows-process-capture"] = serde_json::json!(true);
    tun["windows-process-paths"] = serde_json::json!(profile::selected_tun_paths(configured));
    Ok(tun)
}

fn tun_matches(actual: &Value, expected: &Value) -> bool {
    if actual["enable"] != expected["enable"] {
        return false;
    }
    let selected = expected["windows-process-capture"] == true;
    if (actual["windows-process-capture"] == true) != selected {
        return false;
    }
    if !selected {
        return true;
    }
    let paths = |value: &Value| {
        value["windows-process-paths"].as_array().into_iter().flatten()
            .filter_map(Value::as_str).map(str::to_owned)
            .collect::<std::collections::BTreeSet<_>>()
    };
    paths(actual) == paths(expected) && actual["auto-route"] == false
}

/// The configuration Mihomo actually runs: the saved profile narrowed to the active subscription,
/// plus runtime defaults. Starting, hot-reloading and offline validation all go through here so
/// an edit made while the core runs cannot drop a setting that start-up added.
fn runtime_config(configured: &Value, tun: bool) -> Result<Value, String> {
    let mut runtime = profile::effective_config(configured);
    if tun {
        if let Some(map) = runtime.as_object_mut() {
            map.entry("dns").or_insert_with(|| {
                serde_json::json!({
                    "enable": true,
                    "enhanced-mode": "fake-ip",
                    "nameserver": ["223.5.5.5", "1.1.1.1"],
                })
            });
            map.entry("sniffer")
                .or_insert_with(runtime_tuning::tun_sniffer);
        }
    }
    fixed_socks::apply(configured, &mut runtime)?;
    Ok(runtime)
}

fn terminate(process: &mut Option<CoreProcess>) -> Result<(), String> {
    if running(process)? {
        match process.as_mut().expect("a running process is present") {
            CoreProcess::Local(managed) => {
                #[cfg(target_os = "macos")]
                managed.wait().map_err(|err| err.to_string())?;
                #[cfg(not(target_os = "macos"))]
                managed.terminate().map_err(|err| err.to_string())?;
            }
            CoreProcess::Tun(worker) => worker.stop().map_err(|err| err.to_string())?,
        }
        *process = None;
    }
    Ok(())
}

#[tauri::command]
async fn stop_local_core(app: AppHandle) -> Result<CoreStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let state = app.state::<Core>();
        let mut process = state.0.lock().map_err(|err| err.to_string())?;
        system_proxy::restore(&dir)?;
        terminate(&mut process)?;
        *app.state::<LiveController>()
            .0
            .lock()
            .map_err(|err| err.to_string())? = None;
        status(&dir, &mut process)
    })
    .await
    .map_err(|err| err.to_string())?
}

#[tauri::command]
async fn import_core_config(app: AppHandle, content: String, expected: Option<String>) -> Result<CoreStatus, String> {
    if content.len() > 4 * 1024 * 1024 {
        return Err("配置文件不能超过 4 MiB。".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let content = content.trim_start_matches('\u{feff}');
        let mut config = sanitize_imported_config(content)?;
        if expected.is_none() {
            // External profiles cannot opt the user into additional listeners.
            config.as_object_mut().unwrap().remove(fixed_socks::KEY);
        }
        let normalized = serde_json::to_string(&config).map_err(|err| err.to_string())?;
        validate_config(&normalized)?;
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let state = app.state::<Core>();
        let mut process = state.0.lock().map_err(|err| err.to_string())?;
        if running(&mut process)? {
            return Err("请停止代理服务后再替换完整配置。".into());
        }
        if let Some(expected) = expected {
            if serde_yaml_ng::to_string(&configured_profile(&dir)?).map_err(|e| e.to_string())? != expected {
                return Err("配置已更改，请重新打开编辑器。".into());
            }
        }
        validate_with_core(&dir, &config)?;
        system_proxy::restore(&dir)?;
        save_profile(&dir, &config)?;
        status(&dir, &mut process)
    })
    .await
    .map_err(|err| err.to_string())?
}

fn configured_profile(dir: &Path) -> Result<Value, String> {
    let path = dir.join("mihomo.json");
    let content = match fs::read_to_string(&path) {
        Ok(content) => content,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let mut example: Value =
                serde_json::from_str(include_str!("../../scripts/mihomo-loopback-example.json"))
                    .map_err(|err| err.to_string())?;
            example["routepilot-created"] = Value::Bool(true);
            example["mode"] = Value::String("global".into());
            return Ok(example);
        }
        Err(err) => return Err(err.to_string()),
    };
    serde_json::from_str(&content).map_err(|err| err.to_string())
}

fn log_tail(mut reader: impl std::io::Read + std::io::Seek) -> std::io::Result<String> {
    use std::io::{Read, SeekFrom};
    const LIMIT: u64 = 64 * 1024;
    let end = reader.seek(SeekFrom::End(0))?;
    let start = end.saturating_sub(LIMIT);
    reader.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::new();
    reader.take(LIMIT).read_to_end(&mut bytes)?;
    let text = String::from_utf8_lossy(&bytes);
    let mut lines: Vec<_> = text.lines().rev().take(200).collect();
    lines.reverse();
    Ok(lines.join("\n"))
}

#[tauri::command]
async fn core_log_tail(app: AppHandle) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let path = core_dir(&app)?.join("mihomo.log");
        match fs::File::open(path) {
            Ok(file) => log_tail(file).map_err(|err| err.to_string()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
            Err(err) => Err(err.to_string()),
        }
    }).await.map_err(|err| err.to_string())?
}

#[tauri::command]
async fn choose_program_path() -> Result<Option<String>, String> {
    let Some(file) = rfd::AsyncFileDialog::new().set_title("选择可执行文件").pick_file().await else {
        return Ok(None);
    };
    let path = file.path();
    #[cfg(target_os = "macos")]
    if path.extension().is_some_and(|e| e == "app") {
        let output = std::process::Command::new("/usr/bin/plutil")
            .args(["-extract", "CFBundleExecutable", "raw", "-o", "-"])
            .arg(path.join("Contents/Info.plist")).output().map_err(|e| e.to_string())?;
        let name = String::from_utf8_lossy(&output.stdout);
        let executable = path.join("Contents/MacOS").join(name.trim());
        if !output.status.success() || !executable.is_file() { return Err("无法读取应用主程序路径".into()); }
        return Ok(Some(executable.to_string_lossy().into_owned()));
    }
    Ok(Some(path.to_string_lossy().into_owned()))
}

#[tauri::command]
async fn configured_profile_summary(app: AppHandle) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let state = app.state::<Core>();
        let mut process = state.0.lock().map_err(|err| err.to_string())?;
        Ok(serde_json::json!({
            "profile": profile::summary(&configured_profile(&dir)?),
            "running": running(&mut process)?
        }))
    })
    .await
    .map_err(|err| err.to_string())?
}

fn subscription_cache_path(dir: &Path, provider: &Value) -> Option<PathBuf> {
    let path = provider["path"]
        .as_str()
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            if provider["type"] != "http" {
                return None;
            }
            let url = provider["url"].as_str()?;
            Some(Path::new("proxies").join(format!("{:x}", md5::compute(url.as_bytes()))))
        })?;
    let root = dir.canonicalize().ok()?;
    let path = dir.join(path).canonicalize().ok()?;
    (path.starts_with(&root) && path.is_file()).then_some(path)
}

fn subscription_usage(header: &str) -> Value {
    let mut values = serde_json::Map::new();
    for field in header.split(';') {
        let Some((key, value)) = field.split_once('=') else {
            continue;
        };
        let key = match key.trim().to_ascii_lowercase().as_str() {
            "upload" => "Upload",
            "download" => "Download",
            "total" => "Total",
            "expire" => "Expire",
            _ => continue,
        };
        if let Ok(value) = value.trim().parse::<u64>() {
            values.insert(key.into(), value.into());
        }
    }
    Value::Object(values)
}

#[tauri::command]
async fn subscription_card_metadata(app: AppHandle, name: String) -> Result<Value, String> {
    let (provider, cached_date, cached_nodes) = tauri::async_runtime::spawn_blocking(move || {
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let config = configured_profile(&dir)?;
        let provider = config["proxy-providers"]
            .get(&name)
            .cloned()
            .ok_or("订阅已移除。")?;
        let cached = subscription_cache_path(&dir, &provider)
            .and_then(|path| fs::metadata(path).ok()?.modified().ok());
        let read_local = provider["type"] != "http" || provider["url"].as_str().is_some_and(|url| url.starts_with("http://"));
        let nodes = if read_local { Some(cached_provider_nodes(&dir, &provider)?) } else { None };
        Ok::<_, String>((provider, cached, nodes))
    })
    .await
    .map_err(|error| error.to_string())??;
    let mut updated = cached_date;
    let mut usage = Value::Null;
    let fetch_metadata = cached_nodes.is_none();
    let mut nodes = cached_nodes.unwrap_or(Value::Null);
    let mut error = None;
    // Imported configurations can also use HTTP sources. Mihomo owns that download;
    // show the local copy just as we do for file providers.
    if fetch_metadata {
        let url = provider["url"]
            .as_str()
            .and_then(|url| reqwest::Url::parse(url).ok())
            .filter(|url| {
                url.scheme() == "https" && url.username().is_empty() && url.password().is_none()
            })
            .ok_or("订阅地址无效。")?;
        let client = reqwest::Client::builder()
            .https_only(true)
            .no_proxy()
            .referer(false)
            .timeout(Duration::from_secs(8))
            .user_agent("Clash.Meta RoutePilot")
            .build()
            .map_err(|_| "暂时无法读取订阅信息。")?;
        match client.get(url).send().await {
            Ok(mut response) if response.status().is_success() => {
                if let Some(header) = response
                    .headers()
                    .get("subscription-userinfo")
                    .and_then(|value| value.to_str().ok())
                {
                    usage = subscription_usage(header);
                }
                const LIMIT: usize = 4 * 1024 * 1024;
                let mut body = Vec::new();
                loop {
                    match response.chunk().await {
                        Ok(Some(chunk)) if body.len() + chunk.len() <= LIMIT => {
                            body.extend_from_slice(&chunk)
                        }
                        Ok(Some(_)) => {
                            error = Some("订阅内容过大");
                            break;
                        }
                        Ok(None) => {
                            nodes = tauri::async_runtime::spawn_blocking(move || {
                                std::str::from_utf8(&body)
                                    .ok()
                                    .map(profile::subscription_metadata)
                                    .unwrap_or(Value::Null)
                            })
                            .await
                            .unwrap_or(Value::Null);
                            if nodes.as_array().is_some_and(|nodes| !nodes.is_empty()) {
                                updated = Some(std::time::SystemTime::now());
                            } else {
                                error = Some("订阅未返回节点");
                            }
                            break;
                        }
                        Err(_) => {
                            error = Some("订阅下载中断");
                            break;
                        }
                    }
                }
            }
            Ok(response) => {
                error = Some(match response.status().as_u16() {
                    401 | 403 => "订阅访问被拒绝",
                    404 | 410 => "订阅地址已失效",
                    _ => "订阅读取失败",
                })
            }
            Err(_) => error = Some("订阅服务器无法连接"),
        }
    }
    let updated_at = updated
        .and_then(|date| date.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs());
    Ok(
        serde_json::json!({ "updatedAt": updated_at, "usage": usage, "nodes": nodes, "error": error }),
    )
}

#[tauri::command]
async fn subscription_nodes(app: AppHandle, name: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let config = configured_profile(&dir)?;
        let provider = &config["proxy-providers"][&name];
        cached_provider_nodes(&dir, provider)
    })
    .await
    .map_err(|err| err.to_string())?
}

fn cached_provider_nodes(dir: &Path, provider: &Value) -> Result<Value, String> {
    if let Some(nodes) = provider["payload"].as_array() {
        return Ok(profile::node_metadata(nodes));
    }
    let Some(path) = subscription_cache_path(dir, provider) else {
        return Ok(Value::Null);
    };
    use std::io::Read;
    const LIMIT: u64 = 4 * 1024 * 1024;
    let mut contents = String::new();
    fs::File::open(path)
        .map_err(|err| err.to_string())?
        .take(LIMIT + 1)
        .read_to_string(&mut contents)
        .map_err(|err| err.to_string())?;
    Ok(if contents.len() as u64 > LIMIT {
        Value::Null
    } else {
        profile::subscription_metadata(&contents)
    })
}

fn save_profile(dir: &Path, config: &Value) -> Result<(), String> {
    let contents = serde_json::to_string_pretty(config).map_err(|err| err.to_string())?;
    validate_config(&contents)?;
    let temporary = dir.join("mihomo.json.tmp");
    fs::write(&temporary, contents).map_err(|err| err.to_string())?;
    fs::rename(temporary, dir.join("mihomo.json")).map_err(|err| err.to_string())?;
    Ok(())
}

fn validate_with_core(dir: &Path, config: &Value) -> Result<(), String> {
    let runtime = runtime_config(config, false)?;
    if core_binary(dir).is_none() {
        return Ok(());
    }
    let path = dir.join("routepilot-profile-check.json");
    fs::write(&path, runtime.to_string()).map_err(|err| err.to_string())?;
    let result = (|| {
        let mut child = mihomo_command(dir)
            .arg("-t")
            .arg("-f")
            .arg(&path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|err| err.to_string())?;
        let deadline = Instant::now() + Duration::from_secs(12);
        while Instant::now() < deadline {
            if let Some(status) = child.try_wait().map_err(|err| err.to_string())? {
                return if status.success() {
                    Ok(())
                } else {
                    Err("无法读取配置，请检查规则和订阅格式。".into())
                };
            }
            thread::sleep(Duration::from_millis(40));
        }
        let _ = child.kill();
        let _ = child.wait();
        Err("配置校验超时，请重试。".into())
    })();
    let _ = fs::remove_file(path);
    result
}

fn update_profile(
    app: &AppHandle,
    validate_offline: bool,
    mutate: impl FnOnce(&mut Value, &Path, bool) -> Result<(), String>,
) -> Result<Value, String> {
    require_core_access(app)?;
    let dir = core_dir(app)?;
    let state = app.state::<Core>();
    let mut process = state.0.lock().map_err(|err| err.to_string())?;
    let is_running = running(&mut process)?;
    let original = configured_profile(&dir)?;
    let mut config = original.clone();
    mutate(&mut config, &dir, !dir.join("mihomo.json").exists())?;
    if config != original || !dir.join("mihomo.json").exists() {
        // A core reload can report success even if a new listener could not bind.
        let previous_bindings = fixed_socks::bindings(&original)?;
        let new_ports: Vec<_> = fixed_socks::bindings(&config)?.into_iter()
            .map(|b| b.port).filter(|port| !previous_bindings.iter().any(|old| old.port == *port)).collect();
        for &port in &new_ports {
            fixed_socks::check_udp_port(port)?;
            TcpListener::bind((Ipv4Addr::LOCALHOST, port))
                .map_err(|_| format!("本地端口 {port} 无法监听，请选择其他端口。"))?;
        }
        if is_running {
            if ["port", "mixed-port", "socks-port"]
                .iter()
                .any(|key| config.get(key) != original.get(key))
            {
                let mut ports_only = original.clone();
                for key in listener_ports::KEYS {
                    if let Some(value) = config.get(key) { ports_only[key] = value.clone(); }
                    else { ports_only.as_object_mut().unwrap().remove(key); }
                }
                if ports_only != config {
                    return Err("请单独保存监听端口，再修改其他配置。".into());
                }
                validate_config(&config.to_string())?;
                let controller = mihomo_api::take(&app.state::<LiveController>())?;
                tauri::async_runtime::block_on(listener_ports::update(&dir, &controller, &config))?;
                return Ok(profile::summary(&config));
            }
            let controller = mihomo_api::take(&app.state::<LiveController>())?;
            let validated: Value = serde_json::from_slice(
                &fs::read(dir.join("routepilot-validated.json")).map_err(|err| err.to_string())?,
            )
            .map_err(|err| err.to_string())?;
            let active_tun = validated["tun"]["enable"] == true;
            let previous_tun = active_tun.then(|| tun_config(&original)).transpose()?;
            let next_tun = active_tun.then(|| tun_config(&config)).transpose()?;
            if next_tun.as_ref().is_some_and(|value| value["windows-process-capture"] == true)
                && !selected_tun_available(&dir)
            {
                return Err("未找到指定软件 TUN 的签名驱动。".into());
            }
            let tun_changed = previous_tun != next_tun;
            let prepared = serde_json::to_string_pretty(&config).map_err(|err| err.to_string())?;
            validate_config(&prepared)?;
            let temporary = dir.join("mihomo.json.tmp");
            let mode_changed = config.get("mode") != original.get("mode");
            // Mihomo supports PATCH for these fields. Unified delay and providers need a reload.
            let patch_key = ["mode", "ipv6", "tcp-concurrent", "log-level"].into_iter().find(|&key| {
                if tun_changed || config.get(key) == original.get(key) {
                    return false;
                }
                let mut previous = original.clone();
                previous[key] = config[key].clone();
                previous == config
            });
            return tauri::async_runtime::block_on(async {
                let _lock = if patch_key.is_some() {
                    None
                } else {
                    Some(controller.probe_lock.lock().await)
                };
                let get = controller
                    .request(reqwest::Method::GET, &["configs"], &[], None)
                    .await?;
                let reload = |raw: &Value, restoring: bool| {
                    if let Some(key) = patch_key {
                        let value = if restoring { &get[key] } else { &raw[key] };
                        return Ok(controller.request(
                            reqwest::Method::PATCH,
                            &["configs"],
                            &[],
                            Some(serde_json::json!({(key):value})),
                        ));
                    }
                    let mut runtime = runtime_config(raw, active_tun)?;
                    for key in [
                        "bind-address",
                        "allow-lan",
                        "external-controller",
                        "secret",
                        "profile",
                    ] {
                        if let Some(value) = validated.get(key) {
                            runtime[key] = value.clone();
                        }
                    }
                    if let Some(tun) = if restoring { &previous_tun } else { &next_tun } {
                        runtime["tun"] = tun.clone();
                    }
                    if restoring || !mode_changed {
                        runtime["mode"] = get["mode"].clone();
                    }
                    controller.add_probe_listener(&mut runtime).map(|()| {
                        controller.request(
                            reqwest::Method::PUT,
                            &["configs"],
                            &[("force", "true")],
                            Some(serde_json::json!({"payload":runtime.to_string()})),
                        )
                    })
                };
                let request = reload(&config, false)?;
                fs::write(&temporary, prepared).map_err(|err| err.to_string())?;
                let mut applied = request.await.map(|_| ());
                if applied.is_ok() && tun_changed {
                    applied = controller.request(reqwest::Method::GET, &["configs"], &[], None)
                        .await.and_then(|status| {
                            if tun_matches(&status["tun"], next_tun.as_ref().unwrap()) {
                                Ok(())
                            } else {
                                Err("内核未启用请求的 TUN 接管范围。".into())
                            }
                        });
                }
                if let Err(error) = applied {
                    let _ = fs::remove_file(&temporary);
                    if tun_changed {
                        let recovery = reload(&original, true)?.await;
                        return Err(match recovery {
                            Ok(_) => format!("TUN 设置未能应用，已恢复原配置：{error}"),
                            Err(err) => format!("TUN 设置未能应用，回滚失败：{error} / {err}"),
                        });
                    }
                    return Err(format!("内核未能应用配置：{error}"));
                }
                let persist = new_ports.iter().try_for_each(|port| fixed_socks::verify_listener(*port))
                    .and_then(|()| fs::rename(&temporary, dir.join("mihomo.json")));
                if let Err(error) = persist {
                    let _ = fs::remove_file(&temporary);
                    let recovery = reload(&original, true)?.await;
                    return Err(match recovery {
                        Ok(_) => format!("保存失败，已恢复原配置：{error}"),
                        Err(err) => format!("保存失败且内核回滚失败：{error} / {err}"),
                    });
                }
                Ok(profile::summary(&config))
            });
        }
        if validate_offline {
            validate_with_core(&dir, &config)?;
        }
        save_profile(&dir, &config)?;
    }
    Ok(profile::summary(&config))
}

#[tauri::command]
async fn import_subscription_link(app: AppHandle, url: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        if share_links::looks_like_share_links(&url) {
            return update_profile(&app, true, |config, _, first| {
                profile::import_node_links(config, &url, first)?;
                Ok(())
            });
        }
        update_profile(&app, true, |config, _, first| {
            profile::import_subscription(config, &url, first)?;
            profile::select_subscription(config, None)
        })
    })
    .await
    .map_err(|err| err.to_string())?
}

#[tauri::command]
async fn import_node_links(app: AppHandle, content: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        update_profile(&app, true, |config, _, first| {
            profile::import_node_links(config, &content, first)?;
            Ok(())
        })
    })
    .await
    .map_err(|err| err.to_string())?
}

fn provider_text(dir: &Path, provider: &Value) -> Result<String, String> {
    use std::io::Read;
    let path = subscription_cache_path(dir, provider).ok_or("本地没有订阅文件，请先刷新订阅。")?;
    // Only expose provider payloads. Imported configurations can point a provider at any file.
    let owned = ["routepilot-providers", "proxies"].iter()
        .filter_map(|folder| dir.join(folder).canonicalize().ok())
        .any(|root| path.starts_with(root));
    if !owned { return Err("此文件由外部配置管理，请在完整配置中编辑。".into()); }
    let mut content = String::new();
    fs::File::open(path).map_err(|e| e.to_string())?.take(4 * 1024 * 1024 + 1)
        .read_to_string(&mut content).map_err(|e| e.to_string())?;
    if content.len() > 4 * 1024 * 1024 { return Err("订阅文件超过 4 MiB。".into()); }
    Ok(content)
}

fn editable_provider_yaml(content: String) -> Result<String, String> {
    if let Ok(yaml) = serde_yaml_ng::from_str::<Value>(&content) {
        if yaml["proxies"].is_array() { return Ok(content); }
        if yaml.is_array() {
            return serde_yaml_ng::to_string(&serde_json::json!({"proxies":yaml})).map_err(|e| e.to_string());
        }
    }
    let nodes = share_links::parse_bundle(&content, true)
        .map_err(|_| "无法将此订阅转换为节点 YAML，请导入含 proxies 的文件。")?;
    serde_yaml_ng::to_string(&serde_json::json!({"proxies":nodes})).map_err(|e| e.to_string())
}

#[tauri::command]
async fn read_profile_document(app: AppHandle, name: Option<String>, payload: bool) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let config = configured_profile(&dir)?;
        let Some(name) = name else {
            return serde_yaml_ng::to_string(&config).map_err(|e| e.to_string());
        };
        let provider = &config["proxy-providers"][&name];
        match provider["type"].as_str() {
            Some("file") => provider_text(&dir, provider),
            Some("http") if payload => provider_text(&dir, provider).and_then(editable_provider_yaml),
            Some("http") => provider["url"].as_str().map(str::to_owned).ok_or("订阅地址缺失".into()),
            _ => Err("找不到可编辑的订阅。".into()),
        }
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
async fn edit_subscription_url(app: AppHandle, name: String, expected: String, url: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || update_profile(&app, true, |config, _, _| {
        let provider = &mut config["proxy-providers"][&name];
        if provider["type"] != "http" || provider["url"].as_str() != Some(expected.as_str()) {
            return Err("订阅已更改，请重新打开编辑器。".into());
        }
        let url = reqwest::Url::parse(url.trim()).map_err(|_| "订阅地址无效")?;
        if url.scheme() != "https" || url.host_str().is_none() || !url.username().is_empty() || url.password().is_some() {
            return Err("请输入有效的 HTTPS 订阅地址。".into());
        }
        provider["url"] = Value::String(url.to_string());
        Ok(())
    })).await.map_err(|e| e.to_string())?
}

fn yaml_provider_nodes(content: &str) -> Result<Value, String> {
    let yaml: Value = serde_yaml_ng::from_str(content).map_err(|e| format!("YAML 格式错误：{e}"))?;
    let nodes = yaml["proxies"].as_array().ok_or("请在 proxies 下填写节点列表。")?;
    let mut names = std::collections::HashSet::new();
    for node in nodes {
        let name = node["name"].as_str().filter(|s| !s.trim().is_empty()).ok_or("节点缺少名称。")?;
        if node["type"].as_str().is_none_or(str::is_empty) || !names.insert(name) {
            return Err("节点须有协议类型，且名称不能重复。".into());
        }
    }
    Ok(serde_json::json!({"proxies": nodes}))
}

#[tauri::command]
async fn import_subscription_file(
    app: AppHandle,
    name: String,
    content: String,
    expected: Option<String>,
    authored: Option<bool>,
) -> Result<Value, String> {
    if content.trim().is_empty() || content.len() > 4 * 1024 * 1024 || content.contains('\0') {
        return Err("请选择有效的订阅文件（最大 4 MiB）。".into());
    }
    if name.is_empty() || name.len() > 255 || name.contains([',', '\n', '\r', '/', '\\']) {
        return Err("订阅文件名无效。".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let mut created = None;
        let mut replaced = None;
        let result = update_profile(&app, true, |config, dir, first| {
            let editing = expected.is_some();
            let authoring = authored.unwrap_or(false) || editing;
            if let Some(previous) = &expected {
                let provider = &config["proxy-providers"][&name];
                if provider["type"] != "file" || provider_text(dir, provider)? != *previous {
                    return Err("订阅文件已更改，请重新打开编辑器。".into());
                }
                if previous == &content { return Ok(()); }
            }
            if authoring {
                validate_with_core(dir, &yaml_provider_nodes(&content)?)?;
            }
            if !authoring && config["proxy-providers"]
                .as_object()
                .into_iter()
                .flat_map(|items| items.values())
                .filter_map(|item| item["path"].as_str())
                .filter(|path| path.starts_with("./routepilot-providers/") && !path.contains(".."))
                .any(|path| fs::read_to_string(dir.join(path)).is_ok_and(|data| data == content))
            {
                return Ok(());
            }
            let mut random = [0_u8; 16];
            getrandom::fill(&mut random).map_err(|err| err.to_string())?;
            let id: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
            fs::create_dir_all(dir.join("routepilot-providers")).map_err(|err| err.to_string())?;
            let relative = format!("./routepilot-providers/{id}.yaml");
            let path = dir.join(&relative);
            fs::write(&path, &content).map_err(|err| err.to_string())?;
            created = Some(path);
            if editing {
                replaced = subscription_cache_path(dir, &config["proxy-providers"][&name]);
                config["proxy-providers"][&name]["path"] = Value::String(relative);
                return Ok(());
            }
            profile::import_subscription_file(config, &name, &relative, first)?;
            profile::select_subscription(config, None)
        });
        if result.is_err() {
            if let Some(path) = created {
                let _ = fs::remove_file(path);
            }
        } else if let Some(old) = replaced {
            // A backup or a second provider may still point at the previous revision.
            let state = app.state::<Core>();
            if let Ok(_guard) = state.0.lock() {
                if let Ok(dir) = core_dir(&app) { prune_provider_revision(&dir, &old); }
            };
        }
        result
    })
    .await
    .map_err(|err| err.to_string())?
}

fn prune_provider_revision(dir: &Path, old: &Path) {
    let Some(stem) = old.file_stem().and_then(|s| s.to_str()) else { return };
    if stem.len() != 32 || !stem.bytes().all(|b| b.is_ascii_hexdigit())
        || old.extension().is_none_or(|ext| ext != "yaml")
        || old.parent() != dir.join("routepilot-providers").canonicalize().ok().as_deref() {
        return;
    }
    for filename in ["mihomo.json", profile_backup::FILENAME] {
        let contents = match fs::read(dir.join(filename)) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return,
        };
        let config = if filename == profile_backup::FILENAME {
            profile_backup::decode(&contents)
        } else {
            serde_json::from_slice(&contents).map_err(|err| err.to_string())
        };
        let Ok(config) = config else { return };
        if config["proxy-providers"].as_object().into_iter().flat_map(|m| m.values())
            .any(|p| subscription_cache_path(dir, p).as_deref() == Some(old)) {
            return;
        }
    }
    let _ = fs::remove_file(old);
}

#[tauri::command]
fn core_profile_backup(
    app: AppHandle,
    state: State<'_, Core>,
    restore: bool,
) -> Result<(), String> {
    require_core_access(&app)?;
    let dir = core_dir(&app)?;
    let mut process = state.0.lock().map_err(|err| err.to_string())?;
    let backup = dir.join(profile_backup::FILENAME);
    if restore {
        if running(&mut process)? {
            return Err("请先在「网络与设置」中停止内核，再恢复备份。".into());
        }
        let data = fs::read(&backup).map_err(|err| {
            if err.kind() == std::io::ErrorKind::NotFound {
                "暂无配置备份。".into()
            } else {
                err.to_string()
            }
        })?;
        let config = profile_backup::decode(&data)?;
        save_profile(&dir, &config)?;
    } else {
        let data = fs::read_to_string(dir.join("mihomo.json")).map_err(|err| {
            if err.kind() == std::io::ErrorKind::NotFound {
                "尚未生成配置。".into()
            } else {
                err.to_string()
            }
        })?;
        validate_config(&data)?;
        let temporary = dir.join("mihomo.backup.json.tmp");
        fs::write(&temporary, profile_backup::encode(&data)?).map_err(|err| err.to_string())?;
        fs::rename(temporary, backup).map_err(|err| err.to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn subscription_mapping(app: AppHandle, name: String) -> Result<Value,String> {
    require_core_access(&app)?;
    profile::subscription_preview(&configured_profile(&core_dir(&app)?)?, &name)
}

#[tauri::command]
async fn set_subscription_scope(app: AppHandle, name: Option<String>, mapping: Option<std::collections::HashMap<String,String>>) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        update_profile(&app, false, |config, _, _| {
            profile::switch_with_mapping(config, name, mapping.unwrap_or_default())
        })
    })
    .await
    .map_err(|err| err.to_string())?
}

#[tauri::command]
async fn edit_core_profile(
    app: AppHandle,
    edit: profile::Edit,
    node_pins: Option<std::collections::BTreeMap<String, String>>,
    expected_scope: Option<String>,
) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        update_profile(&app, true, |config, _, _| {
            if expected_scope.as_deref().is_some_and(|scope| {
                scope != profile::active_subscription(config).unwrap_or_default()
            }) {
                return Err("订阅配置已切换，请刷新后重试。".into());
            }
            profile::bind_subscription_nodes(config, node_pins.unwrap_or_default())?;
            profile::edit_active(config, edit)
        })
    })
    .await
    .map_err(|err| err.to_string())?
}

#[tauri::command]
async fn set_system_proxy(app: AppHandle, enabled: bool) -> Result<CoreStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let state = app.state::<Core>();
        let mut process = state.0.lock().map_err(|err| err.to_string())?;
        if enabled {
            if !running(&mut process)? {
                return Err("请先启动本地内核，再开启系统代理。".into());
            }
            let facts = runtime_facts(&dir);
            let port = facts.http.ok_or("系统代理需要 HTTP 或混合端口。")?;
            if TcpStream::connect_timeout(
                &SocketAddrV4::new(Ipv4Addr::LOCALHOST, port).into(),
                Duration::from_millis(200),
            )
            .is_err()
            {
                return Err("本地 HTTP 代理端口尚未就绪。".into());
            }
            system_proxy::enable(&dir, port, facts.socks)?;
        } else {
            system_proxy::restore(&dir)?;
        }
        status(&dir, &mut process)
    })
    .await
    .map_err(|err| err.to_string())?
}

fn proxy_client(app: &AppHandle, state: &Core) -> Result<reqwest::Client, String> {
    require_core_access(app)?;
    let dir = core_dir(app)?;
    {
        let mut process = state.0.lock().map_err(|err| err.to_string())?;
        if !running(&mut process)? {
            return Err("代理服务未启动。".into());
        }
    }
    let port = http_port(&dir).ok_or("An HTTP or mixed port is required")?;
    let proxy =
        reqwest::Proxy::all(format!("http://127.0.0.1:{port}")).map_err(|err| err.to_string())?;
    reqwest::Client::builder()
        .proxy(proxy)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(|err| err.to_string())
}

#[tauri::command]
async fn mihomo_website_probe(
    app: AppHandle,
    state: State<'_, Core>,
    host: String,
) -> Result<Value, String> {
    if host.len() > 253
        || !host.contains('.')
        || !host
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'.')
    {
        return Err("Enter a valid website host".into());
    }
    let client = proxy_client(&app, &state)?;
    let start = Instant::now();
    let response = client
        .get(format!("https://{host}/"))
        .send()
        .await
        .map_err(|err| err.to_string())?;
    Ok(
        serde_json::json!({"ms":start.elapsed().as_millis() as u64,"status":response.status().as_u16()}),
    )
}

#[tauri::command]
async fn mihomo_exit_ip(app: AppHandle, state: State<'_, Core>) -> Result<String, String> {
    let response = proxy_client(&app, &state)?
        .get("https://api64.ipify.org?format=json")
        .send()
        .await
        .map_err(|err| err.to_string())?
        .error_for_status()
        .map_err(|err| err.to_string())?;
    let body: Value = response.json().await.map_err(|err| err.to_string())?;
    body.get("ip")
        .and_then(Value::as_str)
        .and_then(|value| value.parse::<std::net::IpAddr>().ok())
        .map(|address| address.to_string())
        .ok_or("The IP service returned an invalid address".into())
}

#[cfg(windows)]
fn read_network_details() -> Result<Value, String> {
    use std::os::windows::process::CommandExt;
    let windows = std::env::var_os("SystemRoot").ok_or("Windows installation path unavailable")?;
    let shell = PathBuf::from(windows).join("System32/WindowsPowerShell/v1.0/powershell.exe");
    let command = r#"
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$ErrorActionPreference='Stop'
$active=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
    ForEach-Object { $_.GetIPProperties() })
$addresses=@($active | ForEach-Object { $_.UnicastAddresses | ForEach-Object { $_.Address.ToString() } } | Sort-Object -Unique)
$dns=@($active | ForEach-Object { $_.DnsAddresses | ForEach-Object { $_.ToString() } } | Sort-Object -Unique)
@{addresses=$addresses;dns=$dns} | ConvertTo-Json -Compress
"#;
    let output = Command::new(shell)
        .args(["-NoProfile", "-NonInteractive", "-Command", command])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|err| err.to_string())?;
    if !output.status.success() {
        return Err("Windows IP or DNS information is unavailable".into());
    }
    serde_json::from_slice(&output.stdout).map_err(|err| err.to_string())
}

#[cfg(target_os = "macos")]
fn read_network_details() -> Result<Value, String> {
    use std::collections::BTreeSet;
    let mut addresses = BTreeSet::new();
    let mut dns = BTreeSet::new();
    if let Ok(output) = Command::new("/sbin/ifconfig").output() {
        if output.status.success() {
            for line in String::from_utf8_lossy(&output.stdout).lines() {
                let trimmed = line.trim();
                if let Some(rest) = trimmed.strip_prefix("inet ") {
                    if let Some(ip) = rest.split_whitespace().next() {
                        if !ip.starts_with("127.") {
                            addresses.insert(ip.to_owned());
                        }
                    }
                } else if let Some(rest) = trimmed.strip_prefix("inet6 ") {
                    if let Some(ip) = rest.split_whitespace().next() {
                        let clean = ip.split('%').next().unwrap_or(ip);
                        if clean != "::1" && !clean.starts_with("fe80:") {
                            addresses.insert(clean.to_owned());
                        }
                    }
                }
            }
        }
    }
    if let Ok(output) = Command::new("/usr/sbin/scutil").arg("--dns").output() {
        if output.status.success() {
            for line in String::from_utf8_lossy(&output.stdout).lines() {
                let trimmed = line.trim();
                if let Some((_, val)) = trimmed
                    .strip_prefix("nameserver[")
                    .and_then(|s| s.split_once(':'))
                {
                    let addr = val.trim();
                    if addr.parse::<std::net::IpAddr>().is_ok() {
                        dns.insert(addr.to_owned());
                    }
                }
            }
        }
    }
    Ok(serde_json::json!({
        "addresses": addresses.into_iter().collect::<Vec<_>>(),
        "dns": dns.into_iter().collect::<Vec<_>>(),
    }))
}

#[cfg(all(not(windows), not(target_os = "macos")))]
fn read_network_details() -> Result<Value, String> {
    use std::collections::BTreeSet;
    let mut addresses = BTreeSet::new();
    let mut dns = BTreeSet::new();
    if let Ok(output) = Command::new("ip").args(["-o", "addr", "show", "up"]).output() {
        if output.status.success() {
            for line in String::from_utf8_lossy(&output.stdout).lines() {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 4 && (parts[2] == "inet" || parts[2] == "inet6") {
                    let ip = parts[3].split('/').next().unwrap_or("");
                    if !ip.starts_with("127.") && ip != "::1" && !ip.starts_with("fe80:") {
                        addresses.insert(ip.to_owned());
                    }
                }
            }
        }
    }
    if let Ok(resolv) = fs::read_to_string("/etc/resolv.conf") {
        for line in resolv.lines() {
            if let Some(ip) = line.trim().strip_prefix("nameserver ") {
                let ip = ip.trim();
                if ip.parse::<std::net::IpAddr>().is_ok() {
                    dns.insert(ip.to_owned());
                }
            }
        }
    }
    Ok(serde_json::json!({
        "addresses": addresses.into_iter().collect::<Vec<_>>(),
        "dns": dns.into_iter().collect::<Vec<_>>(),
    }))
}

#[tauri::command]
async fn windows_network_details() -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(read_network_details)
        .await
        .map_err(|err| err.to_string())?
}

#[tauri::command]
async fn system_network_details() -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(read_network_details)
        .await
        .map_err(|err| err.to_string())?
}

#[tauri::command]
fn window_minimize(window: tauri::WebviewWindow) -> Result<(), String> {
    window.minimize().map_err(|err| err.to_string())
}

#[tauri::command]
fn window_toggle_maximize(window: tauri::WebviewWindow) -> Result<bool, String> {
    if window.is_maximized().map_err(|err| err.to_string())? {
        window.unmaximize().map_err(|err| err.to_string())?;
        Ok(false)
    } else {
        window.maximize().map_err(|err| err.to_string())?;
        Ok(true)
    }
}

#[tauri::command]
fn window_close(window: tauri::WebviewWindow) -> Result<(), String> {
    window.close().map_err(|err| err.to_string())
}

/// Keeps the native window appearance in step with the in-app theme. The window material on macOS
/// and the system-drawn chrome follow this setting, not the page's own colours.
#[tauri::command]
fn window_set_theme(window: tauri::WebviewWindow, theme: Option<String>) -> Result<(), String> {
    let theme = match theme.as_deref() {
        Some("dark") => Some(tauri::Theme::Dark),
        Some("light") => Some(tauri::Theme::Light),
        _ => None,
    };
    window.set_theme(theme).map_err(|err| err.to_string())
}

fn main() {
    let mut args = std::env::args_os().skip(1);
    let action = args.next();
    #[cfg(target_os = "macos")]
    if action.as_deref() == Some(std::ffi::OsStr::new("--routepilot-local-worker")) {
        let ok = args.next().is_some_and(|dir| local_worker(Path::new(&dir)).is_ok());
        std::process::exit(if ok { 0 } else { 1 });
    }
    if action.is_some_and(|arg| arg == tun_worker::ARG) {
        std::process::exit(if tun_worker::run(args).is_ok() { 0 } else { 1 });
    }
    tauri::Builder::default()
        .manage(Core::default())
        .manage(LiveController::default())
        .manage(connection_log::ConnectionLog::default())
        .setup(|app| {
            let opened = (|| -> Result<_, String> {
                let dir = core_dir(app.handle())?;
                let lock = fs::OpenOptions::new()
                    .create(true)
                    .truncate(false)
                    .read(true)
                    .write(true)
                    .open(dir.join("routepilot.lock"))
                    .map_err(|err| {
                        format!("Could not open the RoutePilot data directory: {err}")
                    })?;
                lock.try_lock().map_err(|err| {
                    format!("Could not lock the RoutePilot data directory: {err}")
                })?;
                Ok((dir, lock))
            })();
            match opened {
                Ok((dir, lock)) => {
                    app.manage(CoreAccess {
                        _lock: Some(lock),
                        error: None,
                    });
                    let handle = app.handle().clone();
                    thread::spawn(move || loop {
                        thread::sleep(Duration::from_secs(1));
                        let state = handle.state::<Core>();
                        if let Ok(mut process) = state.0.lock() {
                            if matches!(running(&mut process), Ok(false)) {
                                let _ = system_proxy::restore(&dir);
                                if let Ok(mut controller) =
                                    handle.state::<LiveController>().0.lock()
                                {
                                    *controller = None;
                                }
                            }
                        };
                    });
                }
                Err(error) => {
                    app.manage(CoreAccess {
                        _lock: None,
                        error: Some(error),
                    });
                }
            }
            #[cfg(any(target_os = "linux", target_os = "windows"))]
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_decorations(false);
            }
            tray::install(app.handle())?;
            Ok(())
        })
        .on_window_event(tray::on_window_event)
        .invoke_handler(tauri::generate_handler![
            window_minimize,
            window_toggle_maximize,
            window_close,
            window_set_theme,
            tray::update_tray_menu,
            tray::show_routepilot,
            core_status,
            start_local_core,
            start_global_tun,
            stop_local_core,
            set_system_proxy,
            import_core_config,
            choose_program_path,
            configured_profile_summary,
            core_log_tail,
            subscription_nodes,
            subscription_card_metadata,
            edit_core_profile,
            set_subscription_scope,
            subscription_mapping,
            core_profile_backup,
            import_subscription_link,
            import_node_links,
            import_subscription_file,
            read_profile_document,
            edit_subscription_url,
            connection_log::connection_log_rows,
            processes::list_running_processes,
            processes::list_process_threads,
            processes::check_process_instances,
            mihomo_api::active_routes,
            mihomo_api::mihomo_snapshot,
            mihomo_api::mihomo_delay,
            mihomo_api::mihomo_select,
            mihomo_api::mihomo_select_group,
            mihomo_api::mihomo_refresh_provider,
            mihomo_website_probe,
            mihomo_exit_ip,
            windows_network_details,
            system_network_details
        ])
        .build(tauri::generate_context!())
        .expect("failed to initialize RoutePilot")
        .run(|app, event| match event {
            RunEvent::Exit => {
                if require_core_access(app).is_ok() {
                    if let Ok(mut process) = app.state::<Core>().0.lock() {
                        if let Ok(dir) = core_dir(app) {
                            let _ = system_proxy::restore(&dir);
                        }
                        let _ = terminate(&mut process);
                    }
                }
            }
            // Closing the window only hides it to the tray, so a Dock click has to bring it back.
            #[cfg(target_os = "macos")]
            RunEvent::Reopen { .. } => {
                let _ = tray::show_routepilot(app.clone());
            }
            _ => {}
        });
}

#[cfg(test)]
mod tests {
    use super::{log_tail, parse_runtime_facts, sanitize_imported_config, subscription_usage, tun_config, validate_config};

    #[test]
    fn backup_keeps_imported_provider_revision_until_reference_is_removed() {
        use super::{fs, profile_backup, prune_provider_revision};
        let mut random = [0; 16];
        getrandom::fill(&mut random).unwrap();
        let dir = std::env::temp_dir().join(format!("routepilot-backup-{:x}", u128::from_le_bytes(random)));
        let relative = "routepilot-providers/0123456789abcdef0123456789abcdef.yaml";
        let provider = dir.join(relative);
        fs::create_dir_all(provider.parent().unwrap()).unwrap();
        fs::write(&provider, "proxies: []").unwrap();
        let provider = provider.canonicalize().unwrap();
        let config = serde_json::json!({"proxy-providers":{"imported":{"path":relative}}});
        let backup = dir.join(profile_backup::FILENAME);
        fs::write(&backup, profile_backup::encode(&config.to_string()).unwrap()).unwrap();
        prune_provider_revision(&dir, &provider);
        let kept = provider.is_file();
        fs::remove_file(backup).unwrap();
        prune_provider_revision(&dir, &provider);
        let removed = !provider.exists();
        fs::remove_dir_all(dir).unwrap();
        assert!(kept);
        assert!(removed);
    }

    #[test]
    fn tail_limits_large_logs_by_bytes_and_lines() {
        use std::io::Cursor;
        let lines = (0..300).map(|i| format!("line {i}\n")).collect::<String>();
        let tail = log_tail(Cursor::new(lines)).unwrap();
        assert_eq!(tail.lines().count(), 200);
        assert!(tail.starts_with("line 100\n"));
        assert!(tail.ends_with("line 299"));
        assert_eq!(log_tail(Cursor::new(vec![b'x'; 100_000])).unwrap().len(), 65_536);
    }

    #[test]
    fn selected_scope_never_starts_global_tun() {
        for mode in ["global", "direct", "rule"] {
            let tun = tun_config(&serde_json::json!({
                "mode": mode, "routepilot-tun-scope": "selected"
            }));
            if cfg!(all(windows, target_arch = "x86_64")) {
                let tun = tun.unwrap();
                assert_eq!(tun["auto-route"], false);
                assert_eq!(tun["windows-process-capture"], true);
            } else {
                assert!(tun.is_err());
            }
        }
    }

    #[test]
    fn dns_status_uses_the_generated_configuration() {
        let facts = parse_runtime_facts(&serde_json::json!({
            "dns":{"enable":true,"enhanced-mode":"fake-ip"},
            "tun":{"enable":true,"dns-hijack":["any:53"]}
        }));
        assert_eq!(facts.dns_mode, Some("fake-ip"));
        assert!(facts.tun_dns_hijack);
        let disabled = parse_runtime_facts(&serde_json::json!({"tun":{"dns-hijack":["any:53"]}}));
        assert_eq!(disabled.dns_mode, Some("off"));
        assert!(!disabled.tun_dns_hijack);
    }

    #[test]
    fn runtime_facts_pick_the_port_that_speaks_each_protocol() {
        let mixed = parse_runtime_facts(&serde_json::json!({
            "mixed-port": 7890, "port": 8080, "socks-port": 1080, "tun": {"enable": true}
        }));
        assert!(mixed.tun);
        assert_eq!((mixed.http, mixed.socks), (Some(7890), Some(7890)));

        let split = parse_runtime_facts(&serde_json::json!({
            "mixed-port": 0, "port": 8080, "socks-port": 1080, "tun": {"enable": false}
        }));
        assert!(!split.tun);
        assert_eq!((split.http, split.socks), (Some(8080), Some(1080)));

        let http_only = parse_runtime_facts(&serde_json::json!({"port": 8080}));
        assert_eq!((http_only.http, http_only.socks), (Some(8080), None));

        let invalid = parse_runtime_facts(&serde_json::json!({"mixed-port": 70000, "port": "x"}));
        assert_eq!((invalid.http, invalid.socks), (None, None));
    }

    #[test]
    fn accepts_third_party_yaml_or_json_with_dns_after_sanitization() {
        let yaml = r#"
mixed-port: 7890
allow-lan: true
external-controller: 0.0.0.0:9090
dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
    - 1.1.1.1
rules:
  - MATCH,DIRECT
"#;
        let sanitized = sanitize_imported_config(yaml).unwrap();
        assert_eq!(sanitized["allow-lan"], false);
        assert_eq!(sanitized["bind-address"], "127.0.0.1");
        assert!(sanitized.get("external-controller").is_none());
        assert_eq!(sanitized["dns"]["enable"], true);
        let json_str = serde_json::to_string(&sanitized).unwrap();
        assert_eq!(validate_config(&json_str).unwrap(), vec![7890]);
    }

    #[test]
    fn editable_provider_keeps_yaml_comments_and_rejects_invalid_or_partial_data() {
        let text = "# private\nproxies:\n  - {name: Proxy, type: socks5, server: 127.0.0.1, port: 1080}\n";
        assert_eq!(super::editable_provider_yaml(text.into()).unwrap(), text);
        assert_eq!(super::yaml_provider_nodes(text).unwrap()["proxies"][0]["port"], 1080);
        for invalid in ["proxies: [", "rules: []", "proxies: [{type: ss}]", "proxies: [{name: a,type: ss},{name: a,type: ss}]"] {
            assert!(super::yaml_provider_nodes(invalid).is_err());
        }
        assert!(super::editable_provider_yaml("trojan://abc@localhost:443#Test\nunknown://broken".into()).is_err());
    }

    #[test]
    fn subscription_header_keeps_valid_usage_fields() {
        assert_eq!(
            subscription_usage(
                "upload=123; download=456; total=1024; expire=2218532293; bad=secret"
            ),
            serde_json::json!({"Upload":123,"Download":456,"Total":1024,"Expire":2218532293u64})
        );
        assert_eq!(
            subscription_usage("total=bad; expire=-1"),
            serde_json::json!({})
        );
    }

    #[test]
    fn fixed_socks_ports_are_reserved_and_preserved_alongside_the_probe() {
        let mut config = serde_json::json!({"mixed-port":7890,
            "proxy-providers":{"A":{"type":"inline"}, "B":{"type":"inline"}},
            "routepilot-active-subscription":"B",
            "routepilot-fixed-socks":[{"port":19081,"node":"日本.1","provider":"A"}]});
        assert_eq!(validate_config(&config.to_string()).unwrap(), vec![7890, 19081]);
        let mut runtime = crate::runtime_config(&config, false).unwrap();
        let controller = crate::Controller::new("127.0.0.1:54321".parse().unwrap(), "test".into(), 54322).unwrap();
        controller.add_probe_listener(&mut runtime).unwrap();
        let listeners = runtime["listeners"].as_array().unwrap();
        assert_eq!(listeners.len(), 2);
        let pin = &listeners[0];
        assert_eq!(pin["listen"], "127.0.0.1");
        assert_eq!(pin["type"], "socks");
        let group = runtime["proxy-groups"].as_array().unwrap().iter().find(|g| g["name"] == pin["proxy"]).unwrap();
        assert_eq!(group["use"], serde_json::json!(["A"]));
        assert_eq!(group["filter"], r"^日本\.1$");
        assert_eq!(group["empty-fallback"], "REJECT");
        config["mixed-port"] = 19081.into();
        assert!(validate_config(&config.to_string()).is_err());
    }

    #[test]
    #[ignore = "requires MIHOMO_BIN, python3, curl and loopback sockets"]
    fn fixed_socks_real_exits() {
        use std::io::Write;
        let mut profile = serde_json::json!({"mixed-port":7890,"mode":"rule",
            "proxy-providers":{"sample":{"type":"inline","payload":[
                {"name":"JP","type":"http","server":"127.0.0.1","port":1},
                {"name":"US","type":"http","server":"127.0.0.1","port":2}]}},
            "rules":["MATCH,GLOBAL"]});
        let binding = crate::fixed_socks::Binding { port:19081, node:"JP".into(), provider:Some("sample".into()) };
        crate::profile::edit_active(&mut profile, crate::profile::Edit::FixedSocks { binding, remove:false }).unwrap();
        let runtime = crate::runtime_config(&profile, false).unwrap();
        let mut child = std::process::Command::new("python3")
            .args(["../scripts/smoke-fixed-socks.py", &std::env::var("MIHOMO_BIN").unwrap()])
            .stdin(std::process::Stdio::piped()).spawn().unwrap();
        child.stdin.take().unwrap().write_all(runtime.to_string().as_bytes()).unwrap();
        assert!(child.wait().unwrap().success());
    }

    #[test]
    fn accepts_distinct_loopback_ports() {
        assert!(validate_config(r#"{"port":7890,"socks-port":7891,"allow-lan":false}"#).is_ok());
    }

    #[test]
    fn rejects_overlapping_or_missing_ports() {
        assert!(validate_config(r#"{"port":7890,"mixed-port":7890}"#).is_err());
        assert!(validate_config(r#"{"port":0}"#).is_err());
    }

    #[test]
    fn rejects_system_capture_and_external_listeners() {
        for configuration in [
            r#"{"port":7890,"allow-lan":true}"#,
            r#"{"port":7890,"bind-address":"0.0.0.0"}"#,
            r#"{"port":7890,"tun":{"enable":true}}"#,
            r#"{"port":7890,"external-controller":"127.0.0.1:9090"}"#,
        ] {
            assert!(validate_config(configuration).is_err(), "{configuration}");
        }
    }
}
