use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const KEY: &str = "routepilot-fixed-socks";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Binding {
    pub port: u16,
    pub node: String,
    pub provider: Option<String>,
}

pub fn bindings(config: &Value) -> Result<Vec<Binding>, String> {
    match config.get(KEY) {
        None => Ok(Vec::new()),
        Some(value) => serde_json::from_value(value.clone())
            .map_err(|_| "固定 SOCKS5 入口格式无效，请检查端口和节点。".into()),
    }
}

pub fn edit(config: &mut Value, binding: Binding, remove: bool) -> Result<(), String> {
    let mut entries = bindings(config)?;
    if remove {
        let index = entries
            .iter()
            .position(|b| b == &binding)
            .ok_or("入口已变更，请重新打开。")?;
        entries.remove(index);
    } else {
        if entries.iter().any(|b| b.port == binding.port) {
            return Err("该端口已有固定入口。".into());
        }
        entries.push(binding);
    }
    config[KEY] = json!(entries);
    Ok(())
}

pub fn apply(config: &Value, runtime: &mut Value) -> Result<(), String> {
    for binding in bindings(config)? {
        let name = format!("Xeylroute.SOCKS.{}", binding.port);
        let node = &binding.node;
        if node.trim().is_empty() || node.chars().any(char::is_control) {
            return Err("请选择有效的固定节点。".into());
        }
        let proxy = if let Some(provider) = &binding.provider {
            if config["proxy-providers"].get(provider).is_none() {
                return Err(format!(
                    "端口 {} 仍绑定订阅「{provider}」，请先移除入口。",
                    binding.port
                ));
            }
            if ["proxies", "proxy-groups"].iter().any(|key| {
                runtime[key]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|item| item["name"] == name)
            }) {
                return Err(format!("固定入口的内部名称 {name} 与现有节点或分组重复。"));
            }
            let group = json!({"type":"select", "name":name, "hidden":true, "use":[provider],
                "filter":crate::profile::exact_node_filter(node), "empty-fallback":"REJECT"});
            runtime
                .as_object_mut()
                .ok_or("无效配置")?
                .entry("proxy-groups")
                .or_insert_with(|| json!([]))
                .as_array_mut()
                .ok_or("无效的策略组列表")?
                .push(group);
            name.as_str()
        } else {
            if !config["proxies"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|proxy| proxy["name"] == node.as_str())
            {
                return Err(format!(
                    "端口 {} 绑定的节点「{node}」不存在，请先移除入口。",
                    binding.port
                ));
            }
            node.as_str()
        };
        runtime
            .as_object_mut()
            .ok_or("无效配置")?
            .entry("listeners")
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .ok_or("无效的监听列表")?
            .push(json!({"type":"socks", "name":name,
                "listen":"127.0.0.1", "port":binding.port, "udp":true,"users":[], "proxy":proxy}));
    }
    Ok(())
}

pub fn check_udp_port(port: u16) -> Result<(), String> {
    std::net::UdpSocket::bind((std::net::Ipv4Addr::LOCALHOST, port))
        .map(|_| ())
        .map_err(|_| format!("本地 UDP 端口 {port} 无法监听，请选择其他端口。"))
}

/// Check the SOCKS5 no-auth greeting before publishing a newly opened loopback endpoint.
pub fn verify_listener(port: u16) -> std::io::Result<()> {
    use std::io::{Read, Write};
    use std::net::{Ipv4Addr, TcpStream};
    use std::time::Duration;

    let timeout = Duration::from_secs(1);
    let mut stream = TcpStream::connect_timeout(&(Ipv4Addr::LOCALHOST, port).into(), timeout)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    stream.write_all(&[5, 1, 0])?;
    let mut reply = [0; 2];
    stream.read_exact(&mut reply)?;
    if reply != [5, 0] {
        return Err(std::io::Error::other(format!(
            "端口 {port} 未返回预期的 SOCKS5 握手"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standalone_binding_survives_save_and_checks_removal_identity() {
        let mut config = json!({"proxies":[{"name":"JP"}],"mixed-port":7890});
        let jp = Binding {
            port: 19081,
            node: "JP".into(),
            provider: None,
        };
        edit(&mut config, jp.clone(), false).unwrap();
        let mut saved: Value = serde_json::from_str(&config.to_string()).unwrap();
        assert!(edit(&mut saved, jp.clone(), false).is_err());
        let mut runtime = crate::runtime_config(&saved, false).unwrap();
        assert_eq!(runtime["listeners"][0]["proxy"], "JP");
        let stale = Binding {
            node: "US".into(),
            ..jp.clone()
        };
        assert!(edit(&mut saved, stale, true).is_err());
        saved["proxies"] = json!([]);
        assert!(crate::runtime_config(&saved, false).is_err());
        edit(&mut saved, jp, true).unwrap();
        runtime = crate::runtime_config(&saved, false).unwrap();
        assert!(runtime.get("listeners").is_none());
    }
}
