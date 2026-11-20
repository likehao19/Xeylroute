use std::path::Path;

#[cfg(windows)]
mod platform {
    use base64::{engine::general_purpose::STANDARD, Engine};
    use std::{ffi::c_void, mem::size_of, os::windows::ffi::OsStrExt, path::Path, ptr, sync::OnceLock};
    use windows_sys::Win32::{
        Graphics::Gdi::{
            CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GdiFlush, SelectObject,
            BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
        },
        Storage::FileSystem::{GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW},
        UI::{
            Shell::{
                ExtractIconExW, SHGetStockIconInfo, SHGSI_ICON, SHSTOCKICONINFO, SIID_APPLICATION,
            },
            WindowsAndMessaging::{DestroyIcon, DrawIconEx, DI_NORMAL, HICON},
        },
    };

    pub fn read(path: &Path) -> (Option<String>, Option<String>) {
        let path: Vec<u16> = path.as_os_str().encode_wide().chain([0]).collect();
        (
            description(&path),
            icon(&path).or_else(|| application_icon().clone()),
        )
    }

    fn application_icon() -> &'static Option<String> {
        static ICON: OnceLock<Option<String>> = OnceLock::new();
        ICON.get_or_init(|| {
            let mut info = SHSTOCKICONINFO {
                cbSize: size_of::<SHSTOCKICONINFO>() as u32,
                ..Default::default()
            };
            if unsafe { SHGetStockIconInfo(SIID_APPLICATION, SHGSI_ICON, &mut info) } < 0
                || info.hIcon.is_null()
            {
                return None;
            }
            icon_from_handle(info.hIcon)
        })
    }

    fn description(path: &[u16]) -> Option<String> {
        let mut unused = 0;
        let size = unsafe { GetFileVersionInfoSizeW(path.as_ptr(), &mut unused) };
        if size == 0 || size > 1024 * 1024 {
            return None;
        }
        let mut data = vec![0_u8; size as usize];
        if unsafe { GetFileVersionInfoW(path.as_ptr(), 0, size, data.as_mut_ptr().cast()) } == 0 {
            return None;
        }
        let mut value: *mut c_void = ptr::null_mut();
        let mut length = 0;
        let translations: Vec<u16> = "\\VarFileInfo\\Translation"
            .encode_utf16()
            .chain([0])
            .collect();
        let mut locales = Vec::new();
        if unsafe {
            VerQueryValueW(
                data.as_ptr().cast(),
                translations.as_ptr(),
                &mut value,
                &mut length,
            )
        } != 0
            && !value.is_null()
        {
            for pair in unsafe { std::slice::from_raw_parts(value.cast::<u8>(), length as usize) }
                .chunks_exact(4)
            {
                locales.push((
                    u16::from_le_bytes([pair[0], pair[1]]),
                    u16::from_le_bytes([pair[2], pair[3]]),
                ));
            }
        }
        locales.push((0x0409, 0x04b0));
        for (language, codepage) in locales {
            let query: Vec<u16> =
                format!("\\StringFileInfo\\{language:04x}{codepage:04x}\\FileDescription")
                    .encode_utf16()
                    .chain([0])
                    .collect();
            if unsafe {
                VerQueryValueW(
                    data.as_ptr().cast(),
                    query.as_ptr(),
                    &mut value,
                    &mut length,
                )
            } == 0
                || value.is_null()
                || !(2..512).contains(&length)
            {
                continue;
            }
            let units: Vec<u16> =
                unsafe { std::slice::from_raw_parts(value.cast::<u8>(), length as usize * 2) }
                    .chunks_exact(2)
                    .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
                    .take_while(|unit| *unit != 0)
                    .collect();
            let name = String::from_utf16_lossy(&units);
            let name = name.trim();
            if !name.is_empty() {
                return Some(name.to_owned());
            }
        }
        None
    }

    pub(crate) fn icon(path: &[u16]) -> Option<String> {
        let mut hicon = ptr::null_mut();
        if unsafe { ExtractIconExW(path.as_ptr(), 0, &mut hicon, ptr::null_mut(), 1) } != 1
            || hicon.is_null()
        {
            return None;
        }
        icon_from_handle(hicon)
    }

    fn icon_from_handle(hicon: HICON) -> Option<String> {
        const SIDE: usize = 32;
        let bitmap = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: SIDE as i32,
                biHeight: SIDE as i32,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB,
                ..Default::default()
            },
            ..Default::default()
        };
        let result = unsafe {
            let dc = CreateCompatibleDC(ptr::null_mut());
            let mut bits: *mut c_void = ptr::null_mut();
            let dib = CreateDIBSection(dc, &bitmap, DIB_RGB_COLORS, &mut bits, ptr::null_mut(), 0);
            let mut result = None;
            if !dib.is_null() && !bits.is_null() && !dc.is_null() {
                ptr::write_bytes(bits.cast::<u8>(), 0, SIDE * SIDE * 4);
                let previous = SelectObject(dc, dib);
                if !previous.is_null()
                    && DrawIconEx(
                        dc,
                        0,
                        0,
                        hicon,
                        SIDE as i32,
                        SIDE as i32,
                        0,
                        ptr::null_mut(),
                        DI_NORMAL,
                    ) != 0
                {
                    GdiFlush();
                    let pixels = std::slice::from_raw_parts(bits.cast::<u8>(), SIDE * SIDE * 4);
                    if pixels.iter().any(|pixel| *pixel != 0) {
                        result = Some(encode_icon(pixels));
                    }
                }
                if !previous.is_null() {
                    SelectObject(dc, previous);
                }
            }
            if !dib.is_null() {
                DeleteObject(dib);
            }
            if !dc.is_null() {
                DeleteDC(dc);
            }
            DestroyIcon(hicon);
            result
        };
        result
    }

    fn encode_icon(pixels: &[u8]) -> String {
        let mut bytes = vec![0, 0, 1, 0, 1, 0, 32, 32, 0, 0, 1, 0, 32, 0];
        bytes.extend((40 + 4096 + 128_u32).to_le_bytes());
        bytes.extend(22_u32.to_le_bytes());
        bytes.extend(40_u32.to_le_bytes());
        bytes.extend(32_u32.to_le_bytes());
        bytes.extend(64_u32.to_le_bytes());
        bytes.extend([1, 0, 32, 0]);
        bytes.resize(62, 0);
        let alpha = pixels.chunks_exact(4).any(|pixel| pixel[3] > 0);
        for pixel in pixels.chunks_exact(4) {
            if alpha {
                let a = u16::from(pixel[3]);
                bytes.extend(pixel[..3].iter().map(|v| {
                    if a == 0 {
                        0
                    } else {
                        (u16::from(*v) * 255 / a).min(255) as u8
                    }
                }));
                bytes.push(pixel[3]);
            } else {
                bytes.extend([
                    pixel[0],
                    pixel[1],
                    pixel[2],
                    255 * u8::from(pixel[..3] != [0; 3]),
                ]);
            }
        }
        bytes.resize(62 + 4096 + 128, 0);
        format!("data:image/x-icon;base64,{}", STANDARD.encode(bytes))
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use base64::{engine::general_purpose::STANDARD, Engine};
    use serde_json::Value;
    use std::{
        collections::HashMap,
        fs,
        path::{Path, PathBuf},
        process::Command,
        sync::{Mutex, OnceLock},
    };

    type BundleCache = Mutex<HashMap<PathBuf, (Option<String>, Option<String>)>>;

    fn cache() -> &'static BundleCache {
        static CACHE: OnceLock<BundleCache> = OnceLock::new();
        CACHE.get_or_init(|| Mutex::new(HashMap::new()))
    }

    pub(crate) fn enclosing_app_bundle(path: &Path) -> Option<PathBuf> {
        let mut cursor = Some(path);
        while let Some(dir) = cursor {
            if dir
                .extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case("app"))
            {
                return Some(dir.to_path_buf());
            }
            cursor = dir.parent();
        }
        None
    }

    fn render_icns_png(icns: &Path) -> Option<String> {
        if !icns.is_file() {
            return None;
        }
        let mut random = [0u8; 8];
        getrandom::fill(&mut random).ok()?;
        let id: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let out = std::env::temp_dir().join(format!("routepilot-icon-{id}.png"));
        let output = Command::new("/usr/bin/sips")
            .args(["-s", "format", "png", "-Z", "32"])
            .arg(icns)
            .arg("--out")
            .arg(&out)
            .output()
            .ok()?;
        let data = if output.status.success() {
            fs::read(&out).ok()
        } else {
            None
        };
        let _ = fs::remove_file(&out);
        data.filter(|bytes| !bytes.is_empty())
            .map(|bytes| format!("data:image/png;base64,{}", STANDARD.encode(bytes)))
    }

    fn read_bundle(bundle: &Path) -> (Option<String>, Option<String>) {
        let plist = bundle.join("Contents/Info.plist");
        let fallback_name = bundle
            .file_stem()
            .and_then(|s| s.to_str())
            .map(str::to_owned);
        let Ok(output) = Command::new("/usr/bin/plutil")
            .args(["-convert", "json", "-o", "-"])
            .arg(&plist)
            .output()
        else {
            return (fallback_name, None);
        };
        if !output.status.success() {
            return (fallback_name, None);
        }
        let Ok(info) = serde_json::from_slice::<Value>(&output.stdout) else {
            return (fallback_name, None);
        };
        let name = info["CFBundleDisplayName"]
            .as_str()
            .or_else(|| info["CFBundleName"].as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .or(fallback_name);
        let icon = info["CFBundleIconFile"]
            .as_str()
            .or_else(|| info["CFBundleIconName"].as_str())
            .and_then(|file| {
                let resources = bundle.join("Contents/Resources");
                let candidate = if file.ends_with(".icns") {
                    resources.join(file)
                } else {
                    resources.join(format!("{file}.icns"))
                };
                render_icns_png(&candidate)
            });
        (name, icon)
    }

    pub fn read(path: &Path) -> (Option<String>, Option<String>) {
        let Some(bundle) = enclosing_app_bundle(path) else {
            return (None, None);
        };
        if let Ok(guard) = cache().lock() {
            if let Some(hit) = guard.get(&bundle) {
                return hit.clone();
            }
        }
        let value = read_bundle(&bundle);
        if let Ok(mut guard) = cache().lock() {
            guard.insert(bundle, value.clone());
        }
        value
    }
}

#[cfg(all(not(windows), not(target_os = "macos")))]
mod platform {
    use std::path::Path;

    pub fn read(_path: &Path) -> (Option<String>, Option<String>) {
        (None, None)
    }
}

pub fn read(path: &Path) -> (Option<String>, Option<String>) {
    platform::read(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn reads_real_windows_program_metadata_and_icon() {
        use base64::{engine::general_purpose::STANDARD, Engine};
        use std::os::windows::ffi::OsStrExt;

        let root = std::env::var_os("SystemRoot").expect("Windows root");
        let explorer = std::path::PathBuf::from(root).join("explorer.exe");
        let (name, _) = read(&explorer);
        assert!(name.is_some_and(|name| !name.is_empty()));
        let path: Vec<_> = explorer.as_os_str().encode_wide().chain([0]).collect();
        let encoded = platform::icon(&path)
            .unwrap()
            .strip_prefix("data:image/x-icon;base64,")
            .unwrap()
            .to_owned();
        let bytes = STANDARD.decode(encoded).unwrap();
        assert_eq!(&bytes[..10], &[0, 0, 1, 0, 1, 0, 32, 32, 0, 0]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn locates_enclosing_macos_app_bundle() {
        let exe = Path::new("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome");
        assert_eq!(
            platform::enclosing_app_bundle(exe),
            Some(std::path::PathBuf::from("/Applications/Google Chrome.app"))
        );
        assert_eq!(platform::enclosing_app_bundle(Path::new("/usr/local/bin/node")), None);
    }
}
