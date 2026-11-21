use serde::Serialize;
use serde_json::Value;
use std::{collections::VecDeque, sync::Mutex};
use tauri::{AppHandle, Manager, State};

#[derive(Clone, Serialize, PartialEq)]
pub struct ConnectionRow {
    time: String,
    app: String,
    target: String,
    protocol: String,
    exit: String,
    decision: String,
    failed: bool,
}

#[derive(Default)]
pub struct ConnectionLog(Mutex<VecDeque<ConnectionRow>>);

fn route_event(event: Value) -> Option<ConnectionRow> {
    let message = event["message"].as_str()?;
    let (protocol, route) = message.strip_prefix('[')?.split_once("] ")?;
    if !["TCP", "UDP"].contains(&protocol) {
        return None;
    }
    let (source, right) = route.split_once(" --> ")?;
    let (target, rest) = right.split_once(' ')?;
    let failure = rest.strip_prefix("error: ");
    let (source, exit, decision) = if let Some(error) = failure {
        let attempt = source.strip_prefix("dial ")?;
        let origin_end = attempt
            .rfind('(')
            .filter(|_| attempt.ends_with(')'))
            .unwrap_or(attempt.len());
        let origin_start = attempt[..origin_end].rfind(' ')?;
        let (exit, origin) = (&attempt[..origin_start], &attempt[origin_start + 1..]);
        let (exit, rule) = exit
            .split_once(" (match ")
            .map_or((exit, ""), |(exit, decision)| {
                (exit, decision.trim_end_matches(')'))
            });
        (
            origin,
            exit,
            if rule.is_empty() {
                error.to_owned()
            } else {
                format!("{rule} · {error}")
            },
        )
    } else {
        let (decision, exit) = rest.split_once("using ")?;
        (
            source,
            exit,
            decision.trim().trim_start_matches("match ").to_owned(),
        )
    };
    if exit.contains("RoutePilot.Internal.SpeedTest") {
        return None;
    }
    let name = source
        .split_once('(')
        .and_then(|(_, name)| name.strip_suffix(')'))
        .map(|name| name.split(", uid=").next().unwrap_or(name))
        .filter(|name| !name.starts_with("uid="))
        .unwrap_or("");
    Some(ConnectionRow {
        time: event["time"].as_str()?.into(),
        app: name.into(),
        target: target.into(),
        protocol: protocol.into(),
        exit: exit.into(),
        decision,
        failed: failure.is_some(),
    })
}

pub async fn collect(app: AppHandle, mut response: reqwest::Response) {
    let mut buffer = Vec::new();
    while let Ok(Some(chunk)) = response.chunk().await {
        buffer.extend(chunk);
        let Some(last) = buffer.iter().rposition(|byte| *byte == b'\n') else {
            if buffer.len() > 64 * 1024 {
                buffer.clear();
            }
            continue;
        };
        let state = app.state::<ConnectionLog>();
        let Ok(mut rows) = state.0.lock() else { return };
        for line in buffer[..last].split(|byte| *byte == b'\n') {
            if let Some(row) = serde_json::from_slice(line).ok().and_then(route_event) {
                rows.push_back(row);
                if rows.len() > 500 {
                    rows.pop_front();
                }
            }
        }
        buffer.drain(..=last);
    }
}

#[tauri::command]
pub fn connection_log_rows(
    state: State<'_, ConnectionLog>,
    clear: bool,
) -> Result<Vec<ConnectionRow>, String> {
    let mut rows = state.0.lock().map_err(|err| err.to_string())?;
    if clear {
        rows.clear();
    }
    Ok(rows.iter().rev().cloned().collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn records_short_connections_and_routing_failures() {
        let event = |message| route_event(json!({"time":"11:00:00","message":message})).unwrap();
        let success = event("[TCP] 127.0.0.1:1234(App.exe) --> example.com:443 match Domain(example.com) using Group[Node]");
        assert_eq!(success.app, "App.exe");
        assert_eq!(success.exit, "Group[Node]");
        assert_eq!(success.decision, "Domain(example.com)");
        let failure = event("[TCP] dial Work Group (match Domain/example.com) 127.0.0.1:1234(App.exe) --> example.com:443 error: timeout");
        assert_eq!(failure.exit, "Work Group");
        assert_eq!(failure.decision, "Domain/example.com · timeout");
    }
}
