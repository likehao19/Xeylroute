use reqwest::Client;
use serde_json::{json, Value};
use std::{
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

pub const PROBE_GROUP: &str = "RoutePilot.Internal.SpeedTest";

#[derive(Clone)]
pub struct Controller {
    client: Client,
    endpoint: SocketAddr,
    token: String,
    probe_port: u16,
    pub probe_lock: Arc<tauri::async_runtime::Mutex<()>>,
}

#[derive(Default)]
pub struct LiveController(pub Mutex<Option<Controller>>);

impl Controller {
    pub fn new(endpoint: SocketAddr, token: String, probe_port: u16) -> Result<Self, String> {
        let client = Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(8))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self {
            client,
            endpoint,
            token,
            probe_port,
            probe_lock: Arc::default(),
        })
    }

    pub async fn request(
        &self,
        method: reqwest::Method,
        segments: &[&str],
        query: &[(&str, &str)],
        body: Option<Value>,
    ) -> Result<Value, String> {
        let mut url =
            reqwest::Url::parse(&format!("http://{}", self.endpoint)).map_err(|e| e.to_string())?;
        url.path_segments_mut()
            .map_err(|_| "Invalid controller URL")?
            .extend(segments);
        url.query_pairs_mut().extend_pairs(query);
        let update = method == reqwest::Method::PUT
            && matches!(segments.first(), Some(&"configs" | &"providers"));
        let mut request = self.client.request(method, url).bearer_auth(&self.token);
        if update {
            request = request.timeout(Duration::from_secs(45));
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        let mut response = request.send().await.map_err(|e| e.to_string())?;
        if let Err(error) = response.error_for_status_ref() {
            if let Ok(Some(chunk)) = response.chunk().await {
                if let Ok(message) = serde_json::from_slice::<Value>(&chunk) {
                    if let Some(message) = message["message"].as_str() {
                        return Err(message.into());
                    }
                }
            }
            return Err(error.to_string());
        }
        if response.status() == reqwest::StatusCode::NO_CONTENT
            || response.content_length() == Some(0)
        {
            return Ok(Value::Null);
        }
        response.json().await.map_err(|e| e.to_string())
    }

    pub async fn log_stream(&self) -> Result<reqwest::Response, String> {
        Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(3))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|err| err.to_string())?
            .get(format!(
                "http://{}/logs?level=info&format=structured",
                self.endpoint
            ))
            .bearer_auth(&self.token)
            .send()
            .await
            .and_then(reqwest::Response::error_for_status)
            .map_err(|err| err.to_string())
    }

    pub fn add_probe_listener(&self, config: &mut Value) -> Result<(), String> {
        let mut members = vec!["DIRECT".to_owned()];
        for key in ["proxies", "proxy-groups"] {
            for item in config[key].as_array().into_iter().flatten() {
                if let Some(name) = item["name"].as_str() {
                    if name == PROBE_GROUP {
                        return Err("配置使用了 RoutePilot 的内部测速分组名称。".into());
                    }
                    if name != "GLOBAL" {
                        members.push(name.into());
                    }
                }
            }
        }
        let providers: Vec<_> = config["proxy-providers"]
            .as_object()
            .into_iter()
            .flat_map(|items| items.keys())
            .cloned()
            .collect();
        if config.get("proxy-groups").is_none() {
            config["proxy-groups"] = json!([]);
        }
        config["proxy-groups"]
            .as_array_mut()
            .ok_or("Invalid proxy-groups")?
            .push(json!({"name":PROBE_GROUP, "type":"select", "proxies":members, "use":providers}));
        config["listeners"] = json!([{
            "name":"RoutePilot-SpeedTest", "type":"http", "listen":"127.0.0.1",
            "port":self.probe_port, "proxy":PROBE_GROUP,
            "users":[{"username":"routepilot", "password":self.token}]
        }]);
        Ok(())
    }

    async fn download(&self, name: &str) -> Result<f64, String> {
        self.request(
            reqwest::Method::PUT,
            &["proxies", PROBE_GROUP],
            &[],
            Some(json!({"name":name})),
        )
        .await?;
        let proxy = reqwest::Proxy::all(format!("http://127.0.0.1:{}", self.probe_port))
            .map_err(|err| err.to_string())?
            .basic_auth("routepilot", &self.token);
        let client = Client::builder()
            .proxy(proxy)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(10))
            .build()
            .map_err(|err| err.to_string())?;
        const SIZE: usize = 1_000_000;
        let start = Instant::now();
        let mut response = client
            .get("https://speed.cloudflare.com/__down?bytes=1000000")
            .send()
            .await
            .map_err(|err| err.to_string())?
            .error_for_status()
            .map_err(|err| err.to_string())?;
        let mut bytes = 0;
        while let Some(chunk) = response.chunk().await.map_err(|err| err.to_string())? {
            bytes += chunk.len();
            if bytes > SIZE {
                return Err("测速响应超出预期大小。".into());
            }
        }
        if bytes != SIZE {
            return Err("测速响应不完整。".into());
        }
        Ok(bytes as f64 * 8.0 / (start.elapsed().as_secs_f64().max(0.001) * 1_000_000.0))
    }
}

pub fn take(state: &LiveController) -> Result<Controller, String> {
    state
        .0
        .lock()
        .map_err(|e| e.to_string())?
        .clone()
        .ok_or("代理服务未启动。".into())
}

// The interface polls this snapshot for as long as the window is open, so every field that
// crosses the IPC bridge is paid for again on each tick. A raw `/proxies` entry carries per-URL
// health history and transport flags, and `/connections` lists every open connection; the
// interface reads a handful of fields from each, so only those are forwarded.

fn slim_proxy(entry: &Value) -> Value {
    let mut slim = serde_json::Map::new();
    for key in ["name", "type", "now", "all", "provider"] {
        if let Some(value) = entry.get(key).filter(|value| !value.is_null()) {
            slim.insert(key.into(), value.clone());
        }
    }
    if let Some(delay) = entry["history"]
        .as_array()
        .and_then(|history| history.last())
        .and_then(|latest| latest.get("delay"))
    {
        slim.insert("history".into(), json!([{ "delay": delay }]));
    }
    Value::Object(slim)
}

fn slim_proxies(raw: &Value) -> Value {
    let entries: serde_json::Map<String, Value> = raw["proxies"]
        .as_object()
        .into_iter()
        .flatten()
        .map(|(name, entry)| (name.clone(), slim_proxy(entry)))
        .collect();
    json!({ "proxies": entries })
}

fn slim_providers(raw: &Value) -> Value {
    let entries: serde_json::Map<String, Value> = raw["providers"]
        .as_object()
        .into_iter()
        .flatten()
        .map(|(name, provider)| {
            let mut slim = serde_json::Map::new();
            for key in ["name", "vehicleType", "updatedAt", "subscriptionInfo"] {
                if let Some(value) = provider.get(key).filter(|value| !value.is_null()) {
                    slim.insert(key.into(), value.clone());
                }
            }
            if let Some(proxies) = provider["proxies"].as_array() {
                let nodes: Vec<Value> = proxies
                    .iter()
                    .map(|node| json!({ "name": node.get("name"), "type": node.get("type") }))
                    .collect();
                slim.insert("proxies".into(), Value::Array(nodes));
            }
            (name.clone(), Value::Object(slim))
        })
        .collect();
    json!({ "providers": entries })
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConnectionSnapshot {
    download_total: Option<u64>,
    upload_total: Option<u64>,
    memory: Option<u64>,
    connections: Option<Vec<serde::de::IgnoredAny>>,
}

impl ConnectionSnapshot {
    fn totals(self) -> Value {
        json!({
            "downloadTotal": self.download_total, "uploadTotal": self.upload_total,
            "memory": self.memory, "count": self.connections.map_or(0, |rows| rows.len())
        })
    }
}

#[tauri::command]
pub async fn active_routes(state: tauri::State<'_, LiveController>) -> Result<Vec<Value>, String> {
    let core = take(&state)?;
    let data = core.request(reqwest::Method::GET, &["connections"], &[], None).await?;
    let rows = data["connections"].as_array().ok_or("无效的活动连接响应")?;
    Ok(rows.iter().filter(|row| {
        !row["chains"].as_array().is_some_and(|chain| chain.iter().any(|n| n.as_str() == Some(PROBE_GROUP)))
    }).map(|row| {
        let meta = &row["metadata"];
        let field = |key: &str| meta[key].as_str().unwrap_or("");
        json!({"program": field("processPath"), "process": field("process"), "host":field("host"),
            "ip":field("destinationIP"), "port":meta["destinationPort"], "network":field("network"),
            "inbound":field("type"), "rule":row["rule"], "payload":row["rulePayload"], "chains":row["chains"]})
    }).collect())
}

/// `light` skips the proxy and provider tables. They change only when a group reselects or a
/// subscription refreshes, so the interface asks for them on a slower cadence than traffic.
#[tauri::command]
pub async fn mihomo_snapshot(
    state: tauri::State<'_, LiveController>,
    light: Option<bool>,
) -> Result<Value, String> {
    let core = take(&state)?;
    let fetch = |path: &'static [&'static str]| {
        let controller = core.clone();
        tauri::async_runtime::spawn(async move {
            controller
                .request(reqwest::Method::GET, path, &[], None)
                .await
        })
    };
    let config = fetch(&["configs"]);
    let connections = core.client.get(format!("http://{}/connections", core.endpoint))
        .bearer_auth(&core.token).send();
    let tables = (!light.unwrap_or(false))
        .then(|| (fetch(&["proxies"]), fetch(&["providers", "proxies"])));

    let connections = match connections.await.and_then(reqwest::Response::error_for_status) {
        Ok(response) => response.json::<ConnectionSnapshot>().await.ok().map(ConnectionSnapshot::totals),
        Err(_) => None,
    };
    let config = config.await.map_err(|err| err.to_string())??;
    let mut snapshot = json!({
        "config": {
            "mode": config.get("mode"), "port": config.get("port"),
            "socks-port": config.get("socks-port"), "mixed-port": config.get("mixed-port")
        },
        "connections": connections,
    });
    if let Some((proxies, providers)) = tables {
        let proxies = proxies.await.map_err(|err| err.to_string())??;
        let providers = providers.await.ok().and_then(Result::ok);
        snapshot["proxies"] = slim_proxies(&proxies);
        snapshot["providers"] = providers.as_ref().map_or(Value::Null, slim_providers);
    }
    Ok(snapshot)
}

#[tauri::command]
pub async fn mihomo_delay(
    state: tauri::State<'_, LiveController>,
    name: String,
    provider: Option<String>,
    download: Option<bool>,
    target: Option<String>,
    timeout_ms: Option<u32>,
) -> Result<Value, String> {
    let url = match target.as_deref().unwrap_or("google") {
        "google" => "https://www.gstatic.com/generate_204",
        "cloudflare" => "https://cp.cloudflare.com/generate_204",
        "microsoft" => "http://www.msftconnecttest.com/connecttest.txt",
        _ => return Err("不支持的延迟测试服务".into()),
    };
    let timeout = match timeout_ms.unwrap_or(5000) {
        ms @ (2000 | 5000 | 7000) => ms.to_string(),
        _ => return Err("不支持的延迟测试超时".into()),
    };
    let core = take(&state)?;
    let route = match provider.as_deref() {
        Some(provider) => vec!["providers", "proxies", provider, &name, "healthcheck"],
        None => vec!["proxies", &name, "delay"],
    };
    let delay = core
        .request(
            reqwest::Method::GET,
            &route,
            &[("timeout", timeout.as_str()), ("url", url)],
            None,
        )
        .await
        .ok()
        .and_then(|result| result["delay"].as_u64());
    let mbps = if download.unwrap_or(true) {
        let _lock = core.probe_lock.lock().await;
        core.download(&name).await.ok()
    } else {
        None
    };
    if delay.is_none() && mbps.is_none() {
        return Err("测速失败".into());
    }
    Ok(json!({"delay":delay, "mbps":mbps}))
}

#[tauri::command]
pub async fn mihomo_select(
    state: tauri::State<'_, LiveController>,
    name: String,
) -> Result<(), String> {
    take(&state)?
        .request(
            reqwest::Method::PUT,
            &["proxies", "GLOBAL"],
            &[],
            Some(json!({ "name": name })),
        )
        .await?;
    Ok(())
}

#[tauri::command]
pub async fn mihomo_select_group(
    state: tauri::State<'_, LiveController>,
    group: String,
    name: String,
) -> Result<(), String> {
    take(&state)?
        .request(
            reqwest::Method::PUT,
            &["proxies", &group],
            &[],
            Some(json!({ "name": name })),
        )
        .await?;
    Ok(())
}

#[tauri::command]
pub async fn mihomo_refresh_provider(
    state: tauri::State<'_, LiveController>,
    name: String,
) -> Result<(), String> {
    take(&state)?
        .request(
            reqwest::Method::PUT,
            &["providers", "proxies", &name],
            &[],
            None,
        )
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proxies_keep_only_the_fields_the_interface_reads() {
        let raw = json!({"proxies": {
            "GLOBAL": {
                "name": "GLOBAL", "type": "Selector", "now": "HK 01",
                "all": ["HK 01", "DIRECT"], "alive": true, "udp": true,
                "extra": {"https://example.com": {"alive": true, "history": []}},
                "history": []
            },
            "HK 01": {
                "name": "HK 01", "type": "Trojan", "alive": true, "tfo": false,
                "history": [
                    {"time": "2026-11-20T10:00:00Z", "delay": 120},
                    {"time": "2026-11-20T10:05:00Z", "delay": 48}
                ]
            }
        }});
        let slim = slim_proxies(&raw);
        assert_eq!(
            slim["proxies"]["GLOBAL"],
            json!({"name": "GLOBAL", "type": "Selector", "now": "HK 01", "all": ["HK 01", "DIRECT"]})
        );
        assert_eq!(
            slim["proxies"]["HK 01"],
            json!({"name": "HK 01", "type": "Trojan", "history": [{"delay": 48}]})
        );
    }

    #[test]
    fn providers_keep_usage_and_node_identity() {
        let raw = json!({"providers": {
            "Home": {
                "name": "Home", "vehicleType": "HTTP", "updatedAt": "2026-11-20T10:00:00Z",
                "subscriptionInfo": {"Upload": 1, "Download": 2, "Total": 3, "Expire": 4},
                "testUrl": "https://example.com", "expectedStatus": "*",
                "proxies": [{"name": "HK 01", "type": "Trojan", "alive": true, "history": [{"delay": 48}]}]
            }
        }});
        assert_eq!(
            slim_providers(&raw)["providers"]["Home"],
            json!({
                "name": "Home", "vehicleType": "HTTP", "updatedAt": "2026-11-20T10:00:00Z",
                "subscriptionInfo": {"Upload": 1, "Download": 2, "Total": 3, "Expire": 4},
                "proxies": [{"name": "HK 01", "type": "Trojan"}]
            })
        );
    }

    #[test]
    fn connections_collapse_to_totals_and_a_count() {
        let raw = json!({
            "downloadTotal": 2048, "uploadTotal": 512, "memory": 31_000_000,
            "connections": [{"id": "a", "metadata": {"host": "example.com"}}, {"id": "b"}]
        });
        assert_eq!(
            serde_json::from_value::<ConnectionSnapshot>(raw).unwrap().totals(),
            json!({"downloadTotal": 2048, "uploadTotal": 512, "memory": 31_000_000, "count": 2})
        );
        assert_eq!(serde_json::from_value::<ConnectionSnapshot>(json!({"connections": null})).unwrap().totals()["count"], 0);
    }

    #[test]
    fn malformed_tables_slim_to_empty_maps() {
        assert_eq!(slim_proxies(&json!({})), json!({"proxies": {}}));
        assert_eq!(slim_providers(&json!({"providers": []})), json!({"providers": {}}));
    }
}
