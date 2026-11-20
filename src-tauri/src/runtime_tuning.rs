//! Defaults layered onto the configuration handed to Mihomo, on top of what the user saved.
//!
//! Nothing here is written back to `mihomo.json`. A key the user set explicitly always wins.

use serde_json::{json, Value};
use std::collections::HashSet;

/// Destinations a remote node can never reach. Without these a profile whose default exit is a
/// proxy sends the router page, a NAS or a local dev server to that proxy, where it times out.
/// `no-resolve` keeps the rules from triggering a DNS lookup: they only match literal addresses.
const LAN_DIRECT: &[&str] = &[
    "DOMAIN,localhost,DIRECT",
    "DOMAIN-SUFFIX,local,DIRECT",
    "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
    "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
    "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
    "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
    "IP-CIDR6,::1/128,DIRECT,no-resolve",
    "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
    "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
];

/// How much faster another node must be before an automatic group leaves the current one.
/// Mihomo's default of zero reselects on every few milliseconds of jitter, and each reselect
/// moves new connections to a different exit.
const URL_TEST_TOLERANCE_MS: u64 = 50;

/// True when the rule ends in a block, either directly or through a group that can only block.
fn blocks(groups: &[Value], rule: &str) -> bool {
    let Some(exit) = crate::profile::rule_exit(rule) else {
        return false;
    };
    if matches!(exit, "REJECT" | "REJECT-DROP") {
        return true;
    }
    groups.iter().any(|group| {
        group["name"] == exit
            && group["type"] == "select"
            && group["use"].as_array().is_none_or(Vec::is_empty)
            && group["proxies"].as_array().is_some_and(|members| {
                members.len() == 1
                    && matches!(members[0].as_str(), Some("REJECT" | "REJECT-DROP"))
            })
    })
}

/// `managed` is true for profiles this application built from subscriptions and share links.
/// A complete configuration the user imported keeps its own rules and group settings.
pub fn apply(runtime: &mut Value, managed: bool) {
    let Some(map) = runtime.as_object_mut() else {
        return;
    };
    // `unified-delay` reports the round trip on an established connection instead of adding
    // each protocol's handshake to the number. `tcp-concurrent` dials every resolved address
    // at once and keeps the first to answer.
    for key in ["unified-delay", "tcp-concurrent"] {
        map.entry(key).or_insert(Value::Bool(true));
    }
    if !managed {
        return;
    }
    if let Some(groups) = map.get_mut("proxy-groups").and_then(Value::as_array_mut) {
        for group in groups {
            if group["type"] == "url-test" {
                if let Some(group) = group.as_object_mut() {
                    group
                        .entry("tolerance")
                        .or_insert(json!(URL_TEST_TOLERANCE_MS));
                }
            }
        }
    }
    let groups = map
        .get("proxy-groups")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if let Some(rules) = map.get_mut("rules").and_then(Value::as_array_mut) {
        let present: HashSet<String> = rules
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect();
        // Explicit blocks sort first and stay first: a blocked program stays blocked on the LAN.
        let position = rules
            .iter()
            .take_while(|rule| rule.as_str().is_some_and(|rule| blocks(&groups, rule)))
            .count();
        let additions: Vec<Value> = LAN_DIRECT
            .iter()
            .filter(|rule| !present.contains(**rule))
            .map(|rule| json!(rule))
            .collect();
        let _ = rules.splice(position..position, additions);
    }
}

/// TUN inbound settings. `dns-hijack` answers port 53 queries that enter the interface from
/// Mihomo's own resolver, which is what lets fake-ip map a connection back to its domain.
pub fn tun_inbound() -> Value {
    json!({
        "enable": true,
        "stack": "mixed",
        "auto-route": true,
        "auto-detect-interface": true,
        "dns-hijack": ["any:53"],
    })
}

/// Recovers the domain from the first bytes of a connection. In TUN mode an application that
/// resolved through a resolver the interface does not see arrives as a bare address, and
/// without this no domain rule can match it.
pub fn tun_sniffer() -> Value {
    json!({
        "enable": true,
        "parse-pure-ip": true,
        "sniff": {
            "HTTP": { "ports": ["80", "8080-8880"], "override-destination": true },
            "TLS": { "ports": ["443", "8443"] },
            "QUIC": { "ports": ["443", "8443"] },
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_settings_win_over_defaults() {
        let mut runtime = json!({"unified-delay": false, "rules": ["MATCH,DIRECT"]});
        apply(&mut runtime, false);
        assert_eq!(runtime["unified-delay"], false);
        assert_eq!(runtime["tcp-concurrent"], true);
    }

    #[test]
    fn imported_configurations_keep_their_rules_and_groups() {
        let mut runtime = json!({
            "proxy-groups": [{"name": "Auto", "type": "url-test", "proxies": ["A"]}],
            "rules": ["DOMAIN,example.com,Auto", "MATCH,Auto"]
        });
        apply(&mut runtime, false);
        assert_eq!(
            runtime["rules"],
            json!(["DOMAIN,example.com,Auto", "MATCH,Auto"])
        );
        assert!(runtime["proxy-groups"][0].get("tolerance").is_none());
    }

    #[test]
    fn managed_profiles_send_local_destinations_direct_after_blocks() {
        let mut runtime = json!({
            "proxy-groups": [
                {"name": "Blocked", "type": "select", "proxies": ["REJECT"]},
                {"name": "AUTO", "type": "url-test", "proxies": ["A"]},
                {"name": "Fixed", "type": "url-test", "proxies": ["A"], "tolerance": 10}
            ],
            "rules": [
                "DOMAIN,ads.example,REJECT",
                "PROCESS-PATH,/Applications/Game.app/Contents/MacOS/Game,Blocked",
                "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
                "PROCESS-PATH,/Applications/Chat.app/Contents/MacOS/Chat,AUTO",
                "MATCH,AUTO"
            ]
        });
        apply(&mut runtime, true);
        let rules: Vec<&str> = runtime["rules"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect();
        assert_eq!(rules[0], "DOMAIN,ads.example,REJECT");
        assert_eq!(
            rules[1],
            "PROCESS-PATH,/Applications/Game.app/Contents/MacOS/Game,Blocked"
        );
        assert_eq!(rules[2], "DOMAIN,localhost,DIRECT");
        assert_eq!(*rules.last().unwrap(), "MATCH,AUTO");
        // The rule the profile already carried is not added a second time.
        assert_eq!(
            rules
                .iter()
                .filter(|rule| **rule == "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve")
                .count(),
            1
        );
        assert_eq!(rules.len(), 5 + LAN_DIRECT.len() - 1);
        let chat = rules
            .iter()
            .position(|rule| rule.starts_with("PROCESS-PATH,/Applications/Chat"))
            .unwrap();
        let loopback = rules
            .iter()
            .position(|rule| *rule == "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve")
            .unwrap();
        assert!(loopback < chat);
        assert_eq!(runtime["proxy-groups"][1]["tolerance"], 50);
        assert_eq!(runtime["proxy-groups"][2]["tolerance"], 10);
    }

    #[test]
    fn tun_inbound_hijacks_dns() {
        assert_eq!(tun_inbound()["dns-hijack"], json!(["any:53"]));
        assert_eq!(tun_sniffer()["enable"], true);
    }
}
