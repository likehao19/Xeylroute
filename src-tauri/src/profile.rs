mod shared;
use shared::{mapping_requirements, shared_projection};
pub use shared::{subscription_preview, switch_with_mapping};
use serde::Deserialize;
use serde_json::{json, Value};

const BUILT_INS: &[&str] = &["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"];
const SCOPED_FIELDS: &[&str] = &[
    "rules",
    "routepilot-rule-order",
    "routepilot-shared-mapping",
    "proxy-groups",
    "routepilot-disabled-rules",
    "routepilot-disabled-groups",
    "routepilot-independent-exits",
    "routepilot-tun-groups",
    "routepilot-tun-targets",
];

pub fn tun_scope(profile: &Value) -> &str {
    match profile["routepilot-tun-scope"].as_str() {
        Some("selected") => "selected",
        _ => "all",
    }
}


/// True when this application owns the rule list being run: a profile it created, or any profile
/// narrowed to a subscription. A complete configuration the user imported is left as written.
pub fn is_managed(profile: &Value) -> bool {
    profile["routepilot-created"] == true || active_subscription(profile).is_some()
}

pub fn active_subscription(profile: &Value) -> Option<&str> {
    profile["routepilot-active-subscription"]
        .as_str()
        .filter(|name| profile["proxy-providers"].get(*name).is_some())
}

pub fn select_subscription(profile: &mut Value, name: Option<String>) -> Result<(), String> {
    if name
        .as_ref()
        .is_some_and(|name| profile["proxy-providers"].get(name).is_none())
    {
        return Err("该订阅已移除，请重新选择。".into());
    }
    let name = name.or_else(|| {
        active_subscription(profile).map(str::to_owned).or_else(|| {
            profile["proxy-providers"]
                .as_object()?
                .keys()
                .next()
                .cloned()
        })
    });
    if let Some(next) = &name {
        if entries(profile,"routepilot-shared-rules").next().is_some() {
            let preview = subscription_preview(profile,next)?;
            if !preview["missing"].as_array().is_none_or(Vec::is_empty) {
                return Err(format!("共享规则需要为这些出口选择映射：{}",preview["missing"]));
            }
        }
    }
    profile["routepilot-active-subscription"] = json!(name);
    Ok(())
}

fn scoped_profile(profile: &Value) -> std::borrow::Cow<'_, Value> {
    let Some(name) = active_subscription(profile) else {
        return std::borrow::Cow::Borrowed(profile);
    };
    let mut view = profile.clone();
    let map = view
        .as_object_mut()
        .expect("an active subscription requires an object");
    let saved = &profile["routepilot-subscription-scopes"][name];
    for &field in SCOPED_FIELDS {
        if let Some(value) = saved.get(field) {
            map.insert(field.into(), value.clone());
        } else {
            map.remove(field);
        }
    }
    map.entry("rules").or_insert_with(|| json!(["MATCH,GLOBAL"]));
    map.insert(
        "proxy-providers".into(),
        json!({name: profile["proxy-providers"][name]}),
    );
    map.insert("routepilot-created".into(), json!(true));
    std::borrow::Cow::Owned(view)
}

/// Provider proxies are not top-level Mihomo outbounds. Bind a selected node by
/// name inside its subscription, so provider refreshes also refresh its credentials.
pub fn bind_subscription_nodes(profile: &mut Value, pins: std::collections::BTreeMap<String, String>) -> Result<(), String> {
    if pins.is_empty() { return Ok(()); }
    let scope = active_subscription(profile).ok_or("请选择节点所属的订阅")?.to_owned();
    let view = scoped_profile(profile);
    let mut groups: Vec<_> = entries(&view, "proxy-groups").cloned().collect();
    let available = exits(&view);
    for (alias, node) in pins {
        if !clean(&alias) || node.trim().is_empty() || node.chars().any(char::is_control) {
            return Err("节点名称无效".into());
        }
        if let Some(group) = groups.iter().find(|g| g["name"] == alias) {
            if group["x-routepilot-node"] == node && group["use"] == json!([scope]) { continue; }
            return Err("节点出口与现有分组重名，请重新打开选择器".into());
        }
        if alias == "GLOBAL" || available.contains(&alias.as_str()) {
            return Err("节点出口名称冲突，请重新打开选择器".into());
        }
        let mut filter = String::from("^");
        for c in node.chars() {
            if c == '`' {
                filter.push_str(r"\x60");
            } else {
                if r"\.^$|?*+()[]{}".contains(c) { filter.push('\\'); }
                filter.push(c);
            }
        }
        filter.push('$');
        groups.push(json!({"name":alias, "type":"select", "use":[scope], "filter":filter,
            "hidden":true, "empty-fallback":"REJECT", "x-routepilot-node":node}));
    }
    profile["routepilot-subscription-scopes"][scope]["proxy-groups"] = json!(groups);
    Ok(())
}

pub fn edit_active(profile: &mut Value, mutation: Edit) -> Result<(), String> {
    if matches!(&mutation, Edit::SharedRule { .. } | Edit::AddProgramMatches { shared: true, .. }) {
        return edit(profile, mutation);
    }
    if let Edit::RemoveProvider { name } = &mutation {
        let name = name.clone();
        edit(profile, mutation)?;
        if let Some(scopes) = profile["routepilot-subscription-scopes"].as_object_mut() {
            scopes.remove(&name);
        }
        return select_subscription(profile, None);
    }
    if matches!(
        &mutation,
        Edit::Mode { .. }
            | Edit::Ports { .. }
            | Edit::CoreSetting { .. }
            | Edit::ProviderInterval { .. }
            | Edit::Provider { .. }
            | Edit::TunScope { .. }
            | Edit::RemoveNode { .. }
    ) {
        return edit(profile, mutation);
    }
    let Some(name) = active_subscription(profile).map(str::to_owned) else {
        return edit(profile, mutation);
    };
    let mut view = scoped_profile(profile).into_owned();
    edit(&mut view, mutation)?;
    if !mapping_requirements(&view)["missing"].as_array().is_none_or(Vec::is_empty) {
        return Err("共享规则正在使用该出口，请先更改共享规则".into());
    }
    let fields: serde_json::Map<String, Value> = SCOPED_FIELDS
        .iter()
        .filter_map(|&key| view.get(key).map(|value| (key.to_owned(), value.clone())))
        .collect();
    profile["routepilot-subscription-scopes"][name] = Value::Object(fields);
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BatchAction { Enable, Disable, Delete }

#[derive(Deserialize)]
pub struct RuleSelection {
    pub index: usize,
    pub expected: String,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Edit {
    AddProgramMatches { targets: Vec<String>, conditions: crate::rule_conditions::Conditions, exit: String, shared: bool },
    SharedRule { expected: Option<String>, conditions: Option<crate::rule_conditions::Conditions>, exit: Option<String> },
    MatchRule { index: Option<usize>, expected: Option<String>, conditions: crate::rule_conditions::Conditions, exit: String },
    RuleOrder { expected: Vec<String>, order: Option<Vec<String>> },
    BatchRules { action: BatchAction, rules: Vec<RuleSelection> },
    Mode {
        mode: String,
    },
    CoreSetting {
        key: String,
        value: Value,
    },
    ProviderInterval {
        name: String,
        seconds: u64,
    },
    Ports {
        http: u16,
        socks: u16,
        mixed: u16,
    },
    Rule {
        index: Option<usize>,
        expected: Option<String>,
        category: String,
        target: String,
        exit: String,
    },
    ProgramRules {
        targets: Vec<String>,
        exit: String,
    },
    ClearProgramRules {
        targets: Vec<String>,
    },
    RemoveRule {
        index: usize,
        expected: String,
    },
    DetachRule {
        index: usize,
        expected: String,
    },
    ToggleRule {
        index: usize,
        expected: String,
        enabled: bool,
    },
    ToggleGroup {
        name: String,
        enabled: bool,
    },
    Group {
        name: String,
        policy: String,
        members: Vec<String>,
        providers: Vec<String>,
    },
    RemoveGroup {
        name: String,
    },
    Provider {
        name: String,
        url: String,
        interval: u64,
    },
    RemoveProvider {
        name: String,
    },
    RemoveNode {
        name: String,
    },
    TunScope {
        scope: String,
    },
    ToggleGroupTun {
        name: String,
        enabled: bool,
    },
    SetRuleTun {
        target: String,
        mode: String,
    },
}

fn entries<'a>(profile: &'a Value, field: &str) -> impl Iterator<Item = &'a Value> {
    profile
        .get(field)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
}

fn names<'a>(profile: &'a Value, field: &str) -> impl Iterator<Item = &'a str> {
    entries(profile, field).filter_map(|entry| entry.get("name")?.as_str())
}

fn array<'a>(profile: &'a mut Value, field: &str) -> Result<&'a mut Vec<Value>, String> {
    let object = profile.as_object_mut().ok_or("Invalid configuration")?;
    object
        .entry(field)
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .ok_or_else(|| format!("{field} must be an array"))
}

fn clean(value: &str) -> bool {
    !value.is_empty() && value.trim() == value && !value.chars().any(|c| c == ',' || c.is_control())
}

fn program_path_key(path: &str) -> String {
    if cfg!(windows) { path.replace('\\', "/").to_lowercase() } else { path.to_owned() }
}

fn exits(profile: &Value) -> Vec<&str> {
    let mut items: Vec<_> = BUILT_INS
        .iter()
        .copied()
        .chain(names(profile, "proxies"))
        .chain(names(profile, "proxy-groups"))
        .collect();
    if !items.contains(&"AUTO")
        && (names(profile, "proxies").next().is_some()
            || profile["proxy-providers"]
                .as_object()
                .is_some_and(|items| !items.is_empty()))
    {
        items.push("AUTO");
    }
    items
}

fn matches_rule(rules: &[Value], index: usize, expected: &str) -> Result<(), String> {
    if rules.get(index).and_then(Value::as_str) != Some(expected) {
        return Err("规则已被修改。请刷新后重试。".into());
    }
    Ok(())
}

fn contains_member(group: &Value, field: &str, name: &str) -> bool {
    group
        .get(field)
        .and_then(Value::as_array)
        .is_some_and(|members| members.iter().any(|member| member.as_str() == Some(name)))
}

fn creates_cycle(profile: &Value, group: &str, members: &[String]) -> bool {
    let mut remaining: Vec<_> = members.iter().map(String::as_str).collect();
    let mut seen = std::collections::HashSet::new();
    while let Some(name) = remaining.pop() {
        if name == group {
            return true;
        }
        if seen.insert(name) {
            if let Some(entry) =
                entries(profile, "proxy-groups").find(|entry| entry["name"].as_str() == Some(name))
            {
                if let Some(children) = entry["proxies"].as_array() {
                    remaining.extend(children.iter().filter_map(Value::as_str));
                }
            }
        }
    }
    false
}

pub fn rule_exit(rule: &str) -> Option<&str> {
    let (prefix, last) = rule.rsplit_once(',')?;
    if ["no-resolve", "src"].contains(&last.trim()) {
        return prefix.rsplit_once(',').map(|(_, exit)| exit.trim());
    }
    Some(last.trim())
}

fn disabled(profile: &Value, field: &str, name: &str) -> bool {
    entries(profile, field).any(|item| item.as_str() == Some(name))
}

fn set_enabled(profile: &mut Value, field: &str, name: &str, enabled: bool) -> Result<(), String> {
    let items = array(profile, field)?;
    items.retain(|item| item.as_str() != Some(name));
    if !enabled {
        items.push(json!(name));
    }
    Ok(())
}

fn rule_priority(profile: &Value, line: &str) -> (u8, std::cmp::Reverse<usize>) {
    let (kind, tail) = line.split_once(',').unwrap_or((line, ""));
    let exit = rule_exit(line).unwrap_or("");
    let effective = entries(profile, "proxy-groups")
        .find(|group| {
            group["name"] == exit
                && group["type"] == "select"
                && group["use"].as_array().is_none_or(Vec::is_empty)
        })
        .and_then(|group| group["proxies"].as_array())
        .filter(|members| members.len() == 1)
        .and_then(|members| members[0].as_str())
        .unwrap_or(exit);
    let order = match (kind, effective) {
        ("MATCH", _) => 7,
        (_, "REJECT" | "REJECT-DROP") => 0,
        (_, "DIRECT") => 1,
        ("AND", _) => 2,
        ("PROCESS-PATH" | "PROCESS-NAME", _) => 3,
        ("DOMAIN", _) => 4,
        ("DOMAIN-SUFFIX", _) => 5,
        _ => 6,
    };
    (
        order,
        std::cmp::Reverse(if kind == "DOMAIN-SUFFIX" {
            tail.split(',').next().unwrap_or("").len()
        } else {
            0
        }),
    )
}

fn apply_rule_order(profile: &Value, rules: &mut Vec<Value>) {
    rules.retain(|item| {
        item.as_str().is_none_or(|rule| {
            let enabled = !disabled(profile, "routepilot-disabled-rules", rule)
                && !rule_exit(rule)
                    .is_some_and(|exit| disabled(profile, "routepilot-disabled-groups", exit));
            enabled || rule.starts_with("MATCH,")
        })
    });
    for item in rules.iter_mut() {
        if item.as_str().is_some_and(|rule| {
            rule.starts_with("MATCH,")
                && rule_exit(rule)
                    .is_some_and(|exit| disabled(profile, "routepilot-disabled-groups", exit))
        }) {
            *item = json!("MATCH,DIRECT");
        }
    }
    if profile["routepilot-created"] == true {
        rules.sort_by_cached_key(|rule| rule_priority(profile, rule.as_str().unwrap_or("")));
    }
}

pub fn runtime_profile(profile: &Value) -> Value {
    let catalog = profile.get("proxy-providers");
    let scoped = scoped_profile(profile);
    let profile = scoped.as_ref();
    let mut runtime = profile.clone();
    if let Some(rules) = runtime.get_mut("rules").and_then(Value::as_array_mut) {
        if is_managed(profile) {
            for (_,line) in shared_projection(profile) {
                if !rules.iter().any(|r| r.as_str() == Some(&line)) { rules.push(json!(line)); }
            }
        }
        apply_rule_order(profile, rules);
    }
    if let Some(map) = runtime.as_object_mut() {
        map.remove("routepilot-disabled-rules");
        map.remove("routepilot-disabled-groups");
        map.remove("routepilot-imported-providers");
        map.remove("routepilot-independent-exits");
        map.remove("routepilot-created");
        map.remove("routepilot-rule-order");
        map.remove("routepilot-shared-rules");
        map.remove("routepilot-shared-mapping");
        map.remove("routepilot-active-subscription");
        map.remove("routepilot-subscription-scopes");
        map.remove("routepilot-tun-scope");
        map.remove("routepilot-tun-groups");
        map.remove("routepilot-tun-targets");
    }
    let providers: Vec<_> = profile["proxy-providers"]
        .as_object()
        .into_iter()
        .flat_map(|items| items.keys())
        .cloned()
        .collect();
    let static_nodes: Vec<_> = names(profile, "proxies").collect();
    let custom_auto = names(profile, "proxies")
        .chain(names(profile, "proxy-groups"))
        .any(|name| name == "AUTO");
    let has_auto = custom_auto || !providers.is_empty() || !static_nodes.is_empty();
    if has_auto && !custom_auto {
        if let Ok(groups) = array(&mut runtime, "proxy-groups") {
            groups.push(
                json!({"name":"AUTO", "type":"url-test", "proxies":static_nodes,
                "use":providers, "url":"https://www.gstatic.com/generate_204", "interval":300}),
            );
        }
    }
    if has_auto && !names(profile, "proxy-groups").any(|name| name == "GLOBAL") {
        let pinned: std::collections::HashSet<_> = entries(profile, "proxy-groups")
            .filter(|g| g["x-routepilot-node"].is_string())
            .filter_map(|g| g["name"].as_str()).collect();
        let members = std::iter::once("AUTO")
            .chain(exits(profile).into_iter().filter(|name| *name != "AUTO"))
            .filter(|name| !pinned.contains(name) && !["PASS", "COMPATIBLE", "REJECT-DROP"].contains(name))
            .collect::<Vec<_>>();
        if let Ok(groups) = array(&mut runtime, "proxy-groups") {
            groups.push(
                json!({"name":"GLOBAL", "type":"select", "proxies":members, "use":providers}),
            );
        }
    }
    if let Some(catalog) = catalog {
        runtime["proxy-providers"] = catalog.clone();
    }
    runtime
}

/// Startup, hot reload and the order inspector all use this projection.
pub fn effective_config(catalog: &Value) -> Value {
    let mut runtime = runtime_profile(catalog);
    crate::runtime_tuning::apply(&mut runtime, is_managed(catalog));
    if !is_managed(catalog) { return runtime; }
    let view = scoped_profile(catalog);
    if let (Some(order), Some(rules)) = (view["routepilot-rule-order"].as_array(), runtime["rules"].as_array_mut()) {
        let ranks: std::collections::HashMap<_, _> = order.iter().filter_map(Value::as_str)
            .enumerate().map(|(i,line)| (line,i)).collect();
        rules.sort_by_key(|r| {
            let line = r.as_str().unwrap_or("");
            (line.starts_with("MATCH,"), ranks.get(line).copied().unwrap_or(usize::MAX))
        });
    }
    runtime
}

fn save_order(profile: &mut Value, expected: Vec<String>, order: Option<Vec<String>>) -> Result<(), String> {
    if !is_managed(profile) {return Err("完整配置使用 YAML 文件中的规则顺序".into());}
    let actual = effective_config(profile);
    if actual["rules"] != json!(expected) {return Err("生效规则已变化，请重新打开顺序面板".into());}
    if let Some(mut lines) = order {
        let mut a = expected.clone();
        let mut b = lines.clone();
        a.sort(); b.sort();
        if a != b || lines.iter().rev().skip(1).any(|s| s.starts_with("MATCH,")) {
            return Err("规则顺序无效，默认出口必须位于末尾".into());
        }
        // Keep disabled rules anchored to their nearest surviving neighbour.
        let visible: std::collections::HashSet<_> = expected.iter().collect();
        let previous: Vec<String> = entries(profile,"routepilot-rule-order").filter_map(Value::as_str).map(str::to_owned).collect();
        let mut anchor = lines.len();
        for line in previous.into_iter().rev() {
            if visible.contains(&line) {
                anchor = lines.iter().position(|item| item == &line).unwrap_or(lines.len());
            } else if entries(profile,"rules").any(|item| item.as_str() == Some(&line)) {
                lines.insert(anchor,line);
            }
        }
        profile["routepilot-rule-order"] = json!(lines);
    } else if let Some(map) = profile.as_object_mut() {map.remove("routepilot-rule-order");}
    Ok(())
}

fn is_subscription_exit(profile: &Value, group: &Value) -> bool {
    group["name"].as_str().is_some_and(|name| {
        disabled(profile, "routepilot-imported-providers", name)
            && profile["proxy-providers"].get(name).is_some()
            && group["type"] == "url-test"
            && group["use"] == json!([name])
            && group["proxies"] == json!([])
    })
}

pub fn node_metadata(nodes: &[Value]) -> Value {
    json!(nodes
        .iter()
        .filter_map(|node| {
            Some(json!({"name":node["name"].as_str()?,"type":node["type"].as_str()?}))
        })
        .collect::<Vec<_>>())
}

pub fn subscription_metadata(content: &str) -> Value {
    use base64::{engine::general_purpose, Engine};
    let decode = |input: &str| {
        general_purpose::STANDARD
            .decode(input)
            .or_else(|_| general_purpose::STANDARD_NO_PAD.decode(input))
            .or_else(|_| general_purpose::URL_SAFE_NO_PAD.decode(input))
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
    };
    let content = content.trim_start_matches('\u{feff}').trim();
    if let Ok(profile) = serde_yaml_ng::from_str::<Value>(content) {
        if let Some(nodes) = profile["proxies"].as_array() {
            return node_metadata(nodes);
        }
        if let Some(nodes) = profile.as_array() {
            return node_metadata(nodes);
        }
    }
    let decoded = if content.contains("://") {
        None
    } else {
        decode(content)
    };
    let nodes = decoded
        .as_deref()
        .unwrap_or(content)
        .lines()
        .filter_map(|line| {
            let (kind, data) = line.trim().split_once("://")?;
            if !matches!(
                kind,
                "ss" | "ssr"
                    | "vmess"
                    | "vless"
                    | "trojan"
                    | "hysteria"
                    | "hysteria2"
                    | "hy2"
                    | "tuic"
                    | "wireguard"
                    | "anytls"
            ) {
                return None;
            }
            let name = if kind == "vmess" && !data.contains('#') {
                let node: Value = serde_json::from_str(&decode(data)?).ok()?;
                node["ps"].as_str()?.to_owned()
            } else {
                let label = data.rsplit_once('#')?.1;
                reqwest::Url::parse(&format!(
                    "http://127.0.0.1/?name={}",
                    label.replace('&', "%26").replace('+', "%2B")
                ))
                .ok()?
                .query_pairs()
                .next()?
                .1
                .into_owned()
            };
            if name.is_empty() {
                return None;
            }
            Some(json!({"name":name,"type":kind}))
        })
        .collect::<Vec<_>>();
    if nodes.is_empty() {
        Value::Null
    } else {
        json!(nodes)
    }
}

pub fn summary(profile: &Value) -> Value {
    let catalog = profile;
    let scoped = scoped_profile(profile);
    let profile = scoped.as_ref();
    let runtime = effective_config(catalog);
    let active_rules = runtime["rules"].as_array().cloned().unwrap_or_default();
    let process_rules = active_rules
        .iter()
        .filter_map(Value::as_str)
        .take_while(|line| !line.starts_with("MATCH,"))
        .filter_map(|line| {
            let (kind, rest) = line.split_once(',')?;
            if !matches!(kind, "PROCESS-PATH" | "PROCESS-NAME") {
                return None;
            }
            let (target, _) = rest.split_once(',')?;
            Some(json!({"kind":kind,"target":target.trim(),"exit":rule_exit(line)?}))
        })
        .collect::<Vec<_>>();
    let node_pins: serde_json::Map<String, Value> = entries(profile, "proxy-groups")
        .filter_map(|g| Some((g["name"].as_str()?.to_owned(), json!(g["x-routepilot-node"].as_str()?))))
        .collect();
    let groups = entries(profile, "proxy-groups")
        .filter(|group| group["x-routepilot-node"].is_null() && group["name"] != "GLOBAL" && !is_subscription_exit(profile, group))
        .map(|group| {
            json!({
                "name":group.get("name"), "type":group.get("type"),
                "proxies":group.get("proxies"), "use":group.get("use"),
                "enabled":!group["name"].as_str().is_some_and(|name| disabled(profile,"routepilot-disabled-groups",name))
            })
        })
        .collect::<Vec<_>>();
    let providers = catalog.get("proxy-providers").and_then(Value::as_object).map(|providers| {
        providers.iter().map(|(name,item)| {
            let source = item["url"].as_str().and_then(|url| reqwest::Url::parse(url).ok())
                .and_then(|url| url.host_str().map(str::to_owned));
            let rule_exit_disabled = disabled(profile, "routepilot-disabled-groups", name)
                && entries(profile, "proxy-groups")
                    .any(|group| group["name"].as_str() == Some(name.as_str()) && is_subscription_exit(profile, group));
            json!({"name":name,"type":item.get("type"),"interval":item.get("interval"),"source":source,"ruleExitDisabled":rule_exit_disabled})
        }).collect::<Vec<_>>()
    }).unwrap_or_default();
    json!({
        "subscriptionScope": active_subscription(catalog),
        "subscriptionScopeInitialized": catalog.get("routepilot-active-subscription").is_some(),
        "http":profile.get("port"), "socks":profile.get("socks-port"), "mixed":profile.get("mixed-port"), "mode":profile.get("mode"),
        "coreSettings": {
            "ipv6": catalog["ipv6"].as_bool().unwrap_or(true),
            "tcp-concurrent": catalog["tcp-concurrent"].as_bool().unwrap_or(true),
            "unified-delay": catalog["unified-delay"].as_bool().unwrap_or(true),
            "log-level": catalog["log-level"].as_str().unwrap_or("info")
        },
        "sharedRules":shared_projection(profile).iter().filter_map(|(source,line)| {
            let (conditions,exit) = source.rsplit_once(',')?;
            let (kind,target) = conditions.split_once(',')?;
            Some(json!({"source":source,"line":line,"exit":exit,"conditions":crate::rule_conditions::decode(kind,target)}))
        }).collect::<Vec<_>>(),
        "effectiveRules":active_rules, "managedOrder":is_managed(catalog), "manualOrder":profile["routepilot-rule-order"].is_array(),
        "ruleConditions":entries(profile, "rules").map(|r| {
            let (prefix, _) = r.as_str()?.rsplit_once(',')?;
            let (kind,target) = prefix.split_once(',')?;
            crate::rule_conditions::decode(kind,target)
        }).collect::<Vec<_>>(),
        "rules":profile.get("rules"), "groups":groups, "providers":providers, "nodePins":node_pins, "exits":exits(profile),
        "disabledRules":profile.get("routepilot-disabled-rules"), "disabledGroups":profile.get("routepilot-disabled-groups"),
        "tunScope": tun_scope(catalog),
        "tunGroups": profile.get("routepilot-tun-groups").cloned().unwrap_or_else(|| json!([])),
        "tunTargets": profile.get("routepilot-tun-targets").cloned().unwrap_or_else(|| json!({})),
        "processRules":process_rules,
        "nodes":entries(profile,"proxies").map(|item|json!({"name":item.get("name"),"type":item.get("type")})).collect::<Vec<_>>(),
        "ruleExits":entries(profile,"rules").map(|item|item.as_str().and_then(rule_exit)).collect::<Vec<_>>()
    })
}

pub fn import_node_links(
    profile: &mut Value,
    raw: &str,
    first_profile: bool,
) -> Result<usize, String> {
    let parsed = crate::share_links::parse_share_links(raw)?;
    let mut added = 0usize;
    for mut node in parsed {
        let base_name = node["name"]
            .as_str()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("Imported Node")
            .to_owned();
        let duplicate = entries(profile, "proxies").any(|existing| {
            existing["type"] == node["type"]
                && existing["server"] == node["server"]
                && existing["port"] == node["port"]
                && existing["uuid"] == node["uuid"]
                && existing["password"] == node["password"]
        });
        if duplicate {
            continue;
        }
        let unique = subscription_name(profile, &base_name);
        node["name"] = json!(unique);
        array(profile, "proxies")?.push(node);
        added += 1;
    }
    if added > 0
        && (first_profile
            || (profile["proxy-providers"]
                .as_object()
                .is_none_or(|p| p.is_empty())
                && profile["rules"] == json!(["MATCH,DIRECT"])))
    {
        profile["rules"] = json!(["MATCH,GLOBAL"]);
    }
    Ok(added)
}

pub fn import_subscription(
    profile: &mut Value,
    url: &str,
    first_profile: bool,
) -> Result<(), String> {
    let parsed = reqwest::Url::parse(url.trim()).map_err(|_| "订阅地址无效")?;
    let host = parsed.host_str().ok_or("订阅地址无效")?;
    if profile["proxy-providers"]
        .as_object()
        .is_some_and(|providers| {
            providers
                .values()
                .any(|provider| provider["url"].as_str() == Some(parsed.as_str()))
        })
    {
        return Ok(());
    }
    let name = subscription_name(profile, &format!("订阅 · {host}"));
    edit(
        profile,
        Edit::Provider {
            name: name.clone(),
            url: parsed.into(),
            interval: 3600,
        },
    )?;
    bind_subscription(profile, &name, first_profile)
}

fn subscription_name(profile: &Value, base: &str) -> String {
    let mut name = base.to_owned();
    let mut suffix = 2;
    while exits(profile).contains(&name.as_str()) || profile["proxy-providers"].get(&name).is_some()
    {
        name = format!("{base} ({suffix})");
        suffix += 1;
    }
    name
}

pub fn import_subscription_file(
    profile: &mut Value,
    label: &str,
    path: &str,
    first_profile: bool,
) -> Result<(), String> {
    let name = subscription_name(profile, label);
    let providers = profile
        .as_object_mut()
        .ok_or("Invalid profile")?
        .entry("proxy-providers")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("Invalid providers")?;
    providers.insert(name.clone(), json!({"type":"file","path":path}));
    bind_subscription(profile, &name, first_profile)
}

fn bind_subscription(profile: &mut Value, name: &str, first_profile: bool) -> Result<(), String> {
    edit(
        profile,
        Edit::Group {
            name: name.into(),
            policy: "url-test".into(),
            members: vec![],
            providers: vec![name.into()],
        },
    )?;
    if first_profile
        || (entries(profile, "proxies").next().is_none()
            && entries(profile, "proxy-groups").count() == 1
            && profile["rules"] == json!(["MATCH,DIRECT"]))
    {
        profile["rules"] = json!(["MATCH,GLOBAL"]);
    }
    array(profile, "routepilot-imported-providers")?.push(json!(name));
    Ok(())
}

pub fn edit(profile: &mut Value, mutation: Edit) -> Result<(), String> {
    match mutation {
        Edit::AddProgramMatches { targets, conditions, exit, shared } => {
            if !(1..=250).contains(&targets.len()) {
                return Err("请选择 1 到 250 个可执行文件".into());
            }
            if !shared && conditions.target.is_empty() && conditions.port.is_empty() {
                return edit(profile, Edit::ProgramRules { targets, exit });
            }
            let mut candidate = profile.clone();
            for program in targets {
                let conditions = crate::rule_conditions::Conditions { program, ..conditions.clone() };
                if shared {
                    shared::edit_shared(&mut candidate, None, Some(conditions), Some(exit.clone()))?;
                } else {
                    edit(&mut candidate, Edit::MatchRule { index: None, expected: None, conditions, exit: exit.clone() })?;
                }
            }
            *profile = candidate;
        }
        Edit::SharedRule { expected, conditions, exit } => {
            return shared::edit_shared(profile, expected, conditions, exit);
        }
        Edit::RuleOrder { expected, order } => return save_order(profile, expected, order),
        Edit::MatchRule { index, expected, conditions, exit } => {
            let (category, target) = conditions.compile()?;
            return edit(profile, Edit::Rule { index, expected, category, target, exit });
        }
        Edit::BatchRules { action, rules } => {
            use std::collections::HashSet;
            let saved = profile["rules"].as_array().ok_or("暂无规则")?;
            let mut indices = HashSet::new();
            let mut lines = HashSet::new();
            for item in &rules {
                matches_rule(saved, item.index, &item.expected)?;
                if item.expected.starts_with("MATCH,") || !indices.insert(item.index) {
                    return Err("请选择不同的非默认规则".into());
                }
                lines.insert(item.expected.as_str());
            }
            if matches!(action, BatchAction::Delete) {
                let saved = array(profile, "rules")?;
                let mut index = 0;
                saved.retain(|_| {
                    let keep = !indices.contains(&index);
                    index += 1;
                    keep
                });
                for remaining in saved.iter().filter_map(Value::as_str) {
                    lines.remove(remaining);
                }
                if let Some(map) = profile.get_mut("routepilot-independent-exits").and_then(Value::as_object_mut) {
                    map.retain(|line, _| !lines.contains(line.as_str()));
                }
            }
            let disabled = array(profile, "routepilot-disabled-rules")?;
            disabled.retain(|r| !r.as_str().is_some_and(|line| lines.contains(line)));
            if matches!(action, BatchAction::Disable) {
                disabled.extend(lines.into_iter().map(|line| json!(line)));
            }
        }
        Edit::Mode { mode } => {
            if !["rule", "global", "direct"].contains(&mode.as_str()) {
                return Err("无效的代理模式。".into());
            }
            profile["mode"] = json!(mode);
        }
        Edit::CoreSetting { key, value } => {
            let valid = match key.as_str() {
                "ipv6" | "tcp-concurrent" | "unified-delay" => value.is_boolean(),
                "log-level" => matches!(value.as_str(), Some("debug" | "info" | "warning" | "error" | "silent")),
                _ => false,
            };
            if !valid {
                return Err("不支持的内核设置或取值".into());
            }
            profile[key] = value;
        }
        Edit::ProviderInterval { name, seconds } => {
            if seconds != 0 && !(60..=86400).contains(&seconds) {
                return Err("刷新间隔须为 1 分钟至 24 小时，或选择手动刷新".into());
            }
            let provider = profile["proxy-providers"].get_mut(&name)
                .filter(|provider| provider["type"] == "http")
                .ok_or("请选择远程订阅")?;
            provider["interval"] = json!(seconds);
        }
        Edit::Ports { http, socks, mixed } => {
            profile["port"] = json!(http);
            profile["socks-port"] = json!(socks);
            profile["mixed-port"] = json!(mixed);
        }
        Edit::Rule {
            index,
            expected,
            category,
            target,
            exit,
        } => {
            if exit != "GLOBAL" && !exits(profile).contains(&exit.as_str()) {
                return Err("请选择可用的出口".into());
            }
            let valid = match category.as_str() {
                "DOMAIN" | "DOMAIN-SUFFIX" | "IP-CIDR" | "IP-CIDR6" | "DST-PORT" | "AND" =>
                    crate::rule_conditions::decode(&category, &target).is_some(),
                "PROCESS-PATH" => clean(&target) && std::path::Path::new(&target).is_absolute(),
                "MATCH" => target.is_empty(),
                _ => false,
            };
            if !valid {
                return Err("规则目标无效".into());
            }
            let text = if category == "MATCH" {
                format!("MATCH,{exit}")
            } else {
                format!("{category},{target},{exit}")
            };
            let was_disabled = expected
                .as_deref()
                .is_some_and(|rule| disabled(profile, "routepilot-disabled-rules", rule));
            let saved_exit = expected
                .as_deref()
                .and_then(|rule| {
                    let old_exit = rule_exit(rule)?;
                    if names(profile, "proxy-groups").any(|group| group == old_exit) {
                        profile["routepilot-independent-exits"]
                            .get(rule)
                            .and_then(Value::as_str)
                    } else {
                        Some(old_exit)
                    }
                })
                .map(str::to_owned);
            let joining_group =
                category != "MATCH" && names(profile, "proxy-groups").any(|group| group == exit);
            let rules = array(profile, "rules")?;
            if category == "MATCH"
                && rules.iter().enumerate().any(|(i, r)| {
                    Some(i) != index && r.as_str().is_some_and(|r| r.starts_with("MATCH,"))
                })
            {
                return Err("已有默认出口规则，请编辑现有 MATCH".into());
            }
            if rules
                .iter()
                .enumerate()
                .any(|(i, r)| Some(i) != index && r.as_str() == Some(&text))
            {
                return Err("已有相同规则".into());
            }
            if let Some(index) = index {
                matches_rule(rules, index, expected.as_deref().unwrap_or(""))?;
                if category == "MATCH" && index + 1 != rules.len() {
                    rules.remove(index);
                    rules.push(json!(&text));
                } else {
                    rules[index] = json!(&text);
                }
            } else {
                let position = if category == "MATCH" {
                    rules.len()
                } else {
                    rules
                        .iter()
                        .position(|r| r.as_str().is_some_and(|r| r.starts_with("MATCH,")))
                        .unwrap_or(rules.len())
                };
                rules.insert(position, json!(&text));
            }
            let previous = expected.as_deref().filter(|_| index.is_some());
            if let (Some(previous),Some(order)) = (previous,profile["routepilot-rule-order"].as_array_mut()) {
                if let Some(item) = order.iter_mut().find(|item| item.as_str() == Some(previous)) { *item = json!(text); }
            }
            if let Some(map) = profile
                .get_mut("routepilot-independent-exits")
                .and_then(Value::as_object_mut)
            {
                if let Some(previous) = previous {
                    map.remove(previous);
                }
            }
            if joining_group {
                if let Some(saved_exit) = saved_exit {
                    profile
                        .as_object_mut()
                        .ok_or("Invalid configuration")?
                        .entry("routepilot-independent-exits")
                        .or_insert_with(|| json!({}))
                        .as_object_mut()
                        .ok_or("Invalid independent exits")?
                        .insert(text.clone(), json!(saved_exit));
                }
            }
            if let Some(previous) = expected.filter(|_| index.is_some() && was_disabled) {
                set_enabled(profile, "routepilot-disabled-rules", &previous, true)?;
                set_enabled(
                    profile,
                    "routepilot-disabled-rules",
                    &text,
                    category == "MATCH",
                )?;
            }
        }
        Edit::ProgramRules { targets, exit } => {
            if targets.is_empty() || targets.len() > 250 {
                return Err("请选择 1 到 250 个软件。".into());
            }
            let mut next = profile.clone();
            for target in targets {
                let normalized = program_path_key(&target);
                let previous = entries(&next, "rules")
                    .enumerate()
                    .find_map(|(index, item)| {
                        let rule = item.as_str()?;
                        let path = rule.strip_prefix("PROCESS-PATH,")?.split_once(',')?.0;
                        (program_path_key(path) == normalized)
                            .then(|| (index, rule.to_owned()))
                    });
                edit(
                    &mut next,
                    Edit::Rule {
                        index: previous.as_ref().map(|(index, _)| *index),
                        expected: previous.map(|(_, rule)| rule),
                        category: "PROCESS-PATH".into(),
                        target,
                        exit: exit.clone(),
                    },
                )?;
            }
            *profile = next;
        }
        Edit::ClearProgramRules { targets } => {
            if targets.is_empty() || targets.len() > 250 || targets.iter().any(|path| !clean(path)) {
                return Err("请选择 1 到 250 个有效的程序路径。".into());
            }
            let paths: std::collections::HashSet<_> =
                targets.iter().map(|path| program_path_key(path)).collect();
            let matches = |rule: &str| {
                rule.strip_prefix("PROCESS-PATH,").and_then(|rest| rest.split_once(','))
                    .is_some_and(|(path, _)| paths.contains(&program_path_key(path.trim())))
            };
            for field in ["rules", "routepilot-disabled-rules"] {
                if let Some(rules) = profile.get_mut(field).and_then(Value::as_array_mut) {
                    rules.retain(|rule| !rule.as_str().is_some_and(&matches));
                }
            }
            if let Some(saved) = profile.get_mut("routepilot-independent-exits").and_then(Value::as_object_mut) {
                saved.retain(|rule, _| !matches(rule));
            }
        }
        Edit::RemoveRule { index, expected } => {
            let rules = array(profile, "rules")?;
            matches_rule(rules, index, &expected)?;
            rules.remove(index);
            set_enabled(profile, "routepilot-disabled-rules", &expected, true)?;
            if let Some(map) = profile
                .get_mut("routepilot-independent-exits")
                .and_then(Value::as_object_mut)
            {
                map.remove(&expected);
            }
        }
        Edit::DetachRule { index, expected } => {
            let (category, tail) = expected.split_once(',').ok_or("无效的规则")?;
            let (target, group) = tail.rsplit_once(',').ok_or("无效的规则")?;
            if crate::rule_conditions::decode(category,target).is_none()
                || !names(profile, "proxy-groups").any(|name| name == group)
            {
                return Err("此规则请在分流规则中编辑。".into());
            }
            let exit = profile["routepilot-independent-exits"][&expected]
                .as_str()
                .filter(|exit| exits(profile).contains(exit))
                .unwrap_or("PASS")
                .to_owned();
            edit(
                profile,
                Edit::Rule {
                    index: Some(index),
                    expected: Some(expected.clone()),
                    category: category.into(),
                    target: target.into(),
                    exit,
                },
            )?;
        }
        Edit::ToggleRule {
            index,
            expected,
            enabled,
        } => {
            matches_rule(&array(profile, "rules")?[..], index, &expected)?;
            if expected.starts_with("MATCH,") {
                return Err("默认出口必须保留，可将出口设为 DIRECT。".into());
            }
            set_enabled(profile, "routepilot-disabled-rules", &expected, enabled)?;
        }
        Edit::ToggleGroup { name, enabled } => {
            if !names(profile, "proxy-groups").any(|item| item == name) {
                return Err("找不到该分组。".into());
            }
            set_enabled(profile, "routepilot-disabled-groups", &name, enabled)?;
        }
        Edit::Group {
            name,
            policy,
            members,
            providers,
        } => {
            if entries(profile, "proxy-groups").any(|g| g["name"] == name && g["x-routepilot-node"].is_string()) {
                return Err("该名称已用于节点出口，请使用其他分组名称".into());
            }
            if entries(profile, "proxy-groups").any(|group| {
                group["name"].as_str() == Some(&name) && is_subscription_exit(profile, group)
            }) {
                return Err("该名称已用于订阅出口，请使用其他分组名称。".into());
            }
            if !clean(&name)
                || name == "GLOBAL"
                || BUILT_INS.contains(&name.as_str())
                || names(profile, "proxies").any(|n| n == name)
            {
                return Err("分组名称无效或与节点冲突".into());
            }
            let available = exits(profile);
            if !["select", "url-test", "fallback"].contains(&policy.as_str())
                || (members.is_empty() && providers.is_empty())
                || providers.iter().any(|name| {
                    !profile["proxy-providers"]
                        .as_object()
                        .is_some_and(|items| items.contains_key(name))
                })
                || members
                    .iter()
                    .any(|member| !available.contains(&member.as_str()))
                || creates_cycle(profile, &name, &members)
            {
                return Err("分组类型、成员或引用无效".into());
            }
            let groups = array(profile, "proxy-groups")?;
            let found = groups
                .iter_mut()
                .find(|group| group["name"].as_str() == Some(&name));
            let mut group = found
                .as_deref()
                .cloned()
                .unwrap_or_else(|| json!({"name":name}));
            group["type"] = json!(policy);
            group["proxies"] = json!(members);
            group["use"] = json!(providers);
            if policy != "select" {
                let map = group.as_object_mut().ok_or("Invalid group")?;
                map.entry("url")
                    .or_insert_with(|| json!("https://www.gstatic.com/generate_204"));
                map.entry("interval").or_insert_with(|| json!(300));
            }
            match found {
                Some(existing) => *existing = group,
                None => groups.push(group),
            }
        }
        Edit::RemoveGroup { name } => {
            let in_rules = entries(profile, "rules")
                .filter_map(Value::as_str)
                .any(|r| rule_exit(r) == Some(&name));
            if in_rules
                || entries(profile, "proxy-groups")
                    .any(|group| contains_member(group, "proxies", &name))
            {
                return Err("分组仍被规则或其他分组引用".into());
            }
            array(profile, "proxy-groups")?.retain(|group| group["name"].as_str() != Some(&name));
            set_enabled(profile, "routepilot-disabled-groups", &name, true)?;
        }
        Edit::Provider {
            name,
            url,
            interval,
        } => {
            if !clean(&name) || !(60..=86400).contains(&interval) {
                return Err("订阅名称或刷新间隔无效".into());
            }
            let parsed = reqwest::Url::parse(&url).map_err(|_| "订阅地址无效")?;
            if parsed.scheme() != "https"
                || parsed.host_str().is_none()
                || !parsed.username().is_empty()
                || parsed.password().is_some()
            {
                return Err("订阅需要 HTTPS 地址".into());
            }
            let providers = profile
                .as_object_mut()
                .ok_or("Invalid profile")?
                .entry("proxy-providers")
                .or_insert_with(|| json!({}))
                .as_object_mut()
                .ok_or("Invalid providers")?;
            let provider = providers
                .entry(name)
                .or_insert_with(|| json!({"type":"http"}));
            if provider["type"] != "http" {
                return Err("该名称已用于不同类型的订阅".into());
            }
            provider["url"] = json!(parsed.as_str());
            provider["interval"] = json!(interval);
        }
        Edit::RemoveProvider { name } => {
            if entries(profile, "proxy-groups").any(|group| {
                group["name"].as_str() == Some(&name) && is_subscription_exit(profile, group)
            }) {
                if entries(profile, "rules")
                    .filter_map(Value::as_str)
                    .any(|rule| !rule.starts_with("MATCH,") && rule_exit(rule) == Some(&name))
                {
                    return Err("订阅出口仍被分流规则引用，请先修改相关规则。".into());
                }
                for rule in array(profile, "rules")? {
                    if rule.as_str().is_some_and(|line| {
                        line.starts_with("MATCH,") && rule_exit(line) == Some(&name)
                    }) {
                        *rule = json!("MATCH,DIRECT");
                    }
                }
                edit(profile, Edit::RemoveGroup { name: name.clone() })?;
            }
            if entries(profile, "proxy-groups").any(|group| contains_member(group, "use", &name)) {
                return Err("订阅仍被策略组引用".into());
            }
            if let Some(providers) = profile["proxy-providers"].as_object_mut() {
                providers.remove(&name);
            }
            set_enabled(profile, "routepilot-imported-providers", &name, true)?;
        }
        Edit::RemoveNode { name } => {
            if entries(profile, "rules")
                .filter_map(Value::as_str)
                .any(|r| rule_exit(r) == Some(&name))
                || entries(profile, "proxy-groups")
                    .any(|group| contains_member(group, "proxies", &name))
            {
                return Err("节点仍被规则或策略组引用，请先修改引用后再移除。".into());
            }
            array(profile, "proxies")?.retain(|node| node["name"].as_str() != Some(&name));
        }
        Edit::TunScope { scope } => {
            if !matches!(scope.as_str(), "all" | "selected") {
                return Err("无效的 TUN 接管范围。".into());
            }
            profile["routepilot-tun-scope"] = json!(scope);
        }
        Edit::ToggleGroupTun { name, enabled } => {
            if !names(profile, "proxy-groups").any(|item| item == name) {
                return Err("找不到该分组。".into());
            }
            let items = array(profile, "routepilot-tun-groups")?;
            items.retain(|item| item.as_str() != Some(&name));
            if enabled {
                items.push(json!(name));
            }
        }
        Edit::SetRuleTun { target, mode } => {
            if !clean(&target) || !matches!(mode.as_str(), "inherit" | "on" | "off") {
                return Err("无效的 TUN 规则设置。".into());
            }
            let map = profile
                .as_object_mut()
                .ok_or("Invalid configuration")?
                .entry("routepilot-tun-targets")
                .or_insert_with(|| json!({}))
                .as_object_mut()
                .ok_or("Invalid tun targets")?;
            if mode == "inherit" {
                map.remove(&target);
            } else {
                map.insert(target, json!(mode));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subscription_node_exit_roundtrips_rules_and_group_members_in_its_scope() {
        let mut catalog = json!({"proxy-providers":{"A":{"type":"inline"},"B":{"type":"inline"}},
            "routepilot-active-subscription":"A"});
        let node = "香港 [01] | A+B";
        let alias = format!("节点 · {node}");
        let pins = std::collections::BTreeMap::from([(alias.clone(), node.to_owned())]);
        bind_subscription_nodes(&mut catalog, pins.clone()).unwrap();
        bind_subscription_nodes(&mut catalog, pins).unwrap();
        edit_active(&mut catalog, Edit::MatchRule { index: None, expected: None,
            conditions: crate::rule_conditions::Conditions {target:"example.test".into(), ..Default::default()}, exit:alias.clone() }).unwrap();
        edit_active(&mut catalog, Edit::Group {name:"工作".into(), policy:"select".into(),
            members:vec![alias.clone()], providers:vec![]}).unwrap();
        let restored: Value = serde_json::from_slice(&serde_json::to_vec(&catalog).unwrap()).unwrap();
        let view = summary(&restored);
        assert_eq!(view["nodePins"][&alias], node);
        assert_eq!(view["groups"].as_array().unwrap().len(), 1);
        assert_eq!(view["groups"][0]["proxies"], json!([alias]));
        let runtime = effective_config(&restored);
        assert!(entries(&runtime, "rules").any(|r| r == &format!("DOMAIN,example.test,{alias}")));
        let pin = entries(&runtime, "proxy-groups").find(|g| g["name"] == alias).unwrap();
        assert_eq!(pin["filter"], r"^香港 \[01\] \| A\+B$");
        assert_eq!(pin["use"], json!(["A"]));
        assert_eq!(pin["empty-fallback"], "REJECT");
        select_subscription(&mut catalog, Some("B".into())).unwrap();
        assert!(!entries(&effective_config(&catalog), "proxy-groups").any(|g| g["name"] == alias));
    }

    #[test]
    fn adding_compound_rules_to_multiple_helpers_is_atomic() {
        let mut profile = json!({"rules":["MATCH,DIRECT"]});
        let root = if cfg!(windows) { "C:/Apps" } else { "/opt" };
        let batch = |second: String| Edit::AddProgramMatches {
            targets: vec![format!("{root}/app"), second],
            conditions: crate::rule_conditions::Conditions { target: "work.test".into(), ..Default::default() },
            exit: "DIRECT".into(),
            shared: false,
        };
        let before = profile.clone();
        assert!(edit_active(&mut profile, batch("relative".into())).is_err());
        assert_eq!(profile, before);
        edit_active(&mut profile, batch(format!("{root}/helper"))).unwrap();
        assert_eq!(entries(&profile, "rules").count(), 3);
    }

    #[test]
    fn network_preferences_survive_scoping_and_profile_round_trip() {
        let mut profile = json!({"proxy-providers": {
            "one": {"type":"http","url":"https://example.org/one","interval":1234,"header":{"X":["a"]}},
            "two": {"type":"file","path":"two.yaml"}
        }});
        let original_provider = profile["proxy-providers"]["one"].clone();
        select_subscription(&mut profile, Some("one".into())).unwrap();
        assert_eq!(summary(&profile)["coreSettings"]["unified-delay"], true);
        for key in ["ipv6", "tcp-concurrent", "unified-delay", "log-level"] {
            let value = if key == "log-level" { json!("warning") } else { json!(false) };
            edit_active(&mut profile, Edit::CoreSetting { key: key.into(), value }).unwrap();
        }
        edit_active(&mut profile, Edit::ProviderInterval { name: "one".into(), seconds: 0 }).unwrap();
        let mut expected = original_provider;
        expected["interval"] = json!(0);
        assert_eq!(profile["proxy-providers"]["one"], expected);
        select_subscription(&mut profile, Some("two".into())).unwrap();
        let restored: Value = serde_json::from_str(&profile.to_string()).unwrap();
        let runtime = crate::runtime_config(&restored, true);
        for key in ["ipv6", "tcp-concurrent", "unified-delay", "log-level"] {
            assert_eq!(runtime[key], restored[key]);
            assert_eq!(summary(&restored)["coreSettings"][key], restored[key]);
        }
        for (key, value) in [("allow-lan", json!(true)), ("ipv6", json!("yes")), ("log-level", json!("all"))] {
            assert!(edit_active(&mut profile, Edit::CoreSetting { key: key.into(), value }).is_err());
        }
        for (name, seconds) in [("one", 1), ("two", 3600), ("missing", 3600)] {
            assert!(edit_active(&mut profile, Edit::ProviderInterval { name: name.into(), seconds }).is_err());
        }
        assert_eq!(profile, restored);
    }

    #[test]
    fn shared_rules_require_mapping_before_switch_and_keep_local_rules_separate() {
        let mut catalog=json!({"proxy-providers":{"A":{},"B":{}},"routepilot-active-subscription":"A",
            "routepilot-subscription-scopes":{"A":{"rules":["MATCH,DIRECT"],"proxy-groups":[{"name":"Office","type":"select","proxies":["DIRECT"]}]},
            "B":{"rules":["DOMAIN,local.test,DIRECT","MATCH,DIRECT"]}}});
        edit_active(&mut catalog,Edit::SharedRule{expected:None,conditions:Some(crate::rule_conditions::Conditions{
            target:"work.test".into(),..Default::default()}),exit:Some("Office".into())}).unwrap();
        assert_eq!(subscription_preview(&catalog,"B").unwrap()["missing"],json!(["Office"]));
        let before=catalog.clone();
        assert!(switch_with_mapping(&mut catalog,Some("B".into()),Default::default()).is_err());
        assert_eq!(before,catalog);
        switch_with_mapping(&mut catalog,Some("B".into()),[("Office".into(),"REJECT".into())].into()).unwrap();
        assert!(entries(&effective_config(&catalog),"rules").any(|v|v=="DOMAIN,work.test,REJECT"));
        assert_eq!(catalog["routepilot-subscription-scopes"]["B"]["rules"],json!(["DOMAIN,local.test,DIRECT","MATCH,DIRECT"]));
    }

    #[test]
    fn manual_order_preserves_initial_order_and_can_override_lan() {
        let exception = "IP-CIDR,10.0.0.7/32,Work";
        let mut profile = json!({"routepilot-created":true, "rules":[exception,"MATCH,DIRECT"]});
        let initial: Vec<String> = serde_json::from_value(effective_config(&profile)["rules"].clone()).unwrap();
        save_order(&mut profile, initial.clone(),Some(initial.clone())).unwrap();
        assert_eq!(effective_config(&profile)["rules"], json!(initial));
        let mut changed = initial.clone();
        changed.retain(|s| s != exception);
        changed.insert(0,exception.into());
        save_order(&mut profile,initial,Some(changed.clone())).unwrap();
        assert_eq!(effective_config(&profile)["rules"],json!(changed));
        assert!(save_order(&mut profile,vec![],None).is_err());
    }

    #[test]
    fn batch_rules_validate_the_entire_selection_before_changing_the_active_scope() {
        let lines = json!(["DOMAIN,a.test,DIRECT", "DOMAIN,b.test,REJECT", "DOMAIN,c.test,DIRECT", "MATCH,DIRECT"]);
        let mut config = json!({
            "rules": lines, "routepilot-active-subscription":"test",
            "proxy-providers":{"test":{"type":"file"}},
            "routepilot-subscription-scopes":{"test":{"rules":lines}}
        });
        let bulk = |action, rules| serde_json::from_value(json!({"kind":"batchRules","action":action,"rules":rules})).unwrap();
        let selection = json!([{"index":0,"expected":lines[0]},{"index":2,"expected":lines[2]}]);
        for bad in [
            json!([selection[0], {"index":2,"expected":"stale"}]),
            json!([selection[0], {"index":3,"expected":"MATCH,DIRECT"}]),
        ] {
            let before = config.clone();
            assert!(edit_active(&mut config, bulk("delete", bad)).is_err());
            assert_eq!(config, before);
        }
        edit_active(&mut config, bulk("disable", selection.clone())).unwrap();
        assert_eq!(runtime_profile(&config)["rules"], json!([lines[1],lines[3]]));
        edit_active(&mut config, bulk("enable", selection.clone())).unwrap();
        assert_eq!(summary(&config)["disabledRules"], json!([]));
        edit_active(&mut config, bulk("delete", selection)).unwrap();
        assert_eq!(summary(&config)["rules"], json!([lines[1],lines[3]]));
        assert_eq!(config["rules"], lines);
    }

    #[test]
    fn clearing_app_exits_restores_scoped_routing_after_reload() {
        let program = "/Apps/Chat";
        let helper = "/Apps/Chat Helper";
        let retired = format!("PROCESS-PATH,{helper},DIRECT");
        let old = format!("PROCESS-PATH,{program},GLOBAL");
        let remaining = json!(["PROCESS-NAME,Chat,REJECT", "PROCESS-PATH,/Apps/Chat Beta,DIRECT", "MATCH,AUTO"]);
        let mut config = json!({
            "proxy-providers": {"One":{"type":"file"}, "Two":{"type":"file"}},
            "routepilot-active-subscription": "One",
            "routepilot-subscription-scopes": {
                "One": {
                    "rules": [old, retired, "PROCESS-NAME,Chat,REJECT", "PROCESS-PATH,/Apps/Chat Beta,DIRECT", "MATCH,AUTO"],
                    "routepilot-disabled-rules": [retired],
                    "routepilot-independent-exits": {(&old): "DIRECT"}
                },
                "Two": {"rules": [old, "MATCH,AUTO"]}
            }
        });
        for _ in 0..2 {
            edit_active(&mut config, Edit::ClearProgramRules {
                targets: vec![program.into(), helper.into()],
            }).unwrap();
        }
        let restored: Value = serde_json::from_str(&config.to_string()).unwrap();
        let scope = &restored["routepilot-subscription-scopes"]["One"];
        assert_eq!(scope["rules"], remaining);
        assert_eq!(scope["routepilot-disabled-rules"], json!([]));
        assert_eq!(scope["routepilot-independent-exits"], json!({}));
        assert_eq!(runtime_profile(&restored)["rules"], remaining);
        assert_eq!(restored["routepilot-subscription-scopes"]["Two"]["rules"], json!([old, "MATCH,AUTO"]));
    }

    #[test]
    fn subscription_scopes_keep_distinct_rules_groups_and_automatic_exits() {
        let mut config = json!({
            "rules":["MATCH,DIRECT"],
            "mode":"rule",
            "proxy-providers":{"First":{"type":"file"},"Second":{"type":"file"}}
        });
        let configure = |config: &mut Value, host: &str, member: &str| {
            edit_active(
                config,
                Edit::Group {
                    name: "开发工具".into(),
                    policy: "select".into(),
                    members: vec![member.into()],
                    providers: vec![],
                },
            )
            .unwrap();
            edit_active(
                config,
                Edit::Rule {
                    index: None,
                    expected: None,
                    category: "DOMAIN".into(),
                    target: host.into(),
                    exit: "开发工具".into(),
                },
            )
            .unwrap();
        };
        select_subscription(&mut config, Some("First".into())).unwrap();
        configure(&mut config, "first.example", "DIRECT");
        select_subscription(&mut config, Some("Second".into())).unwrap();
        assert_eq!(summary(&config)["groups"], json!([]));
        configure(&mut config, "second.example", "REJECT");
        let second_runtime = runtime_profile(&config);
        assert_eq!(
            second_runtime["rules"],
            json!(["DOMAIN,second.example,开发工具", "MATCH,GLOBAL"])
        );
        for name in ["AUTO", "GLOBAL"] {
            let group = entries(&second_runtime, "proxy-groups")
                .find(|group| group["name"] == name)
                .unwrap();
            assert_eq!(group["use"], json!(["Second"]));
        }
        select_subscription(&mut config, Some("First".into())).unwrap();
        assert_eq!(summary(&config)["groups"][0]["proxies"], json!(["DIRECT"]));
        assert_eq!(
            runtime_profile(&config)["rules"],
            json!(["DOMAIN,first.example,开发工具", "MATCH,GLOBAL"])
        );
        assert_eq!(summary(&config)["providers"].as_array().unwrap().len(), 2);
        select_subscription(&mut config, None).unwrap();
        assert_eq!(active_subscription(&config), Some("First"));
        edit_active(
            &mut config,
            Edit::RemoveProvider {
                name: "First".into(),
            },
        )
        .unwrap();
        assert_eq!(active_subscription(&config), Some("Second"));
        edit_active(
            &mut config,
            Edit::RemoveProvider {
                name: "Second".into(),
            },
        )
        .unwrap();
        assert_eq!(active_subscription(&config), None);
        assert_eq!(runtime_profile(&config)["rules"], json!(["MATCH,DIRECT"]));
        assert_eq!(summary(&config)["groups"], json!([]));
    }

    #[test]
    fn subscription_metadata_exposes_names_and_types_only() {
        let yaml = "proxies:\n  - {name: 东京, type: vless, server: example.org, uuid: hidden}";
        assert_eq!(
            subscription_metadata(yaml),
            json!([{"name":"东京","type":"vless"}])
        );
        let link = "ss://placeholder@example.org:443#Tokyo%20One";
        let encoded = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, link);
        assert_eq!(
            subscription_metadata(&encoded),
            json!([{"name":"Tokyo One","type":"ss"}])
        );
        assert_eq!(
            subscription_metadata("<html>Unavailable</html>"),
            Value::Null
        );
    }

    #[test]
    fn process_summary_respects_runtime_order_and_disabled_groups() {
        let config = json!({
            "routepilot-created":true,
            "routepilot-disabled-groups":["Off"],
            "rules":[
                "PROCESS-PATH,C:\\Tools\\tool.exe,Off",
                "PROCESS-PATH,C:\\Tools\\tool.exe,Proxy",
                "PROCESS-NAME,tool.exe,DIRECT",
                "MATCH,DIRECT"
            ]
        });
        assert_eq!(
            summary(&config)["processRules"],
            json!([
                {"kind":"PROCESS-NAME","target":"tool.exe","exit":"DIRECT"},
                {"kind":"PROCESS-PATH","target":"C:\\Tools\\tool.exe","exit":"Proxy"}
            ])
        );
    }

    #[test]
    fn runtime_applies_rule_and_group_toggles_and_keeps_rule_priority() {
        let mut config = json!({
            "routepilot-created":true,
            "proxy-groups":[{"name":"Work","type":"select","proxies":["DIRECT"]}],
            "rules":["DOMAIN,paused.example,DIRECT","DOMAIN-SUFFIX,example,DIRECT",
                "DOMAIN,blocked.example,REJECT","DOMAIN,work.example,Work","MATCH,Work"]
        });
        edit(
            &mut config,
            Edit::ToggleRule {
                index: 0,
                expected: "DOMAIN,paused.example,DIRECT".into(),
                enabled: false,
            },
        )
        .unwrap();
        edit(
            &mut config,
            Edit::ToggleGroup {
                name: "Work".into(),
                enabled: false,
            },
        )
        .unwrap();
        assert_eq!(
            runtime_profile(&config)["rules"],
            json!([
                "DOMAIN,blocked.example,REJECT",
                "DOMAIN-SUFFIX,example,DIRECT",
                "MATCH,DIRECT"
            ])
        );
        assert_eq!(summary(&config)["groups"][0]["enabled"], false);
        assert_eq!(config["rules"].as_array().unwrap().len(), 5);
    }

    #[test]
    fn detaching_a_target_restores_its_independent_exit() {
        let mut config = json!({
            "proxy-groups":[{"name":"Work","type":"select","proxies":["DIRECT"]}],
            "rules":["DOMAIN,work.example,REJECT","MATCH,DIRECT"]
        });
        edit(
            &mut config,
            Edit::Rule {
                index: Some(0),
                expected: Some("DOMAIN,work.example,REJECT".into()),
                category: "DOMAIN".into(),
                target: "work.example".into(),
                exit: "Work".into(),
            },
        )
        .unwrap();
        edit(
            &mut config,
            Edit::DetachRule {
                index: 0,
                expected: "DOMAIN,work.example,Work".into(),
            },
        )
        .unwrap();
        assert_eq!(config["rules"][0], "DOMAIN,work.example,REJECT");
    }

    #[test]
    fn built_in_import_connects_first_subscription_and_keeps_existing_routes() {
        let mut config = json!({"rules":["MATCH,DIRECT"]});
        let url = "https://example.org/sub?token=private";
        import_subscription(&mut config, url, true).unwrap();
        assert_eq!(config["rules"], json!(["MATCH,GLOBAL"]));
        assert_eq!(
            config["proxy-groups"][0]["use"],
            json!(["订阅 · example.org"])
        );
        import_subscription(&mut config, url, false).unwrap();
        assert_eq!(config["proxy-providers"].as_object().unwrap().len(), 1);
        import_subscription(&mut config, "https://example.org/second", false).unwrap();
        assert_eq!(config["rules"], json!(["MATCH,GLOBAL"]));
        assert_eq!(config["proxy-providers"].as_object().unwrap().len(), 2);
        assert!(!summary(&config).to_string().contains("private"));
    }

    #[test]
    fn subscription_exit_is_not_a_user_group() {
        let mut config = json!({"rules":["MATCH,DIRECT"]});
        import_subscription_file(&mut config, "local.yaml", "./providers/local.yaml", true)
            .unwrap();
        // Explicitly using the subscription as the fallback exercises disabling that exit.
        config["rules"] = json!(["MATCH,local.yaml"]);
        let groups = array(&mut config, "proxy-groups").unwrap();
        groups.push(json!({"name":"Work","type":"select","use":["local.yaml"]}));
        groups.push(json!({"name":"GLOBAL","type":"select","proxies":["Work"]}));
        edit(
            &mut config,
            Edit::ToggleGroup {
                name: "local.yaml".into(),
                enabled: false,
            },
        )
        .unwrap();

        let visible = summary(&config);
        assert_eq!(visible["groups"].as_array().unwrap().len(), 1);
        assert_eq!(visible["groups"][0]["name"], "Work");
        assert_eq!(visible["providers"][0]["ruleExitDisabled"], true);
        assert_eq!(visible["disabledGroups"], json!(["local.yaml"]));
        assert!(visible["exits"]
            .as_array()
            .unwrap()
            .contains(&json!("local.yaml")));
        assert_eq!(runtime_profile(&config)["rules"], json!(["MATCH,DIRECT"]));
        assert!(edit(
            &mut config,
            Edit::Group {
                name: "local.yaml".into(),
                policy: "select".into(),
                members: vec!["DIRECT".into()],
                providers: vec![],
            }
        )
        .is_err());

        edit(
            &mut config,
            Edit::ToggleGroup {
                name: "local.yaml".into(),
                enabled: true,
            },
        )
        .unwrap();
        assert_eq!(summary(&config)["providers"][0]["ruleExitDisabled"], false);
        assert_eq!(
            runtime_profile(&config)["rules"],
            json!(["MATCH,local.yaml"])
        );
    }

    #[test]
    fn inserts_rules_before_the_default_and_rejects_stale_edits() {
        let mut config = json!({"rules":["MATCH,DIRECT"]});
        edit(
            &mut config,
            Edit::Rule {
                index: None,
                expected: None,
                category: "DOMAIN".into(),
                target: "example.org".into(),
                exit: "REJECT".into(),
            },
        )
        .unwrap();
        assert_eq!(
            config["rules"],
            json!(["DOMAIN,example.org,REJECT", "MATCH,DIRECT"])
        );
        assert!(edit(
            &mut config,
            Edit::RemoveRule {
                index: 0,
                expected: "MATCH,DIRECT".into()
            }
        )
        .is_err());
    }

    #[test]
    fn protects_group_references_and_rejects_cycles() {
        let mut config = json!({"proxy-groups":[{"name":"A","type":"select","proxies":["DIRECT"]},{"name":"B","type":"select","proxies":["A"]}]});
        assert!(edit(
            &mut config,
            Edit::Group {
                name: "A".into(),
                policy: "select".into(),
                members: vec!["B".into()],
                providers: vec![]
            }
        )
        .is_err());
        assert!(edit(&mut config, Edit::RemoveGroup { name: "A".into() }).is_err());
    }

    #[test]
    fn provider_can_supply_a_group_and_cannot_be_removed_while_used() {
        let mut config = json!({"proxy-providers":{"Example":{"type":"http"}}});
        edit(
            &mut config,
            Edit::Group {
                name: "Auto".into(),
                policy: "url-test".into(),
                members: vec![],
                providers: vec!["Example".into()],
            },
        )
        .unwrap();
        assert_eq!(config["proxy-groups"][0]["use"], json!(["Example"]));
        assert!(edit(
            &mut config,
            Edit::RemoveProvider {
                name: "Example".into()
            }
        )
        .is_err());
    }

    #[test]
    fn subscription_credentials_are_not_in_the_summary() {
        let mut config = json!({});
        edit(
            &mut config,
            Edit::Provider {
                name: "Example".into(),
                url: "https://example.org/sub?token=private".into(),
                interval: 300,
            },
        )
        .unwrap();
        assert!(!summary(&config).to_string().contains("private"));
    }

    #[test]
    fn imports_single_node_share_links_and_deduplicates_safely() {
        let mut config = json!({"rules":["MATCH,DIRECT"]});
        let link = "trojan://pass@sg.example.com:443?sni=sg.example.com#SG%2001";
        let added = import_node_links(&mut config, link, true).unwrap();
        assert_eq!(added, 1);
        assert_eq!(config["proxies"][0]["name"], "SG 01");
        assert_eq!(config["rules"], json!(["MATCH,GLOBAL"]));
        // Re-importing the exact same node is a no-op
        assert_eq!(import_node_links(&mut config, link, false).unwrap(), 0);
        // Runtime profile automatically wires static nodes into AUTO & GLOBAL
        let rt = runtime_profile(&config);
        let auto = entries(&rt, "proxy-groups")
            .find(|g| g["name"] == "AUTO")
            .unwrap();
        assert_eq!(auto["proxies"], json!(["SG 01"]));
    }

    #[test]
    fn scoped_tun_preferences_are_saved_outside_the_core_configuration() {
        let mut config = json!({
            "routepilot-created": true,
            "proxy-groups": [{"name":"AI","type":"select","proxies":["DIRECT"]}],
            "rules": [
                "PROCESS-PATH,/Applications/Claude.app/Contents/MacOS/Claude,AI",
                "PROCESS-PATH,/Applications/Chrome.app/Contents/MacOS/Chrome,AI",
                "MATCH,DIRECT"
            ]
        });
        edit(
            &mut config,
            Edit::TunScope {
                scope: "selected".into(),
            },
        )
        .unwrap();
        edit(
            &mut config,
            Edit::ToggleGroupTun {
                name: "AI".into(),
                enabled: true,
            },
        )
        .unwrap();
        edit(
            &mut config,
            Edit::SetRuleTun {
                target: "/Applications/Chrome.app/Contents/MacOS/Chrome".into(),
                mode: "off".into(),
            },
        )
        .unwrap();
        edit(
            &mut config,
            Edit::SetRuleTun {
                target: "/Applications/Codex.app/Contents/MacOS/Codex".into(),
                mode: "on".into(),
            },
        )
        .unwrap();

        assert_eq!(tun_scope(&config), "selected");
        let rt = runtime_profile(&config);
        assert!(rt.get("routepilot-tun-scope").is_none());
        assert!(rt.get("routepilot-tun-groups").is_none());
        assert!(rt.get("routepilot-tun-targets").is_none());
    }
}
