use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Cursor, Read},
    path::Path,
    time::Duration,
};

const MAX_DOWNLOAD: usize = 8 * 1024 * 1024;
const FILES: [(&str, &str); 2] = [
    (
        "WinDivert.dll",
        "c1e060ee19444a259b2162f8af0f3fe8c4428a1c6f694dce20de194ac8d7d9a2",
    ),
    (
        "WinDivert64.sys",
        "8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2",
    ),
];

fn verify(data: &[u8], expected: &str) -> Result<(), String> {
    if format!("{:x}", Sha256::digest(data)) != expected {
        return Err("WinDivert SHA-256 校验失败。".into());
    }
    Ok(())
}

fn ready(dir: &Path) -> bool {
    FILES.iter().all(|(name, digest)| {
        fs::read(dir.join(name)).is_ok_and(|data| verify(&data, digest).is_ok())
    })
}

async fn download(client: &reqwest::Client, url: &str, digest: &str) -> Result<Vec<u8>, String> {
    let mut response = client
        .get(url)
        .send()
        .await
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?;
    let mut data = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        if data.len() + chunk.len() > MAX_DOWNLOAD {
            return Err("WinDivert 下载文件超过大小限制。".into());
        }
        data.extend_from_slice(&chunk);
    }
    verify(&data, digest)?;
    Ok(data)
}

fn unpack(archive: &[u8]) -> Result<Vec<(&'static str, Vec<u8>)>, String> {
    let mut zip = zip::ZipArchive::new(Cursor::new(archive)).map_err(|e| e.to_string())?;
    let mut files = Vec::new();
    for (name, digest) in FILES {
        let mut data = Vec::new();
        zip.by_name(&format!("WinDivert-2.2.2-A/x64/{name}"))
            .map_err(|e| e.to_string())?
            .take(MAX_DOWNLOAD as u64 + 1)
            .read_to_end(&mut data)
            .map_err(|e| e.to_string())?;
        verify(&data, digest)?;
        files.push((name, data));
    }
    let mut license = Vec::new();
    zip.by_name("WinDivert-2.2.2-A/LICENSE")
        .map_err(|e| e.to_string())?
        .take(MAX_DOWNLOAD as u64 + 1)
        .read_to_end(&mut license)
        .map_err(|e| e.to_string())?;
    if license.len() > MAX_DOWNLOAD {
        return Err("WinDivert 许可证超过大小限制。".into());
    }
    files.push(("WinDivert-LICENSE.txt", license));
    Ok(files)
}

/// Called only when selected-program TUN is explicitly enabled. No driver is
/// downloaded, extracted or loaded by the normal application startup path.
pub async fn ensure(dir: &Path) -> Result<(), String> {
    if ready(dir) {
        return Ok(());
    }
    prepare(dir).await.map_err(|error| format!(
        "指定软件 TUN 驱动准备失败：{error} 请检查网络或 Windows 安全中心的保护历史记录。普通代理和全局 TUN 无需此驱动。"
    ))
}

async fn prepare(dir: &Path) -> Result<(), String> {
    let lock: serde_json::Value =
        serde_json::from_str(include_str!("../../scripts/core-lock.json"))
            .map_err(|e| e.to_string())?;
    let version = lock["winDivert"]["version"]
        .as_str()
        .ok_or("Missing WinDivert version")?;
    let digest = lock["winDivert"]["binary"]
        .as_str()
        .ok_or("Missing WinDivert digest")?;
    let source_digest = lock["winDivert"]["source"]
        .as_str()
        .ok_or("Missing WinDivert source digest")?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(180))
        .build()
        .map_err(|e| e.to_string())?;
    let archive = download(
        &client,
        &format!(
            "https://github.com/basil00/WinDivert/releases/download/{version}/WinDivert-{}-A.zip",
            version.trim_start_matches('v')
        ),
        digest,
    )
    .await?;
    let files = unpack(&archive)?;
    let source = download(
        &client,
        &format!("https://codeload.github.com/basil00/WinDivert/tar.gz/refs/tags/{version}"),
        source_digest,
    )
    .await?;
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    fs::write(dir.join("WinDivert-source.tar.gz"), source).map_err(|e| e.to_string())?;
    for (name, data) in files {
        fs::write(dir.join(name), data).map_err(|e| e.to_string())?;
    }
    if !ready(dir) {
        return Err("驱动文件写入后无法读取或校验失败。".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn rejects_tampered_download() {
        let expected = format!("{:x}", Sha256::digest(b"official archive"));
        assert!(verify(b"official archive", &expected).is_ok());
        assert!(verify(b"modified archive", &expected).is_err());
    }

    #[test]
    fn rejects_missing_or_tampered_driver_in_zip() {
        let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
        zip.start_file("unrelated.txt", zip::write::SimpleFileOptions::default())
            .unwrap();
        zip.write_all(b"unrelated").unwrap();
        let missing = zip.finish().unwrap().into_inner();
        assert!(unpack(&missing).is_err());

        let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
        zip.start_file(
            "WinDivert-2.2.2-A/x64/WinDivert.dll",
            zip::write::SimpleFileOptions::default(),
        )
        .unwrap();
        zip.write_all(b"tampered driver").unwrap();
        assert!(unpack(&zip.finish().unwrap().into_inner())
            .unwrap_err()
            .contains("SHA-256"));
    }

    #[test]
    #[ignore = "Downloads the official driver; run only in an isolated Windows environment"]
    fn prepare_driver_from_release() {
        let dir = std::env::var_os("WINDIVERT_TEST_DIR")
            .map(std::path::PathBuf::from)
            .expect("Set WINDIVERT_TEST_DIR to the test driver directory");
        tauri::async_runtime::block_on(ensure(&dir)).unwrap();
        assert!(ready(&dir));
        // A valid cache needs no network.
        tauri::async_runtime::block_on(ensure(&dir)).unwrap();
    }
}
