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
        let mut response = client
            .get("https://speed.cloudflare.com/__down?bytes=1000000")
            .send()
            .await
            .map_err(|err| err.to_string())?
            .error_for_status()
            .map_err(|err| err.to_string())?;
        let start = Instant::now();
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

#[tauri::command]
pub async fn mihomo_snapshot(state: tauri::State<'_, LiveController>) -> Result<Value, String> {
    let core = take(&state)?;
    let paths: [&[&str]; 5] = [
        &["configs"],
        &["proxies"],
        &["connections"],
        &["rules"],
        &["providers", "proxies"],
    ];
    let [config, proxies, connections, rules, providers] = paths.map(|path| {
        let controller = core.clone();
        tauri::async_runtime::spawn(async move {
            controller
                .request(reqwest::Method::GET, path, &[], None)
                .await
        })
    });
    let config = config.await.map_err(|err| err.to_string())??;
    let proxies = proxies.await.map_err(|err| err.to_string())??;
    let connections = connections.await.ok().and_then(Result::ok);
    let rules = rules.await.ok().and_then(Result::ok);
    let providers = providers.await.ok().and_then(Result::ok);
    let config = json!({
        "mode": config.get("mode"), "port": config.get("port"),
        "socks-port": config.get("socks-port"), "mixed-port": config.get("mixed-port")
    });
    Ok(json!({
        "config":config, "proxies":proxies, "connections":connections,
        "rules":rules, "providers":providers
    }))
}

#[tauri::command]
pub async fn mihomo_delay(
    state: tauri::State<'_, LiveController>,
    name: String,
    provider: Option<String>,
) -> Result<Value, String> {
    let core = take(&state)?;
    let _lock = core.probe_lock.lock().await;
    let route = match provider.as_deref() {
        Some(provider) => vec!["providers", "proxies", provider, &name, "healthcheck"],
        None => vec!["proxies", &name, "delay"],
    };
    let delay = core
        .request(
            reqwest::Method::GET,
            &route,
            &[
                ("timeout", "5000"),
                ("url", "https://www.gstatic.com/generate_204"),
            ],
            None,
        )
        .await
        .ok()
        .and_then(|result| result["delay"].as_u64());
    let mbps = core.download(&name).await.ok();
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
