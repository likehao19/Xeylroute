use serde::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::Path,
    sync::Mutex,
    time::{Duration, Instant},
};

const JOURNAL: &str = "system-proxy-recovery.json";

#[cfg(windows)]
mod platform {
    use super::*;
    use std::{
        ffi::c_void,
        mem::size_of,
        ptr::{null, null_mut},
    };
    use windows_sys::Win32::{Foundation::GlobalFree, Networking::WinInet::*};

    #[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
    pub struct ProxySettings {
        pub flags: u32,
        pub server: String,
    }

    fn options_list(options: &mut [INTERNET_PER_CONN_OPTIONW]) -> INTERNET_PER_CONN_OPTION_LISTW {
        INTERNET_PER_CONN_OPTION_LISTW {
            dwSize: size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32,
            pszConnection: null_mut(),
            dwOptionCount: options.len() as u32,
            dwOptionError: 0,
            pOptions: options.as_mut_ptr(),
        }
    }

    fn query_with_flags(flag_option: u32) -> io::Result<ProxySettings> {
        let mut flags = INTERNET_PER_CONN_OPTIONW {
            dwOption: flag_option,
            ..Default::default()
        };
        let mut server = INTERNET_PER_CONN_OPTIONW {
            dwOption: INTERNET_PER_CONN_PROXY_SERVER,
            ..Default::default()
        };
        flags.Value.dwValue = 0;
        server.Value.pszValue = null_mut();
        let mut options = [flags, server];
        let mut list = options_list(&mut options);
        let mut size = list.dwSize;
        // WinINet allocates the returned string, including when some requested options fail.
        let ok = unsafe {
            InternetQueryOptionW(
                null(),
                INTERNET_OPTION_PER_CONNECTION_OPTION,
                (&mut list as *mut INTERNET_PER_CONN_OPTION_LISTW).cast::<c_void>(),
                &mut size,
            )
        };
        let error = (ok == 0).then(io::Error::last_os_error);
        let server = unsafe {
            let pointer = options[1].Value.pszValue;
            if pointer.is_null() {
                String::new()
            } else {
                let mut count = 0;
                while *pointer.add(count) != 0 {
                    count += 1;
                }
                let value = String::from_utf16_lossy(std::slice::from_raw_parts(pointer, count));
                GlobalFree(pointer.cast::<c_void>());
                value
            }
        };
        if let Some(error) = error {
            return Err(error);
        }
        Ok(ProxySettings {
            flags: unsafe { options[0].Value.dwValue },
            server,
        })
    }

    pub fn query() -> Result<ProxySettings, String> {
        query_with_flags(INTERNET_PER_CONN_FLAGS_UI)
            .or_else(|_| query_with_flags(INTERNET_PER_CONN_FLAGS))
            .map_err(|err| err.to_string())
    }

    pub fn desired(port: u16, _socks: Option<u16>, _previous: &ProxySettings) -> ProxySettings {
        ProxySettings {
            flags: PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY,
            server: format!("127.0.0.1:{port}"),
        }
    }

    pub fn apply(settings: &ProxySettings) -> Result<(), String> {
        let mut server: Vec<u16> = settings.server.encode_utf16().chain([0]).collect();
        let mut options = [
            INTERNET_PER_CONN_OPTIONW {
                dwOption: INTERNET_PER_CONN_PROXY_SERVER,
                Value: INTERNET_PER_CONN_OPTIONW_0 {
                    pszValue: server.as_mut_ptr(),
                },
            },
            INTERNET_PER_CONN_OPTIONW {
                dwOption: INTERNET_PER_CONN_FLAGS,
                Value: INTERNET_PER_CONN_OPTIONW_0 {
                    dwValue: settings.flags,
                },
            },
        ];
        let list = options_list(&mut options);
        unsafe {
            if InternetSetOptionW(
                null(),
                INTERNET_OPTION_PER_CONNECTION_OPTION,
                (&list as *const INTERNET_PER_CONN_OPTION_LISTW).cast::<c_void>(),
                list.dwSize,
            ) == 0
            {
                return Err(io::Error::last_os_error().to_string());
            }
            InternetSetOptionW(null(), INTERNET_OPTION_PROXY_SETTINGS_CHANGED, null(), 0);
            InternetSetOptionW(null(), INTERNET_OPTION_REFRESH, null(), 0);
        }
        Ok(())
    }

    pub const ALREADY_OWNED_ERR: &str =
        "Windows already uses this address. RoutePilot did not take ownership.";
    pub const APPLY_MISMATCH_ERR: &str = "Windows did not apply the expected proxy settings";
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use std::process::Command;

    #[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
    pub struct ServiceProxy {
        pub enabled: bool,
        pub server: String,
        pub port: u16,
    }

    #[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
    pub struct ServiceEntry {
        pub service: String,
        pub http: ServiceProxy,
        pub https: ServiceProxy,
        pub socks: ServiceProxy,
    }

    #[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
    pub struct ProxySettings {
        pub services: Vec<ServiceEntry>,
    }

    fn networksetup(args: &[&str]) -> Result<String, String> {
        let output = Command::new("/usr/sbin/networksetup")
            .args(args)
            .output()
            .map_err(|err| format!("无法执行 networksetup：{err}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            let detail = if !stderr.is_empty() { stderr } else { stdout };
            return Err(if detail.is_empty() {
                "macOS 系统代理设置失败。".into()
            } else {
                format!("macOS 系统代理设置失败：{detail}")
            });
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }

    pub(crate) fn parse_services(output: &str) -> Vec<String> {
        output
            .lines()
            .skip(1)
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('*'))
            .map(str::to_owned)
            .collect()
    }

    pub(crate) fn parse_proxy_output(output: &str) -> ServiceProxy {
        let mut enabled = false;
        let mut server = String::new();
        let mut port = 0u16;
        for line in output.lines() {
            let Some((k, v)) = line.split_once(':') else {
                continue;
            };
            let val = v.trim();
            match k.trim().to_ascii_lowercase().as_str() {
                "enabled" => enabled = val.eq_ignore_ascii_case("yes"),
                "server" => server = val.to_owned(),
                "port" => port = val.parse::<u16>().unwrap_or(0),
                _ => {}
            }
        }
        ServiceProxy {
            enabled,
            server,
            port,
        }
    }

    fn has_active_ip(service: &str) -> bool {
        networksetup(&["-getinfo", service]).is_ok_and(|out| {
            out.lines().any(|line| {
                line.strip_prefix("IP address:")
                    .map(str::trim)
                    .is_some_and(|ip| !ip.is_empty() && !ip.eq_ignore_ascii_case("none"))
            })
        })
    }

    fn target_services() -> Result<Vec<String>, String> {
        let all = parse_services(&networksetup(&["-listallnetworkservices"])?);
        if all.is_empty() {
            return Err("未检测到可用的 macOS 网络服务。".into());
        }
        let active: Vec<String> = all
            .iter()
            .filter(|svc| has_active_ip(svc))
            .cloned()
            .collect();
        if !active.is_empty() {
            return Ok(active);
        }
        // Fall back to Wi-Fi or the first enabled service when offline.
        if let Some(wifi) = all.iter().find(|s| s.eq_ignore_ascii_case("Wi-Fi")) {
            return Ok(vec![wifi.clone()]);
        }
        Ok(vec![all[0].clone()])
    }

    fn query_service(service: &str) -> Result<ServiceEntry, String> {
        let http = parse_proxy_output(&networksetup(&["-getwebproxy", service])?);
        let https = parse_proxy_output(&networksetup(&["-getsecurewebproxy", service])?);
        let socks = parse_proxy_output(&networksetup(&["-getsocksfirewallproxy", service])?);
        Ok(ServiceEntry {
            service: service.to_owned(),
            http,
            https,
            socks,
        })
    }

    pub fn query() -> Result<ProxySettings, String> {
        let services = target_services()?;
        query_for(&services)
    }

    pub fn query_for(services: &[String]) -> Result<ProxySettings, String> {
        let mut entries = Vec::with_capacity(services.len());
        for service in services {
            entries.push(query_service(service)?);
        }
        Ok(ProxySettings { services: entries })
    }

    pub fn desired(port: u16, socks: Option<u16>, previous: &ProxySettings) -> ProxySettings {
        let local = |port: u16| ServiceProxy {
            enabled: true,
            server: "127.0.0.1".into(),
            port,
        };
        // macOS sends non-HTTP traffic to the SOCKS entry, so it must name a port that speaks
        // SOCKS5. With only an HTTP listener the entry is switched off rather than pointed at a
        // port that would reject the handshake.
        let socks = match socks {
            Some(port) => local(port),
            None => ServiceProxy {
                enabled: false,
                server: String::new(),
                port: 0,
            },
        };
        ProxySettings {
            services: previous
                .services
                .iter()
                .map(|entry| ServiceEntry {
                    service: entry.service.clone(),
                    http: local(port),
                    https: local(port),
                    socks: socks.clone(),
                })
                .collect(),
        }
    }

    fn apply_one(service: &str, set_cmd: &str, state_cmd: &str, cfg: &ServiceProxy) -> Result<(), String> {
        if cfg.enabled && !cfg.server.is_empty() && cfg.port > 0 {
            let port_str = cfg.port.to_string();
            networksetup(&[set_cmd, service, &cfg.server, &port_str])?;
            networksetup(&[state_cmd, service, "on"])?;
        } else {
            networksetup(&[state_cmd, service, "off"])?;
        }
        Ok(())
    }

    pub fn apply(settings: &ProxySettings) -> Result<(), String> {
        for entry in &settings.services {
            apply_one(
                &entry.service,
                "-setwebproxy",
                "-setwebproxystate",
                &entry.http,
            )?;
            apply_one(
                &entry.service,
                "-setsecurewebproxy",
                "-setsecurewebproxystate",
                &entry.https,
            )?;
            apply_one(
                &entry.service,
                "-setsocksfirewallproxy",
                "-setsocksfirewallproxystate",
                &entry.socks,
            )?;
        }
        Ok(())
    }

    pub const ALREADY_OWNED_ERR: &str =
        "macOS 系统代理已指向该地址，RoutePilot 未重复接管。";
    pub const APPLY_MISMATCH_ERR: &str = "macOS 未按预期应用系统代理设置。";
}

#[cfg(all(not(windows), not(target_os = "macos")))]
mod platform {
    use super::*;
    use std::process::Command;

    #[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
    pub struct ProxySettings {
        pub mode: String,
        pub host: String,
        pub port: u16,
    }

    fn gsettings(args: &[&str]) -> Result<String, String> {
        let output = Command::new("gsettings")
            .args(args)
            .output()
            .map_err(|_| "当前 Linux 桌面环境缺少 gsettings，请改用终端代理变量或 TUN 模式。".to_owned())?;
        if !output.status.success() {
            return Err("Linux 系统代理配置失败，请改用终端代理变量或 TUN 模式。".into());
        }
        Ok(String::from_utf8_lossy(&output.stdout).trim().trim_matches('\'').to_owned())
    }

    pub fn query() -> Result<ProxySettings, String> {
        let mode = gsettings(&["get", "org.gnome.system.proxy", "mode"])?;
        let host = gsettings(&["get", "org.gnome.system.proxy.http", "host"]).unwrap_or_default();
        let port = gsettings(&["get", "org.gnome.system.proxy.http", "port"])
            .ok()
            .and_then(|s| s.parse::<u16>().ok())
            .unwrap_or(0);
        Ok(ProxySettings { mode, host, port })
    }

    pub fn desired(port: u16, _socks: Option<u16>, _previous: &ProxySettings) -> ProxySettings {
        ProxySettings {
            mode: "manual".into(),
            host: "127.0.0.1".into(),
            port,
        }
    }

    pub fn apply(settings: &ProxySettings) -> Result<(), String> {
        let port_str = settings.port.to_string();
        for schema in [
            "org.gnome.system.proxy.http",
            "org.gnome.system.proxy.https",
            "org.gnome.system.proxy.socks",
        ] {
            gsettings(&["set", schema, "host", &settings.host])?;
            gsettings(&["set", schema, "port", &port_str])?;
        }
        gsettings(&["set", "org.gnome.system.proxy", "mode", &settings.mode])?;
        Ok(())
    }

    pub const ALREADY_OWNED_ERR: &str = "Linux 系统代理已指向该地址，RoutePilot 未重复接管。";
    pub const APPLY_MISMATCH_ERR: &str = "Linux 未按预期应用系统代理设置。";
}

use platform::ProxySettings;

#[derive(Deserialize, Serialize)]
struct Recovery {
    previous: ProxySettings,
    applied: ProxySettings,
}

fn load(dir: &Path) -> Result<Option<Recovery>, String> {
    match fs::read(dir.join(JOURNAL)) {
        Ok(data) => serde_json::from_slice(&data)
            .map(Some)
            .map_err(|err| err.to_string()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err.to_string()),
    }
}

fn query_matching(recovery: &Recovery) -> Result<ProxySettings, String> {
    #[cfg(target_os = "macos")]
    {
        let names: Vec<String> = recovery
            .applied
            .services
            .iter()
            .map(|entry| entry.service.clone())
            .collect();
        return platform::query_for(&names);
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = recovery;
        platform::query()
    }
}

fn restore_target<'a>(
    recovery: &'a Recovery,
    current: &ProxySettings,
) -> Option<&'a ProxySettings> {
    // Do not overwrite changes another application made after RoutePilot enabled the proxy.
    (current == &recovery.applied).then_some(&recovery.previous)
}

pub fn is_owned(dir: &Path) -> Result<bool, String> {
    let Some(recovery) = load(dir)? else {
        return Ok(false);
    };
    Ok(restore_target(&recovery, &query_matching(&recovery)?).is_some())
}

/// How long a status poll may reuse the last ownership answer. Reading the live setting costs
/// three `networksetup` launches per network service on macOS (three `gsettings` on Linux), and
/// the interface asks every two seconds; the only thing the wait delays is noticing that another
/// application replaced the proxy.
const OWNED_TTL: Duration = Duration::from_secs(8);

static OWNED: Mutex<Option<(Instant, bool)>> = Mutex::new(None);

fn forget_owned() {
    if let Ok(mut cached) = OWNED.lock() {
        *cached = None;
    }
}

/// Ownership for status display. Anything that decides whether to write the system setting must
/// call [`is_owned`] instead.
pub fn is_owned_cached(dir: &Path) -> Result<bool, String> {
    if let Ok(cached) = OWNED.lock() {
        if let Some((at, owned)) = *cached {
            if at.elapsed() < OWNED_TTL {
                return Ok(owned);
            }
        }
    }
    let owned = is_owned(dir)?;
    if let Ok(mut cached) = OWNED.lock() {
        *cached = Some((Instant::now(), owned));
    }
    Ok(owned)
}

pub fn restore(dir: &Path) -> Result<(), String> {
    let Some(recovery) = load(dir)? else {
        return Ok(());
    };
    forget_owned();
    let current = query_matching(&recovery)?;
    if let Some(previous) = restore_target(&recovery, &current) {
        platform::apply(previous)?;
    }
    fs::remove_file(dir.join(JOURNAL)).map_err(|err| err.to_string())
}

/// Change only the proxy we still own, preserving the user's original recovery target.
pub fn retarget(dir: &Path, port: u16, socks: Option<u16>) -> Result<(), String> {
    forget_owned();
    let old = load(dir)?.ok_or("系统代理已不再由本应用接管。")?;
    if restore_target(&old, &query_matching(&old)?).is_none() {
        return Err("系统代理已被其他应用修改，请刷新后重试。".into());
    }
    let next = Recovery {
        previous: old.previous.clone(),
        applied: platform::desired(port, socks, &old.previous),
    };
    save_recovery(dir, &next)?;
    let result = platform::apply(&next.applied).and_then(|()| {
        if query_matching(&next)? == next.applied { Ok(()) }
        else { Err(platform::APPLY_MISMATCH_ERR.into()) }
    });
    if let Err(error) = result {
        let current = query_matching(&next)?;
        if current != next.applied && current != old.applied {
            return Err(format!("{error}；系统代理状态已变化，保留恢复记录。"));
        }
        platform::apply(&old.applied)?;
        save_recovery(dir, &old)?;
        return Err(error);
    }
    Ok(())
}

fn save_recovery(dir: &Path, recovery: &Recovery) -> Result<(), String> {
    let contents = serde_json::to_vec(recovery).map_err(|err| err.to_string())?;
    let temporary = dir.join("system-proxy-recovery.tmp");
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&temporary)
        .map_err(|err| err.to_string())?;
    file.write_all(&contents)
        .and_then(|_| file.sync_all())
        .map_err(|err| err.to_string())?;
    drop(file);
    fs::rename(&temporary, dir.join(JOURNAL)).map_err(|err| err.to_string())?;

    Ok(())
}

/// `socks` is the port that actually speaks SOCKS5 (the mixed port, or a dedicated SOCKS port).
/// It is `None` when only an HTTP listener is configured.
pub fn enable(dir: &Path, port: u16, socks: Option<u16>) -> Result<(), String> {
    forget_owned();
    if is_owned(dir)? {
        return Ok(());
    }
    restore(dir)?;
    let previous = platform::query()?;
    let applied = platform::desired(port, socks, &previous);
    if previous == applied {
        return Err(platform::ALREADY_OWNED_ERR.into());
    }

    let recovery = Recovery { previous, applied };
    save_recovery(dir, &recovery)?;

    let result = platform::apply(&recovery.applied).and_then(|()| {
        if is_owned(dir)? {
            Ok(())
        } else {
            Err(platform::APPLY_MISMATCH_ERR.into())
        }
    });
    forget_owned();
    // On failure the recovery journal stays in place: the result of a partial write is uncertain.
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    #[ignore = "temporarily changes the current Windows user's proxy on a disposable VM"]
    fn wininet_takeover_and_recovery() {
        let before = platform::query().unwrap();
        let dir = std::env::temp_dir().join(format!("xeyl-proxy-test-{}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        let reserve = || std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let first = reserve();
        let second = reserve();
        let port = first.local_addr().unwrap().port();
        let expected = platform::desired(port, None, &before);
        let external = platform::desired(second.local_addr().unwrap().port(), None, &before);

        // Keep the runner online even when an assertion fails inside the test.
        let result = std::panic::catch_unwind(|| {
            enable(&dir, port, None).unwrap();
            assert_eq!(platform::query().unwrap(), expected);
            assert!(is_owned(&dir).unwrap());
            enable(&dir, port, None).unwrap();
            assert_eq!(load(&dir).unwrap().unwrap().previous, before);
            let updated_port = second.local_addr().unwrap().port();
            retarget(&dir, updated_port, Some(updated_port)).unwrap();
            assert_eq!(platform::query().unwrap(), external);
            assert_eq!(load(&dir).unwrap().unwrap().previous, before);
            retarget(&dir, port, None).unwrap();
            assert_eq!(platform::query().unwrap(), expected);
            restore(&dir).unwrap();
            assert_eq!(platform::query().unwrap(), before);
            assert!(load(&dir).unwrap().is_none());

            enable(&dir, port, None).unwrap();
            platform::apply(&external).unwrap();
            assert!(!is_owned(&dir).unwrap());
            restore(&dir).unwrap();
            assert_eq!(platform::query().unwrap(), external);
            assert!(load(&dir).unwrap().is_none());
        });
        platform::apply(&before).unwrap();
        assert_eq!(platform::query().unwrap(), before);
        fs::remove_dir_all(dir).unwrap();
        if let Err(panic) = result {
            std::panic::resume_unwind(panic);
        }
    }

    #[cfg(windows)]
    #[test]
    fn recovery_only_restores_exact_owned_settings() {
        let recovery = Recovery {
            previous: ProxySettings {
                flags: 9,
                server: "previous:8080".into(),
            },
            applied: ProxySettings {
                flags: 3,
                server: "127.0.0.1:7890".into(),
            },
        };
        assert_eq!(
            restore_target(&recovery, &recovery.applied),
            Some(&recovery.previous)
        );
        assert_eq!(restore_target(&recovery, &recovery.previous), None);
        assert_eq!(
            restore_target(
                &recovery,
                &ProxySettings {
                    flags: 1,
                    server: recovery.applied.server.clone()
                }
            ),
            None
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parses_macos_networksetup_services_and_proxy_state() {
        let list = "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Bluetooth PAN\nUSB 10/100/1000 LAN\n";
        assert_eq!(
            platform::parse_services(list),
            vec!["Wi-Fi".to_owned(), "USB 10/100/1000 LAN".to_owned()]
        );
        let state = "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\nAuthenticated Proxy Enabled: 0\n";
        let parsed = platform::parse_proxy_output(state);
        assert!(parsed.enabled);
        assert_eq!(parsed.server, "127.0.0.1");
        assert_eq!(parsed.port, 7890);

        let entry = platform::ServiceEntry {
            service: "Wi-Fi".into(),
            http: parsed.clone(),
            https: parsed.clone(),
            socks: parsed,
        };
        let off = platform::ServiceProxy {
            enabled: false,
            server: String::new(),
            port: 0,
        };
        let prev = ProxySettings {
            services: vec![platform::ServiceEntry {
                service: "Wi-Fi".into(),
                http: off.clone(),
                https: off.clone(),
                socks: off,
            }],
        };
        let applied = ProxySettings {
            services: vec![entry],
        };
        let recovery = Recovery {
            previous: prev.clone(),
            applied: applied.clone(),
        };
        assert_eq!(restore_target(&recovery, &applied), Some(&prev));
        assert_eq!(restore_target(&recovery, &prev), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_socks_entry_only_names_a_port_that_speaks_socks() {
        let off = platform::ServiceProxy {
            enabled: false,
            server: String::new(),
            port: 0,
        };
        let previous = ProxySettings {
            services: vec![platform::ServiceEntry {
                service: "Wi-Fi".into(),
                http: off.clone(),
                https: off.clone(),
                socks: platform::ServiceProxy {
                    enabled: true,
                    server: "10.0.0.2".into(),
                    port: 1080,
                },
            }],
        };

        let mixed = platform::desired(7890, Some(7890), &previous);
        assert_eq!(mixed.services[0].http.port, 7890);
        assert_eq!(mixed.services[0].https.port, 7890);
        assert!(mixed.services[0].socks.enabled);
        assert_eq!(mixed.services[0].socks.port, 7890);

        let split = platform::desired(8080, Some(1081), &previous);
        assert_eq!(split.services[0].http.port, 8080);
        assert_eq!(split.services[0].socks.port, 1081);

        let http_only = platform::desired(8080, None, &previous);
        assert_eq!(http_only.services[0].http.port, 8080);
        assert_eq!(http_only.services[0].socks, off);
    }
}
