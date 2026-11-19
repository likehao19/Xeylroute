#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod connection_log;
mod mihomo_api;
mod processes;
mod profile;
mod program_files;
mod system_proxy;
mod tray;
mod tun_worker;

use mihomo_api::{Controller, LiveController};
use serde::Serialize;
use serde_json::Value;
use std::{
    fs,
    net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream},
    os::windows::{io::OwnedHandle, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};
use tauri::{AppHandle, Manager, RunEvent, State};

const CREATE_NO_WINDOW: u32 = 0x08000000;

#[derive(Default)]
struct Core(Mutex<Option<CoreProcess>>);

enum CoreProcess {
    Local { child: Child, _job: OwnedHandle },
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

fn mihomo_command(dir: &Path) -> Command {
    let mut command = Command::new(dir.join("mihomo.exe"));
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_uppercase()
            .starts_with("CLASH_")
        {
            command.env_remove(key);
        }
    }
    command.arg("-d").arg(dir).creation_flags(CREATE_NO_WINDOW);
    command
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CoreStatus {
    app_data: String,
    available: bool,
    configured: bool,
    running: bool,
    system_proxy: bool,
    tun: bool,
    http_port: Option<u16>,
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
            CoreProcess::Local { child, .. } => child.try_wait().map(|status| status.is_none()),
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

fn http_port(dir: &Path) -> Option<u16> {
    let data = fs::read(dir.join("routepilot-validated.json")).ok()?;
    let config: Value = serde_json::from_slice(&data).ok()?;
    ["mixed-port", "port"].iter().find_map(|key| {
        config
            .get(*key)?
            .as_u64()
            .and_then(|port| u16::try_from(port).ok())
            .filter(|port| *port > 0)
    })
}

fn status(dir: &Path, child: &mut Option<CoreProcess>) -> Result<CoreStatus, String> {
    let is_running = running(child)?;
    let tun = is_running
        && fs::read(dir.join("routepilot-validated.json"))
            .ok()
            .and_then(|data| serde_json::from_slice::<Value>(&data).ok())
            .is_some_and(|config| config["tun"]["enable"] == true);
    Ok(CoreStatus {
        app_data: dir.display().to_string(),
        available: dir.join("mihomo.exe").is_file(),
        configured: dir.join("mihomo.json").is_file(),
        running: is_running,
        tun,
        system_proxy: system_proxy::is_owned(dir)?,
        http_port: http_port(dir),
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
        "dns",
        "iptables",
        "experimental",
    ] {
        if config.contains_key(key) {
            return Err(format!(
                "{key} is outside the local listener verification scope"
            ));
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
    Ok(ports)
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
    for &port in &ports {
        TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)).map_err(|err| {
            eprintln!("Local port {port} is unavailable: {err}");
            "暂时无法启动代理服务，请重试。".to_string()
        })?;
    }
    let configured: Value = serde_json::from_str(&contents).map_err(|err| err.to_string())?;
    let mut normalized = profile::runtime_profile(&configured);
    normalized["bind-address"] = Value::String("127.0.0.1".into());
    normalized["allow-lan"] = Value::Bool(false);
    if normalized.get("profile").is_none() {
        normalized["profile"] = serde_json::json!({});
    }
    if let Some(settings) = normalized["profile"].as_object_mut() {
        settings.insert("store-selected".into(), Value::Bool(true));
    }
    if tun {
        normalized["tun"] = serde_json::json!({
            "enable": true,
            "stack": "mixed",
            "auto-route": true,
            "auto-detect-interface": true,
        });
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
    drop(management);
    drop(probe);
    *process = Some(if tun {
        CoreProcess::Tun(tun_worker::Worker::launch(&dir, runtime.as_bytes())?)
    } else {
        let log = fs::File::create(dir.join("mihomo.log")).map_err(|err| err.to_string())?;
        let stderr = log.try_clone().map_err(|err| err.to_string())?;
        let mut command = mihomo_command(&dir);
        command
            .arg("-f")
            .arg(preview)
            .stdin(Stdio::null())
            .stdout(log)
            .stderr(stderr);
        let (child, job) =
            tun_worker::spawn_managed_core(command).map_err(|err| err.to_string())?;
        CoreProcess::Local { child, _job: job }
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
                .is_ok_and(|config| config["tun"]["enable"] == true);
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

fn terminate(process: &mut Option<CoreProcess>) -> Result<(), String> {
    if running(process)? {
        match process.as_mut().expect("a running process is present") {
            CoreProcess::Local { child, .. } => {
                child.kill().map_err(|err| err.to_string())?;
                child.wait().map_err(|err| err.to_string())?;
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
async fn import_core_config(app: AppHandle, content: String) -> Result<CoreStatus, String> {
    if content.len() > 4 * 1024 * 1024 {
        return Err("配置文件不能超过 4 MiB。".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let content = content.trim_start_matches('\u{feff}');
        validate_config(content)?;
        let config = serde_json::from_str(content).map_err(|err| err.to_string())?;
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let state = app.state::<Core>();
        let mut process = state.0.lock().map_err(|err| err.to_string())?;
        if running(&mut process)? {
            return Err("请停止代理服务后再替换完整配置。".into());
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
    let (provider, cached_date) = tauri::async_runtime::spawn_blocking(move || {
        require_core_access(&app)?;
        let dir = core_dir(&app)?;
        let config = configured_profile(&dir)?;
        let provider = config["proxy-providers"]
            .get(&name)
            .cloned()
            .ok_or("订阅已移除。")?;
        let cached = subscription_cache_path(&dir, &provider)
            .and_then(|path| fs::metadata(path).ok()?.modified().ok());
        Ok::<_, String>((provider, cached))
    })
    .await
    .map_err(|error| error.to_string())??;
    let mut updated = cached_date;
    let mut usage = Value::Null;
    let mut nodes = Value::Null;
    let mut error = None;
    if provider["type"] == "http" {
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
        if let Some(nodes) = provider["payload"].as_array() {
            return Ok(profile::node_metadata(nodes));
        }
        let Some(path) = subscription_cache_path(&dir, provider) else {
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
    })
    .await
    .map_err(|err| err.to_string())?
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
    if !dir.join("mihomo.exe").is_file() {
        return Ok(());
    }
    let path = dir.join("routepilot-profile-check.json");
    fs::write(&path, profile::runtime_profile(config).to_string())
        .map_err(|err| err.to_string())?;
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
        if is_running {
            if ["port", "mixed-port", "socks-port"]
                .iter()
                .any(|key| config.get(key) != original.get(key))
            {
                return Err("请停止内核后再修改监听端口。".into());
            }
            let controller = mihomo_api::take(&app.state::<LiveController>())?;
            let validated: Value = serde_json::from_slice(
                &fs::read(dir.join("routepilot-validated.json")).map_err(|err| err.to_string())?,
            )
            .map_err(|err| err.to_string())?;
            let prepared = serde_json::to_string_pretty(&config).map_err(|err| err.to_string())?;
            validate_config(&prepared)?;
            let temporary = dir.join("mihomo.json.tmp");
            fs::write(&temporary, prepared).map_err(|err| err.to_string())?;
            let mode_changed = config.get("mode") != original.get("mode");
            let mode_only = mode_changed && {
                let mut previous = original.clone();
                previous["mode"] = config["mode"].clone();
                previous == config
            };
            return tauri::async_runtime::block_on(async {
                let _lock = if mode_only {
                    None
                } else {
                    Some(controller.probe_lock.lock().await)
                };
                let get = controller
                    .request(reqwest::Method::GET, &["configs"], &[], None)
                    .await?;
                let reload = |raw: &Value, apply_mode: bool| {
                    if mode_only {
                        let mode = if apply_mode {
                            &raw["mode"]
                        } else {
                            &get["mode"]
                        };
                        return Ok(controller.request(
                            reqwest::Method::PATCH,
                            &["configs"],
                            &[],
                            Some(serde_json::json!({"mode":mode})),
                        ));
                    }
                    let mut runtime = profile::runtime_profile(raw);
                    for key in [
                        "bind-address",
                        "allow-lan",
                        "tun",
                        "external-controller",
                        "secret",
                        "profile",
                    ] {
                        if let Some(value) = validated.get(key) {
                            runtime[key] = value.clone();
                        }
                    }
                    if !apply_mode {
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
                if let Err(error) = reload(&config, mode_changed)?.await {
                    let _ = fs::remove_file(&temporary);
                    return Err(format!("内核未能应用配置：{error}"));
                }
                if let Err(error) = fs::rename(&temporary, dir.join("mihomo.json")) {
                    let recovery = reload(&original, false)?.await;
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
        update_profile(&app, true, |config, _, first| {
            profile::import_subscription(config, &url, first)?;
            profile::select_subscription(config, None)
        })
    })
    .await
    .map_err(|err| err.to_string())?
}

#[tauri::command]
async fn import_subscription_file(
    app: AppHandle,
    name: String,
    content: String,
) -> Result<Value, String> {
    let content = content.trim_start_matches('\u{feff}').trim().to_owned();
    if content.is_empty() || content.len() > 4 * 1024 * 1024 || content.contains('\0') {
        return Err("请选择有效的订阅文件（最大 4 MiB）。".into());
    }
    if name.is_empty() || name.len() > 255 || name.contains([',', '\n', '\r', '/', '\\']) {
        return Err("订阅文件名无效。".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let mut created = None;
        let result = update_profile(&app, true, |config, dir, first| {
            if config["proxy-providers"]
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
            profile::import_subscription_file(config, &name, &relative, first)?;
            profile::select_subscription(config, None)
        });
        if result.is_err() {
            if let Some(path) = created {
                let _ = fs::remove_file(path);
            }
        }
        result
    })
    .await
    .map_err(|err| err.to_string())?
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
    let backup = dir.join("mihomo.backup.json");
    if restore {
        if running(&mut process)? {
            return Err("请先关闭首页的接管总开关，再恢复配置。".into());
        }
        let data = fs::read_to_string(&backup).map_err(|err| {
            if err.kind() == std::io::ErrorKind::NotFound {
                "暂无配置备份。".into()
            } else {
                err.to_string()
            }
        })?;
        let config = serde_json::from_str(&data).map_err(|err| err.to_string())?;
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
        fs::write(&temporary, data).map_err(|err| err.to_string())?;
        fs::rename(temporary, backup).map_err(|err| err.to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn set_subscription_scope(app: AppHandle, name: Option<String>) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        update_profile(&app, false, |config, _, _| {
            profile::select_subscription(config, name)
        })
    })
    .await
    .map_err(|err| err.to_string())?
}

#[tauri::command]
async fn edit_core_profile(
    app: AppHandle,
    edit: profile::Edit,
    expected_scope: Option<String>,
) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        update_profile(&app, true, |config, _, _| {
            if expected_scope.as_deref().is_some_and(|scope| {
                scope != profile::active_subscription(config).unwrap_or_default()
            }) {
                return Err("订阅配置已切换，请刷新后重试。".into());
            }
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
            let port = http_port(&dir).ok_or("系统代理需要 HTTP 或混合端口。")?;
            if TcpStream::connect_timeout(
                &SocketAddrV4::new(Ipv4Addr::LOCALHOST, port).into(),
                Duration::from_millis(200),
            )
            .is_err()
            {
                return Err("本地 HTTP 代理端口尚未就绪。".into());
            }
            system_proxy::enable(&dir, port)?;
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

#[tauri::command]
async fn windows_network_details() -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(|| {
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
            .creation_flags(CREATE_NO_WINDOW).output().map_err(|err| err.to_string())?;
        if !output.status.success() { return Err("Windows IP or DNS information is unavailable".into()); }
        serde_json::from_slice(&output.stdout).map_err(|err| err.to_string())
    }).await.map_err(|err| err.to_string())?
}

fn main() {
    let mut args = std::env::args_os().skip(1);
    if args.next().is_some_and(|arg| arg == tun_worker::ARG) {
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
            tray::install(app.handle())?;
            Ok(())
        })
        .on_window_event(tray::on_window_event)
        .invoke_handler(tauri::generate_handler![
            tray::update_tray_menu,
            tray::show_routepilot,
            core_status,
            start_local_core,
            start_global_tun,
            stop_local_core,
            set_system_proxy,
            import_core_config,
            configured_profile_summary,
            subscription_nodes,
            subscription_card_metadata,
            edit_core_profile,
            set_subscription_scope,
            core_profile_backup,
            import_subscription_link,
            import_subscription_file,
            connection_log::connection_log_rows,
            processes::list_running_processes,
            processes::list_process_threads,
            mihomo_api::mihomo_snapshot,
            mihomo_api::mihomo_delay,
            mihomo_api::mihomo_select,
            mihomo_api::mihomo_select_group,
            mihomo_api::mihomo_refresh_provider,
            mihomo_website_probe,
            mihomo_exit_ip,
            windows_network_details
        ])
        .build(tauri::generate_context!())
        .expect("failed to initialize RoutePilot")
        .run(|app, event| {
            if matches!(event, RunEvent::Exit) && require_core_access(app).is_ok() {
                if let Ok(mut process) = app.state::<Core>().0.lock() {
                    if let Ok(dir) = core_dir(app) {
                        let _ = system_proxy::restore(&dir);
                    }
                    let _ = terminate(&mut process);
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::{subscription_usage, validate_config};

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
