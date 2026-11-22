use serde_json::Value;

pub const FILENAME: &str = "mihomo.backup.json";
const DPAPI_FORMAT: &str = "xeylroute-windows-dpapi";

pub fn encode(config: &str) -> Result<Vec<u8>, String> {
    #[cfg(windows)]
    {
        use base64::{engine::general_purpose::STANDARD, Engine as _};
        let encrypted = dpapi(config.as_bytes(), true)
            .map_err(|err| format!("Windows 无法加密配置备份。{err}"))?;
        serde_json::to_vec(&serde_json::json!({
            "format": DPAPI_FORMAT,
            "version": 1,
            "data": STANDARD.encode(encrypted),
        }))
        .map_err(|err| err.to_string())
    }
    #[cfg(not(windows))]
    {
        Ok(config.as_bytes().to_vec())
    }
}

pub fn decode(bytes: &[u8]) -> Result<Value, String> {
    let backup: Value = serde_json::from_slice(bytes).map_err(|err| err.to_string())?;
    if backup.get("format").and_then(Value::as_str) != Some(DPAPI_FORMAT) {
        return Ok(backup);
    }
    #[cfg(windows)]
    {
        use base64::{engine::general_purpose::STANDARD, Engine as _};
        if backup["version"].as_u64() != Some(1) {
            return Err("配置备份版本不受支持。".into());
        }
        let encrypted = backup["data"].as_str().ok_or("配置备份数据缺失。")?;
        let encrypted = STANDARD
            .decode(encrypted)
            .map_err(|_| "配置备份数据已损坏。")?;
        let config = dpapi(&encrypted, false)
            .map_err(|err| format!("无法解密配置备份。请使用创建备份的 Windows 用户。{err}"))?;
        serde_json::from_slice(&config).map_err(|err| err.to_string())
    }
    #[cfg(not(windows))]
    {
        Err("请在创建备份的 Windows 账户下恢复这份配置。".into())
    }
}

#[cfg(windows)]
fn dpapi(bytes: &[u8], encrypt: bool) -> std::io::Result<Vec<u8>> {
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::Cryptography::{
            CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        },
    };

    let input = CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(bytes.len())
            .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidInput, err))?,
        pbData: bytes.as_ptr().cast_mut(),
    };
    let mut output = CRYPT_INTEGER_BLOB::default();
    // DPAPI reads the input blob and transfers ownership of the result to the caller.
    unsafe {
        let ok = if encrypt {
            CryptProtectData(
                &input,
                null(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                null_mut(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        if ok == 0 {
            return Err(std::io::Error::last_os_error());
        }
        if output.pbData.is_null() {
            return Ok(Vec::new());
        }
        let result = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        LocalFree(output.pbData.cast());
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restores_legacy_and_current_backups() {
        let config =
            r#"{"proxy-providers":{"private":{"url":"https://example.com/?token=sample-secret"}}}"#;
        let legacy = decode(config.as_bytes()).unwrap();
        let current = encode(config).unwrap();
        assert_eq!(decode(&current).unwrap(), legacy);
        #[cfg(windows)]
        {
            let text = std::str::from_utf8(&current).unwrap();
            assert!(text.contains(DPAPI_FORMAT));
            assert!(!text.contains("sample-secret"));
        }
    }
}
