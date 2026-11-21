use super::{
    active_subscription, array, entries, exits, rule_exit, scoped_profile, select_subscription,
};
use crate::rule_conditions::Conditions;
use serde_json::{json, Value};

/// Each subscription resolves shared exits against its own policy groups.
pub(super) fn shared_projection(view: &Value) -> Vec<(String, String)> {
    if active_subscription(view).is_none() {
        return Vec::new();
    }
    entries(view, "routepilot-shared-rules")
        .filter_map(Value::as_str)
        .filter_map(|line| {
            let (condition, exit) = line.rsplit_once(',')?;
            let mapped = view["routepilot-shared-mapping"][exit]
                .as_str()
                .unwrap_or(exit);
            Some((line.to_owned(), format!("{condition},{mapped}")))
        })
        .collect()
}

pub(super) fn mapping_requirements(view: &Value) -> Value {
    let mut available = exits(view);
    if !available.contains(&"GLOBAL") {
        available.push("GLOBAL");
    }
    let mut missing = Vec::new();
    for (original, line) in shared_projection(view) {
        let default = rule_exit(&original).unwrap_or("");
        if !available.contains(&rule_exit(&line).unwrap_or(""))
            && !missing.iter().any(|s| s == default)
        {
            missing.push(default.to_owned());
        }
    }
    json!({"missing":missing,"available":available})
}

pub fn subscription_preview(catalog: &Value, name: &str) -> Result<Value, String> {
    if catalog["proxy-providers"].get(name).is_none() {
        return Err("订阅已移除".into());
    }
    let mut candidate = catalog.clone();
    candidate["routepilot-active-subscription"] = json!(name);
    Ok(mapping_requirements(&scoped_profile(&candidate)))
}

pub fn switch_with_mapping(
    catalog: &mut Value,
    name: Option<String>,
    mapping: std::collections::HashMap<String, String>,
) -> Result<(), String> {
    let mut candidate = catalog.clone();
    if let Some(name) = name.as_ref() {
        let preview = subscription_preview(&candidate, name)?;
        for (exit, target) in mapping {
            if !entries(&preview, "missing").any(|v| v.as_str() == Some(&exit))
                || !entries(&preview, "available").any(|v| v.as_str() == Some(&target))
            {
                return Err("可用出口已变化，请重新切换订阅".into());
            }
            candidate["routepilot-subscription-scopes"][name]["routepilot-shared-mapping"][exit] =
                json!(target);
        }
    }
    select_subscription(&mut candidate, name)?;
    *catalog = candidate;
    Ok(())
}

pub(super) fn edit_shared(
    profile: &mut Value,
    expected: Option<String>,
    conditions: Option<Conditions>,
    exit: Option<String>,
) -> Result<(), String> {
    if active_subscription(profile).is_none() {
        return Err("请先选择订阅".into());
    }
    let position = expected
        .as_ref()
        .map(|old| {
            entries(profile, "routepilot-shared-rules")
                .position(|v| v.as_str() == Some(old))
                .ok_or("共享规则已变化，请重新打开")
        })
        .transpose()?;
    let replacement = if let Some(c) = conditions {
        let (kind, target) = c.compile()?;
        let exit = exit.ok_or("请选择这条共享规则的出口")?;
        let view = scoped_profile(profile);
        let mapped = view["routepilot-shared-mapping"][&exit]
            .as_str()
            .unwrap_or(&exit);
        if mapped != "GLOBAL" && !exits(&view).contains(&mapped) {
            return Err("当前订阅没有该出口".into());
        }
        let line = format!("{kind},{target},{exit}");
        if entries(profile, "routepilot-shared-rules")
            .enumerate()
            .any(|(i, v)| Some(i) != position && v.as_str() == Some(&line))
        {
            return Err("已存在相同的共享规则".into());
        }
        Some(line)
    } else {
        None
    };
    // Manual order stores effective rule lines; migrate each subscription's position.
    if let Some(old) = expected.as_deref() {
        if let Some(scopes) = profile["routepilot-subscription-scopes"].as_object_mut() {
            for scope in scopes.values_mut() {
                let mapped = |rule: &str| -> Option<String> {
                    let (condition, exit) = rule.rsplit_once(',')?;
                    let target = scope["routepilot-shared-mapping"][exit]
                        .as_str()
                        .unwrap_or(exit);
                    Some(format!("{condition},{target}"))
                };
                let old_line = mapped(old);
                let new_line = replacement.as_deref().and_then(mapped);
                if entries(scope, "rules").any(|v| v.as_str() == old_line.as_deref()) {
                    continue;
                }
                if let Some(order) = scope["routepilot-rule-order"].as_array_mut() {
                    if let Some(pos) = order.iter().position(|v| v.as_str() == old_line.as_deref())
                    {
                        if let Some(line) = new_line {
                            order[pos] = json!(line);
                        } else {
                            order.remove(pos);
                        }
                    }
                }
            }
        }
    }
    let rules = array(profile, "routepilot-shared-rules")?;
    match (position, replacement) {
        (Some(i), Some(line)) => rules[i] = json!(line),
        (Some(i), None) => {
            rules.remove(i);
        }
        (None, Some(line)) => rules.push(json!(line)),
        (None, None) => return Err("请选择要移除的共享规则".into()),
    }

    Ok(())
}
