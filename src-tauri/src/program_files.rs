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

fn icon(path: &[u16]) -> Option<String> {
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
    // ICO directory, a 32-bit DIB and the required 1-bit mask.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_real_windows_program_metadata_and_icon() {
        let root = std::env::var_os("SystemRoot").expect("Windows root");
        let explorer = std::path::PathBuf::from(root).join("explorer.exe");
        let (name, _) = read(&explorer);
        assert!(name.is_some_and(|name| !name.is_empty()));
        let path: Vec<_> = explorer.as_os_str().encode_wide().chain([0]).collect();
        assert_icon(&icon(&path).unwrap());
    }

    #[test]
    fn supplies_a_windows_application_icon_for_missing_resources() {
        let (_, image) = read(Path::new("routepilot-test-nonexistent.exe"));
        assert_icon(&image.unwrap());
    }

    fn assert_icon(image: &str) {
        let encoded = image.strip_prefix("data:image/x-icon;base64,").unwrap();
        let bytes = STANDARD.decode(encoded).unwrap();
        assert_eq!(&bytes[..10], &[0, 0, 1, 0, 1, 0, 32, 32, 0, 0]);
        assert!(bytes[62..62 + 4096].iter().any(|value| *value != 0));
    }
}
