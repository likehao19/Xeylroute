use serde::{Deserialize, Serialize};
use std::{net::IpAddr, path::Path};

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Conditions {
    pub program: String,
    pub target: String,
    pub suffix: bool,
    pub port: String,
}

impl Conditions {
    pub fn compile(&self) -> Result<(String, String), String> {
        let mut parts = Vec::new();
        let path = self.program.trim();
        if !path.is_empty() {
            if !Path::new(path).is_absolute()
                || path.contains(',')
                || path.chars().any(char::is_control)
            {
                return Err("请选择有效的可执行文件绝对路径".into());
            }
            parts.push(("PROCESS-PATH", path.to_owned()));
        }
        let target = self.target.trim();
        if !target.is_empty() {
            parts.push(target_condition(target, self.suffix)?);
        }
        if !self.port.trim().is_empty() {
            let port = self.port.trim();
            let (start, end) = port.split_once('-').unwrap_or((port, port));
            let number = |s: &str| s.parse::<u16>().ok().filter(|n| *n > 0);
            match (number(start), number(end)) {
                (Some(a), Some(b)) if a <= b => parts.push((
                    "DST-PORT",
                    if a == b {
                        a.to_string()
                    } else {
                        format!("{a}-{b}")
                    },
                )),
                _ => return Err("端口须为 1–65535，范围按从小到大填写".into()),
            }
        }
        match parts.len() {
            0 => Err("请填写匹配条件；所有连接的出口请在「未命中规则时」设置".into()),
            1 => {
                let (kind, value) = parts.pop().unwrap();
                Ok((kind.into(), value))
            }
            _ => {
                if path.contains(['(', ')']) {
                    return Err("此程序路径含有内核逻辑规则保留的括号，仅支持单独按路径匹配".into());
                }
                let clauses = parts
                    .iter()
                    .map(|(k, v)| format!("({k},{v})"))
                    .collect::<Vec<_>>()
                    .join(",");
                Ok(("AND".into(), format!("({clauses})")))
            }
        }
    }
}

fn target_condition(raw: &str, suffix: bool) -> Result<(&'static str, String), String> {
    let host = if raw.contains("://") {
        let url = reqwest::Url::parse(raw).map_err(|_| "网址无效")?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err("请输入 HTTP 或 HTTPS 网址".into());
        }
        url.host_str().ok_or("网址缺少主机名")?.to_owned()
    } else {
        raw.to_owned()
    };
    let (address, prefix) = host
        .split_once('/')
        .map_or((host.as_str(), None), |(a, b)| (a, Some(b)));
    let address = address
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .unwrap_or(address);
    if let Ok(ip) = address.parse::<IpAddr>() {
        let max = if ip.is_ipv4() { 32 } else { 128 };
        let bits = prefix
            .map_or(Ok(max), |p| p.parse::<u8>())
            .map_err(|_| "网段前缀无效")?;
        if bits > max {
            return Err("网段前缀超出范围".into());
        }
        let net = ipnet::IpNet::new(ip, bits).map_err(|_| "网段无效")?.trunc();
        return Ok((
            if ip.is_ipv4() { "IP-CIDR" } else { "IP-CIDR6" },
            net.to_string(),
        ));
    }
    let domain = host.trim_end_matches('.').to_ascii_lowercase();
    if domain.len() > 253
        || domain.bytes().all(|c| c.is_ascii_digit() || c == b'.')
        || domain.split('.').any(|s| {
            s.is_empty()
                || s.len() > 63
                || s.starts_with('-')
                || s.ends_with('-')
                || !s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
        })
    {
        return Err("请输入域名、IP 地址或 CIDR 网段".into());
    }
    Ok((if suffix { "DOMAIN-SUFFIX" } else { "DOMAIN" }, domain))
}

// Only expose a visual edit when all the original conditions can be represented losslessly.
pub fn decode(kind: &str, payload: &str) -> Option<Conditions> {
    let mut c = Conditions::default();
    let mut read = |kind: &str, value: &str| match kind {
        "PROCESS-PATH" if c.program.is_empty() => {
            c.program = value.into();
            true
        }
        "DOMAIN" | "DOMAIN-SUFFIX" | "IP-CIDR" | "IP-CIDR6" if c.target.is_empty() => {
            c.target = value.into();
            c.suffix = kind == "DOMAIN-SUFFIX";
            true
        }
        "DST-PORT" if c.port.is_empty() => {
            c.port = value.into();
            true
        }
        _ => false,
    };
    if kind == "AND" {
        for clause in payload.strip_prefix("((")?.strip_suffix("))")?.split("),(") {
            let (k, v) = clause.split_once(',')?;
            if !read(k, v) {
                return None;
            }
        }
    } else if !read(kind, payload) {
        return None;
    }
    let (k, v) = c.compile().ok()?;
    (k == kind && v == payload).then_some(c)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn combined_rule_roundtrips_and_rejects_invalid_targets() {
        let c = Conditions {
            target: "https://corp.example/path".into(),
            port: "440-443".into(),
            ..Default::default()
        };
        let (k, v) = c.compile().unwrap();
        assert_eq!(v, "((DOMAIN,corp.example),(DST-PORT,440-443))");
        assert_eq!(decode(&k, &v).unwrap().target, "corp.example");
        assert_eq!(
            target_condition("192.0.2.1", false).unwrap().1,
            "192.0.2.1/32"
        );
        assert_eq!(
            target_condition("2001:db8::1/64", false).unwrap().1,
            "2001:db8::/64"
        );
        for invalid in ["192.0.2.300", "192.0.2.1/39", "*.bad", "x.example,REJECT"] {
            assert!(target_condition(invalid, false).is_err());
        }
    }
}
