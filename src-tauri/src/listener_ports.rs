use crate::{fixed_socks, mihomo_api::Controller, parse_runtime_facts, system_proxy};
use serde_json::{json, Value};
use std::{fs, net::{Ipv4Addr, TcpListener}, path::Path, time::Duration};

pub const KEYS: [&str; 3] = ["port", "socks-port", "mixed-port"];

fn ports(config: &Value) -> Value {
    let mut result = json!({});
    for key in KEYS { result[key] = config.get(key).cloned().unwrap_or(json!(0)); }
    result
}

async fn patch(controller: &Controller, next: &Value) -> Result<(), String> {
    let current = controller.request(reqwest::Method::GET, &["configs"], &[], None).await?;
    // PATCH recreates protocols sequentially. Release old listeners before swapping protocols.
    let reuses_port = KEYS.iter().any(|key| next[*key].as_u64().unwrap_or(0) > 0
        && KEYS.iter().any(|other| key != other && next[*key] == current[*other]));
    if reuses_port {
        let mut release = ports(&current);
        for key in KEYS { if release[key] != next[key] { release[key] = json!(0); } }
        controller.request(reqwest::Method::PATCH, &["configs"], &[], Some(release)).await?;
    }
    controller.request(reqwest::Method::PATCH, &["configs"], &[], Some(next.clone())).await?;
    Ok(())
}

async fn verify(controller: &Controller, expected: &Value) -> Result<(), String> {
    let actual = controller.request(reqwest::Method::GET, &["configs"], &[], None).await?;
    if ports(&actual) != *expected { return Err(format!("内核返回的监听端口与配置不一致：实际 {}，预期 {expected}", ports(&actual))); }
    for key in KEYS {
        let port = expected[key].as_u64().unwrap_or(0) as u16;
        if port == 0 { continue; }
        let mut ready = false;
        for _ in 0..10 {
            let result = if key == "port" {
                std::net::TcpStream::connect_timeout(&(Ipv4Addr::LOCALHOST, port).into(), Duration::from_millis(200)).map(|_| ())
            } else { fixed_socks::verify_listener(port) };
            if result.is_ok() { ready = true; break; }
            std::thread::sleep(Duration::from_millis(100));
        }
        if !ready { return Err(format!("本地端口 {port} 未能正常监听。")); }
    }
    Ok(())
}

pub async fn update(dir: &Path, controller: &Controller, config: &Value) -> Result<(), String> {
    let _lock = controller.probe_lock.lock().await;
    let current = controller.request(reqwest::Method::GET, &["configs"], &[], None).await?;
    let old = ports(&current);
    let next = ports(config);
    for key in KEYS {
        let port = next[key].as_u64().unwrap_or(0) as u16;
        if port == 0 { continue; }
        if key != "port" && !["socks-port", "mixed-port"].iter().any(|key| old[*key].as_u64() == Some(port.into())) {
            fixed_socks::check_udp_port(port)?;
        }
        if !KEYS.iter().any(|key| old[*key].as_u64() == Some(port.into())) {
            TcpListener::bind((Ipv4Addr::LOCALHOST, port))
                .map_err(|_| format!("本地端口 {port} 无法监听，请选择其他端口。"))?;
        }
    }
    let owned = system_proxy::is_owned(dir)?;
    let next_facts = parse_runtime_facts(&next);
    if owned && next_facts.http.is_none() {
        return Err("系统代理开启时需保留 HTTP 或混合端口。".into());
    }
    let profile_path = dir.join("mihomo.json");
    let runtime_path = dir.join("routepilot-validated.json");
    let profile_before = fs::read(&profile_path).map_err(|e| e.to_string())?;
    let runtime_before = fs::read(&runtime_path).map_err(|e| e.to_string())?;
    let mut runtime: Value = serde_json::from_slice(&runtime_before).map_err(|e| e.to_string())?;
    for key in KEYS { runtime[key] = next[key].clone(); }
    let profile_temp = dir.join("mihomo.json.tmp");
    let runtime_temp = dir.join("routepilot-validated.json.tmp");
    fs::write(&profile_temp, config.to_string()).map_err(|e| e.to_string())?;
    if let Err(e) = fs::write(&runtime_temp, runtime.to_string()) {
        let _ = fs::remove_file(&profile_temp);
        return Err(e.to_string());
    }
    let mut proxy_changed = false;
    let mut files_changed = false;
    let result: Result<(), String> = async {
        patch(controller, &next).await?;
        verify(controller, &next).await?;
        if owned {
            proxy_changed = true;
            system_proxy::retarget(dir, next_facts.http.unwrap(), next_facts.socks)?;
        }
        fs::rename(&profile_temp, &profile_path).map_err(|e| e.to_string())?;
        files_changed = true;
        fs::rename(&runtime_temp, &runtime_path).map_err(|e| e.to_string())?;
        Ok(())
    }.await;
    let _ = fs::remove_file(&profile_temp);
    let _ = fs::remove_file(&runtime_temp);
    if let Err(error) = result {
        let mut failures = Vec::new();
        let rollback = async {
            patch(controller, &old).await?;
            verify(controller, &old).await
        }.await;
        if let Err(e) = rollback { failures.push(e); }
        if proxy_changed {
            let facts = parse_runtime_facts(&old);
            if let Err(e) = system_proxy::retarget(dir, facts.http.unwrap(), facts.socks) { failures.push(e); }
        }
        if files_changed {
            if let Err(e) = fs::write(&profile_path, &profile_before) { failures.push(e.to_string()); }
        }
        return Err(if failures.is_empty() { format!("端口更新失败，已恢复原配置：{error}") }
            else { format!("端口更新失败：{error}；恢复失败：{}", failures.join("；")) });
    }
    Ok(())
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use std::{os::windows::fs::OpenOptionsExt, process::{Child, Command, Stdio}};

    struct Core { child: Child, dir: std::path::PathBuf }
    impl Drop for Core {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    #[test]
    #[ignore = "requires the bundled Windows Mihomo binary; uses isolated loopback ports, no system proxy"]
    fn hot_ports_with_real_core_and_disk_failure_rollback() {
        let reservations: Vec<_> = (0..7).map(|_| TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).collect();
        let p: Vec<_> = reservations.iter().map(|s| s.local_addr().unwrap().port()).collect();
        let dir = std::env::temp_dir().join(format!("xeyl-hot-ports-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let original = json!({"mixed-port":p[0],"port":0,"socks-port":0,
            "external-controller":format!("127.0.0.1:{}",p[1]),"secret":"hot-port-test",
            "bind-address":"127.0.0.1","allow-lan":false,"mode":"rule",
            "rules":["MATCH,DIRECT"],"dns":{"enable":false}});
        for name in ["mihomo.json", "routepilot-validated.json"] {
            fs::write(dir.join(name), original.to_string()).unwrap();
        }
        drop(reservations);
        let binary = Path::new(env!("CARGO_MANIFEST_DIR")).join("binaries/xeylroute-mihomo-x86_64-pc-windows-msvc.exe");
        let child = Command::new(binary).args(["-d", dir.to_str().unwrap(), "-f", dir.join("mihomo.json").to_str().unwrap()])
            .stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        let mut core = Core { child, dir };
        let controller = Controller::new((Ipv4Addr::LOCALHOST,p[1]).into(), "hot-port-test".into(), p[6]).unwrap();
        tauri::async_runtime::block_on(async {
            for _ in 0..100 {
                if controller.request(reqwest::Method::GET,&["configs"],&[],None).await.is_ok() { break; }
                std::thread::sleep(Duration::from_millis(100));
            }
            let mut next = original.clone();
            next["mixed-port"] = json!(p[2]);
            next["port"] = json!(p[3]);
            next["socks-port"] = json!(p[4]);
            update(&core.dir,&controller,&next).await.unwrap();
            verify(&controller,&ports(&next)).await.unwrap();
            assert!(core.child.try_wait().unwrap().is_none());
            assert!(std::net::TcpStream::connect((Ipv4Addr::LOCALHOST,p[0])).is_err());
            assert_eq!(crate::runtime_facts(&core.dir).http,Some(p[2]));
            assert_eq!(serde_json::from_slice::<Value>(&fs::read(core.dir.join("mihomo.json")).unwrap()).unwrap(),next);

            let mut rejected = next.clone();
            rejected["mixed-port"] = json!(p[5]);
            let occupied = TcpListener::bind((Ipv4Addr::LOCALHOST,p[5])).unwrap();
            assert!(update(&core.dir,&controller,&rejected).await.unwrap_err().contains("无法监听"));
            verify(&controller,&ports(&next)).await.unwrap();
            drop(occupied);
            let occupied_udp = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST,p[5])).unwrap();
            assert!(update(&core.dir,&controller,&rejected).await.unwrap_err().contains("UDP"));
            drop(occupied_udp);

            // Deny deletion of the profile: PATCH succeeds but publishing the file fails.
            let locked = fs::OpenOptions::new().read(true).share_mode(3).open(core.dir.join("mihomo.json")).unwrap();
            let error = update(&core.dir,&controller,&rejected).await.unwrap_err();
            assert!(error.contains("已恢复原配置"),"{error}");
            verify(&controller,&ports(&next)).await.unwrap();
            assert_eq!(serde_json::from_slice::<Value>(&fs::read(core.dir.join("mihomo.json")).unwrap()).unwrap(),next);
            assert!(std::net::TcpStream::connect((Ipv4Addr::LOCALHOST,p[5])).is_err());
            drop(locked);

            // Reuse a previous port for another protocol and disable the mixed listener.
            next["mixed-port"] = json!(0);
            next["port"] = json!(p[4]);
            next["socks-port"] = json!(p[3]);
            update(&core.dir,&controller,&next).await.unwrap();
            verify(&controller,&ports(&next)).await.unwrap();
            assert_eq!(crate::runtime_facts(&core.dir).http,Some(p[4]));
        });
    }
}
