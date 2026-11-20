use base64::{engine::general_purpose, Engine};
use serde_json::{json, Map, Value};
use std::collections::HashMap;

const SUPPORTED_SCHEMES: &[&str] = &[
    "ss",
    "vmess",
    "vless",
    "trojan",
    "hysteria2",
    "hy2",
    "tuic",
];

fn decode_base64(input: &str) -> Option<String> {
    let cleaned: String = input.chars().filter(|c| !c.is_whitespace()).collect();
    if cleaned.is_empty() {
        return None;
    }
    let bytes = general_purpose::STANDARD
        .decode(&cleaned)
        .or_else(|_| general_purpose::STANDARD_NO_PAD.decode(&cleaned))
        .or_else(|_| general_purpose::URL_SAFE.decode(&cleaned))
        .or_else(|_| general_purpose::URL_SAFE_NO_PAD.decode(&cleaned))
        .ok()?;
    String::from_utf8(bytes).ok()
}

fn percent_decode(raw: &str) -> String {
    let escaped = raw.replace('&', "%26").replace('+', "%2B");
    reqwest::Url::parse(&format!("http://127.0.0.1/?v={escaped}"))
        .ok()
        .and_then(|url| url.query_pairs().next().map(|(_, v)| v.into_owned()))
        .unwrap_or_else(|| raw.to_owned())
}

fn query_map(url: &reqwest::Url) -> HashMap<String, String> {
    url.query_pairs()
        .map(|(k, v)| (k.to_ascii_lowercase(), v.into_owned()))
        .collect()
}

fn truthy(value: Option<&String>) -> bool {
    value.is_some_and(|v| matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
}

fn host_str(url: &reqwest::Url) -> Result<String, String> {
    url.host_str()
        .map(|h| h.trim_matches(['[', ']']).to_owned())
        .filter(|h| !h.is_empty())
        .ok_or_else(|| "节点链接缺少服务器地址。".to_owned())
}

fn fragment_name(url: &reqwest::Url, fallback: &str) -> String {
    url.fragment()
        .map(percent_decode)
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| fallback.to_owned())
}

fn split_csv(raw: &str) -> Vec<String> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}

fn apply_transport(node: &mut Map<String, Value>, params: &HashMap<String, String>) {
    let network = params
        .get("type")
        .or_else(|| params.get("net"))
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_else(|| "tcp".into());
    match network.as_str() {
        "ws" => {
            node.insert("network".into(), json!("ws"));
            let mut opts = Map::new();
            if let Some(path) = params.get("path").filter(|s| !s.is_empty()) {
                opts.insert("path".into(), json!(path));
            }
            if let Some(host) = params.get("host").filter(|s| !s.is_empty()) {
                opts.insert("headers".into(), json!({ "Host": host }));
            }
            if !opts.is_empty() {
                node.insert("ws-opts".into(), Value::Object(opts));
            }
        }
        "grpc" => {
            node.insert("network".into(), json!("grpc"));
            if let Some(svc) = params
                .get("servicename")
                .or_else(|| params.get("service-name"))
                .or_else(|| params.get("path"))
                .filter(|s| !s.is_empty())
            {
                node.insert("grpc-opts".into(), json!({ "grpc-service-name": svc }));
            }
        }
        "h2" | "http" => {
            node.insert("network".into(), json!("h2"));
            let mut opts = Map::new();
            if let Some(path) = params.get("path").filter(|s| !s.is_empty()) {
                opts.insert("path".into(), json!(path));
            }
            if let Some(host) = params.get("host").filter(|s| !s.is_empty()) {
                opts.insert("host".into(), json!(split_csv(host)));
            }
            if !opts.is_empty() {
                node.insert("h2-opts".into(), Value::Object(opts));
            }
        }
        _ => {}
    }
}

fn parse_ss(line: &str) -> Result<Value, String> {
    let body = line.strip_prefix("ss://").ok_or("无效的 SS 链接")?;
    let (main, frag) = match body.split_once('#') {
        Some((m, f)) => (m, Some(percent_decode(f))),
        None => (body, None),
    };
    let (addr_part, query_part) = match main.split_once('?') {
        Some((a, q)) => (a, Some(q)),
        None => (main, None),
    };

    let (method, password, server, port) = if let Some((userinfo, hostport)) = addr_part.split_once('@')
    {
        let decoded = if userinfo.contains(':') {
            percent_decode(userinfo)
        } else {
            decode_base64(userinfo).unwrap_or_else(|| percent_decode(userinfo))
        };
        let (method, password) = decoded
            .split_once(':')
            .ok_or("SS 链接缺少加密方式或密码。")?;
        let parsed = reqwest::Url::parse(&format!("http://{hostport}"))
            .map_err(|_| "SS 节点服务器地址或端口无效。")?;
        let server = host_str(&parsed)?;
        let port = parsed.port().ok_or("SS 节点缺少端口号。")?;
        (method.to_owned(), password.to_owned(), server, port)
    } else {
        let decoded = decode_base64(addr_part).ok_or("无法解码 SS Base64 节点链接。")?;
        let (cred, hostport) = decoded.rsplit_once('@').ok_or("SS 链接格式无效。")?;
        let (method, password) = cred.split_once(':').ok_or("SS 链接缺少加密方式或密码。")?;
        let parsed = reqwest::Url::parse(&format!("http://{hostport}"))
            .map_err(|_| "SS 节点服务器地址或端口无效。")?;
        let server = host_str(&parsed)?;
        let port = parsed.port().ok_or("SS 节点缺少端口号。")?;
        (method.to_owned(), password.to_owned(), server, port)
    };

    let name = frag
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| format!("SS · {server}:{port}"));

    let mut node = Map::new();
    node.insert("name".into(), json!(name));
    node.insert("type".into(), json!("ss"));
    node.insert("server".into(), json!(server));
    node.insert("port".into(), json!(port));
    node.insert("cipher".into(), json!(method));
    node.insert("password".into(), json!(password));
    node.insert("udp".into(), json!(true));

    if let Some(q) = query_part {
        if let Ok(fake) = reqwest::Url::parse(&format!("http://127.0.0.1/?{q}")) {
            let params = query_map(&fake);
            if let Some(plugin_raw) = params.get("plugin").filter(|s| !s.is_empty()) {
                let mut parts = plugin_raw.split(';');
                if let Some(plugin_name) = parts.next() {
                    let plugin = match plugin_name {
                        "obfs-local" | "simple-obfs" => "obfs",
                        other => other,
                    };
                    node.insert("plugin".into(), json!(plugin));
                    let mut opts = Map::new();
                    for kv in parts {
                        if let Some((k, v)) = kv.split_once('=') {
                            let key = match k {
                                "obfs" => "mode",
                                "obfs-host" => "host",
                                other => other,
                            };
                            opts.insert(key.into(), json!(v));
                        }
                    }
                    if !opts.is_empty() {
                        node.insert("plugin-opts".into(), Value::Object(opts));
                    }
                }
            }
        }
    }
    Ok(Value::Object(node))
}

fn parse_vmess(line: &str) -> Result<Value, String> {
    let encoded = line.strip_prefix("vmess://").ok_or("无效的 VMess 链接")?;
    let raw = decode_base64(encoded).ok_or("无法解码 VMess Base64 内容。")?;
    let payload: Value = serde_json::from_str(&raw).map_err(|_| "VMess JSON 内容无效。")?;
    let server = payload["add"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("VMess 缺少服务器地址。")?;
    let port = payload["port"]
        .as_u64()
        .or_else(|| payload["port"].as_str()?.parse::<u64>().ok())
        .and_then(|p| u16::try_from(p).ok())
        .filter(|p| *p > 0)
        .ok_or("VMess 端口号无效。")?;
    let uuid = payload["id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("VMess 缺少 UUID。")?;
    let alter_id = payload["aid"]
        .as_u64()
        .or_else(|| payload["aid"].as_str()?.parse::<u64>().ok())
        .unwrap_or(0);
    let cipher = payload["scy"]
        .as_str()
        .or_else(|| payload["cipher"].as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("auto");
    let name = payload["ps"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("VMess · {server}:{port}"));

    let mut node = Map::new();
    node.insert("name".into(), json!(name));
    node.insert("type".into(), json!("vmess"));
    node.insert("server".into(), json!(server));
    node.insert("port".into(), json!(port));
    node.insert("uuid".into(), json!(uuid));
    node.insert("alterId".into(), json!(alter_id));
    node.insert("cipher".into(), json!(cipher));
    node.insert("udp".into(), json!(true));

    if payload["tls"].as_str().is_some_and(|t| t.eq_ignore_ascii_case("tls"))
        || payload["tls"].as_bool() == Some(true)
    {
        node.insert("tls".into(), json!(true));
        if let Some(sni) = payload["sni"]
            .as_str()
            .or_else(|| payload["host"].as_str())
            .filter(|s| !s.is_empty())
        {
            node.insert("servername".into(), json!(sni));
        }
    }
    if let Some(fp) = payload["fp"].as_str().filter(|s| !s.is_empty()) {
        node.insert("client-fingerprint".into(), json!(fp));
    }

    let mut params = HashMap::new();
    for (dst, src) in [
        ("type", "net"),
        ("path", "path"),
        ("host", "host"),
        ("servicename", "path"),
    ] {
        if let Some(v) = payload[src].as_str().filter(|s| !s.is_empty()) {
            params.insert(dst.into(), v.to_owned());
        }
    }
    apply_transport(&mut node, &params);
    Ok(Value::Object(node))
}

fn parse_vless(line: &str) -> Result<Value, String> {
    let url = reqwest::Url::parse(line).map_err(|_| "VLESS 链接格式无效。")?;
    let server = host_str(&url)?;
    let port = url.port().unwrap_or(443);
    let uuid = percent_decode(url.username());
    if uuid.is_empty() {
        return Err("VLESS 链接缺少 UUID。".into());
    }
    let params = query_map(&url);
    let name = fragment_name(&url, &format!("VLESS · {server}:{port}"));

    let mut node = Map::new();
    node.insert("name".into(), json!(name));
    node.insert("type".into(), json!("vless"));
    node.insert("server".into(), json!(server));
    node.insert("port".into(), json!(port));
    node.insert("uuid".into(), json!(uuid));
    node.insert("udp".into(), json!(true));

    if let Some(flow) = params.get("flow").filter(|s| !s.is_empty()) {
        node.insert("flow".into(), json!(flow));
    }
    let security = params
        .get("security")
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    if matches!(security.as_str(), "tls" | "reality") {
        node.insert("tls".into(), json!(true));
    }
    if let Some(sni) = params
        .get("sni")
        .or_else(|| params.get("servername"))
        .filter(|s| !s.is_empty())
    {
        node.insert("servername".into(), json!(sni));
    }
    if let Some(fp) = params.get("fp").filter(|s| !s.is_empty()) {
        node.insert("client-fingerprint".into(), json!(fp));
    }
    if let Some(alpn) = params.get("alpn").filter(|s| !s.is_empty()) {
        node.insert("alpn".into(), json!(split_csv(alpn)));
    }
    if truthy(params.get("allowinsecure").or_else(|| params.get("insecure"))) {
        node.insert("skip-cert-verify".into(), json!(true));
    }
    if security == "reality" {
        let mut reality = Map::new();
        if let Some(pbk) = params.get("pbk").filter(|s| !s.is_empty()) {
            reality.insert("public-key".into(), json!(pbk));
        }
        if let Some(sid) = params.get("sid").filter(|s| !s.is_empty()) {
            reality.insert("short-id".into(), json!(sid));
        }
        if !reality.is_empty() {
            node.insert("reality-opts".into(), Value::Object(reality));
        }
    }
    apply_transport(&mut node, &params);
    Ok(Value::Object(node))
}

fn parse_trojan(line: &str) -> Result<Value, String> {
    let url = reqwest::Url::parse(line).map_err(|_| "Trojan 链接格式无效。")?;
    let server = host_str(&url)?;
    let port = url.port().unwrap_or(443);
    let password = percent_decode(url.username());
    if password.is_empty() {
        return Err("Trojan 链接缺少密码。".into());
    }
    let params = query_map(&url);
    let name = fragment_name(&url, &format!("Trojan · {server}:{port}"));

    let mut node = Map::new();
    node.insert("name".into(), json!(name));
    node.insert("type".into(), json!("trojan"));
    node.insert("server".into(), json!(server));
    node.insert("port".into(), json!(port));
    node.insert("password".into(), json!(password));
    node.insert("udp".into(), json!(true));

    if let Some(sni) = params
        .get("sni")
        .or_else(|| params.get("peer"))
        .filter(|s| !s.is_empty())
    {
        node.insert("sni".into(), json!(sni));
    }
    if let Some(alpn) = params.get("alpn").filter(|s| !s.is_empty()) {
        node.insert("alpn".into(), json!(split_csv(alpn)));
    }
    if let Some(fp) = params.get("fp").filter(|s| !s.is_empty()) {
        node.insert("client-fingerprint".into(), json!(fp));
    }
    if truthy(params.get("allowinsecure").or_else(|| params.get("insecure"))) {
        node.insert("skip-cert-verify".into(), json!(true));
    }
    apply_transport(&mut node, &params);
    Ok(Value::Object(node))
}

fn parse_hysteria2(line: &str) -> Result<Value, String> {
    let normalized = if let Some(rest) = line.strip_prefix("hy2://") {
        format!("hysteria2://{rest}")
    } else {
        line.to_owned()
    };
    let url = reqwest::Url::parse(&normalized).map_err(|_| "Hysteria2 链接格式无效。")?;
    let server = host_str(&url)?;
    let port = url.port().unwrap_or(443);
    let password = match url.password() {
        Some(pass) => format!("{}:{}", percent_decode(url.username()), percent_decode(pass)),
        None => percent_decode(url.username()),
    };
    if password.is_empty() {
        return Err("Hysteria2 链接缺少认证密码。".into());
    }
    let params = query_map(&url);
    let name = fragment_name(&url, &format!("Hysteria2 · {server}:{port}"));

    let mut node = Map::new();
    node.insert("name".into(), json!(name));
    node.insert("type".into(), json!("hysteria2"));
    node.insert("server".into(), json!(server));
    node.insert("port".into(), json!(port));
    node.insert("password".into(), json!(password));

    if let Some(sni) = params.get("sni").filter(|s| !s.is_empty()) {
        node.insert("sni".into(), json!(sni));
    }
    if let Some(obfs) = params.get("obfs").filter(|s| !s.is_empty()) {
        node.insert("obfs".into(), json!(obfs));
    }
    if let Some(obfs_pw) = params.get("obfs-password").filter(|s| !s.is_empty()) {
        node.insert("obfs-password".into(), json!(obfs_pw));
    }
    if let Some(alpn) = params.get("alpn").filter(|s| !s.is_empty()) {
        node.insert("alpn".into(), json!(split_csv(alpn)));
    }
    if truthy(params.get("insecure").or_else(|| params.get("allowinsecure"))) {
        node.insert("skip-cert-verify".into(), json!(true));
    }
    Ok(Value::Object(node))
}

fn parse_tuic(line: &str) -> Result<Value, String> {
    let url = reqwest::Url::parse(line).map_err(|_| "TUIC 链接格式无效。")?;
    let server = host_str(&url)?;
    let port = url.port().unwrap_or(443);
    let uuid = percent_decode(url.username());
    let password = url.password().map(percent_decode).unwrap_or_default();
    if uuid.is_empty() {
        return Err("TUIC 链接缺少 UUID。".into());
    }
    let params = query_map(&url);
    let name = fragment_name(&url, &format!("TUIC · {server}:{port}"));

    let mut node = Map::new();
    node.insert("name".into(), json!(name));
    node.insert("type".into(), json!("tuic"));
    node.insert("server".into(), json!(server));
    node.insert("port".into(), json!(port));
    node.insert("uuid".into(), json!(uuid));
    if !password.is_empty() {
        node.insert("password".into(), json!(password));
    }
    if let Some(sni) = params.get("sni").filter(|s| !s.is_empty()) {
        node.insert("sni".into(), json!(sni));
    }
    if let Some(alpn) = params.get("alpn").filter(|s| !s.is_empty()) {
        node.insert("alpn".into(), json!(split_csv(alpn)));
    }
    if let Some(cc) = params.get("congestion_control").filter(|s| !s.is_empty()) {
        node.insert("congestion-controller".into(), json!(cc));
    }
    if let Some(relay) = params.get("udp_relay_mode").filter(|s| !s.is_empty()) {
        node.insert("udp-relay-mode".into(), json!(relay));
    }
    if truthy(params.get("allow_insecure").or_else(|| params.get("insecure"))) {
        node.insert("skip-cert-verify".into(), json!(true));
    }
    Ok(Value::Object(node))
}

fn parse_single_link(line: &str) -> Result<Value, String> {
    let trimmed = line.trim();
    let (scheme, _) = trimmed
        .split_once("://")
        .ok_or_else(|| "不支持的节点链接格式。".to_owned())?;
    match scheme.to_ascii_lowercase().as_str() {
        "ss" => parse_ss(trimmed),
        "vmess" => parse_vmess(trimmed),
        "vless" => parse_vless(trimmed),
        "trojan" => parse_trojan(trimmed),
        "hysteria2" | "hy2" => parse_hysteria2(trimmed),
        "tuic" => parse_tuic(trimmed),
        _ => Err(format!("暂不支持 {scheme}:// 协议链接。")),
    }
}

pub fn looks_like_share_links(input: &str) -> bool {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return false;
    }
    if trimmed.lines().any(|line| {
        line.trim()
            .split_once("://")
            .is_some_and(|(s, _)| SUPPORTED_SCHEMES.contains(&s.to_ascii_lowercase().as_str()))
    }) {
        return true;
    }
    if !trimmed.contains("://") && !trimmed.contains('\n') {
        if let Some(decoded) = decode_base64(trimmed) {
            return decoded.lines().any(|line| {
                line.trim().split_once("://").is_some_and(|(s, _)| {
                    SUPPORTED_SCHEMES.contains(&s.to_ascii_lowercase().as_str())
                })
            });
        }
    }
    false
}

/// Parses one or more share links (plain lines or a Base64-encoded link bundle) into Mihomo proxy objects.
pub fn parse_share_links(input: &str) -> Result<Vec<Value>, String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err("请输入节点分享链接。".into());
    }
    let decoded_bundle = if !trimmed.contains("://") {
        decode_base64(trimmed)
    } else {
        None
    };
    let source = decoded_bundle.as_deref().unwrap_or(trimmed);
    let mut nodes = Vec::new();
    let mut last_error = None;
    for raw in source.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        match parse_single_link(line) {
            Ok(node) => nodes.push(node),
            Err(err) => last_error = Some(err),
        }
    }
    if nodes.is_empty() {
        return Err(last_error.unwrap_or_else(|| "未识别到有效的代理节点链接。".into()));
    }
    Ok(nodes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_vless_reality_trojan_hy2_ss_vmess_and_base64_bundles() {
        let vless = "vless://11111111-1111-1111-1111-111111111111@example.com:443?security=reality&sni=www.apple.com&fp=chrome&pbk=PUBKEY&sid=abcd&type=tcp&flow=xtls-rprx-vision#Tokyo%20VLESS";
        let trojan = "trojan://secret@hk.example.com:443?sni=hk.example.com&type=ws&path=%2Fws#HK%20Trojan";
        let hy2 = "hy2://pass123@sg.example.com:8443?sni=sg.example.com&insecure=1#SG%20Hy2";
        let ss_cred = general_purpose::STANDARD.encode("aes-256-gcm:my-pass");
        let ss = format!("ss://{ss_cred}@jp.example.com:8388#JP%20SS");
        let vmess_json = json!({
            "v":"2","ps":"US VMess","add":"us.example.com","port":"443",
            "id":"22222222-2222-2222-2222-222222222222","aid":"0","net":"ws","tls":"tls","host":"us.example.com","path":"/v"
        })
        .to_string();
        let vmess = format!("vmess://{}", general_purpose::STANDARD.encode(vmess_json));

        let combined = format!("{vless}\n{trojan}\n{hy2}\n{ss}\n{vmess}");
        assert!(looks_like_share_links(&combined));
        let nodes = parse_share_links(&combined).unwrap();
        assert_eq!(nodes.len(), 5);

        assert_eq!(nodes[0]["name"], "Tokyo VLESS");
        assert_eq!(nodes[0]["type"], "vless");
        assert_eq!(nodes[0]["reality-opts"]["public-key"], "PUBKEY");
        assert_eq!(nodes[0]["flow"], "xtls-rprx-vision");

        assert_eq!(nodes[1]["name"], "HK Trojan");
        assert_eq!(nodes[1]["network"], "ws");
        assert_eq!(nodes[1]["ws-opts"]["path"], "/ws");

        assert_eq!(nodes[2]["name"], "SG Hy2");
        assert_eq!(nodes[2]["type"], "hysteria2");
        assert_eq!(nodes[2]["skip-cert-verify"], true);

        assert_eq!(nodes[3]["name"], "JP SS");
        assert_eq!(nodes[3]["cipher"], "aes-256-gcm");
        assert_eq!(nodes[3]["password"], "my-pass");

        assert_eq!(nodes[4]["name"], "US VMess");
        assert_eq!(nodes[4]["type"], "vmess");
        assert_eq!(nodes[4]["tls"], true);

        let b64_bundle = general_purpose::STANDARD.encode(&combined);
        assert!(looks_like_share_links(&b64_bundle));
        assert_eq!(parse_share_links(&b64_bundle).unwrap().len(), 5);
    }
}
