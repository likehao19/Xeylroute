use serde::{Deserialize, Serialize};
use std::{
    ffi::c_void,
    fs::{self, OpenOptions},
    io::{self, Write},
    mem::size_of,
    path::Path,
    ptr::{null, null_mut},
};
use windows_sys::Win32::{Foundation::GlobalFree, Networking::WinInet::*};

const JOURNAL: &str = "system-proxy-recovery.json";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct ProxySettings {
    flags: u32,
    server: String,
}

#[derive(Deserialize, Serialize)]
struct Recovery {
    previous: ProxySettings,
    applied: ProxySettings,
}

fn options_list(options: &mut [INTERNET_PER_CONN_OPTIONW]) -> INTERNET_PER_CONN_OPTION_LISTW {
    INTERNET_PER_CONN_OPTION_LISTW {
        dwSize: size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32,
        pszConnection: null_mut(),
        dwOptionCount: options.len() as u32,
        dwOptionError: 0,
        pOptions: options.as_mut_ptr(),
    }
}

fn query_with_flags(flag_option: u32) -> io::Result<ProxySettings> {
    let mut flags = INTERNET_PER_CONN_OPTIONW {
        dwOption: flag_option,
        ..Default::default()
    };
    let mut server = INTERNET_PER_CONN_OPTIONW {
        dwOption: INTERNET_PER_CONN_PROXY_SERVER,
        ..Default::default()
    };
    flags.Value.dwValue = 0;
    server.Value.pszValue = null_mut();
    let mut options = [flags, server];
    let mut list = options_list(&mut options);
    let mut size = list.dwSize;
    // WinINet allocates the returned string, including when some requested options fail.
    let ok = unsafe {
        InternetQueryOptionW(
            null(),
            INTERNET_OPTION_PER_CONNECTION_OPTION,
            (&mut list as *mut INTERNET_PER_CONN_OPTION_LISTW).cast::<c_void>(),
            &mut size,
        )
    };
    let error = (ok == 0).then(io::Error::last_os_error);
    let server = unsafe {
        let pointer = options[1].Value.pszValue;
        if pointer.is_null() {
            String::new()
        } else {
            let mut count = 0;
            while *pointer.add(count) != 0 {
                count += 1;
            }
            let value = String::from_utf16_lossy(std::slice::from_raw_parts(pointer, count));
            GlobalFree(pointer.cast::<c_void>());
            value
        }
    };
    if let Some(error) = error {
        return Err(error);
    }
    Ok(ProxySettings {
        flags: unsafe { options[0].Value.dwValue },
        server,
    })
}

fn query() -> io::Result<ProxySettings> {
    query_with_flags(INTERNET_PER_CONN_FLAGS_UI)
        .or_else(|_| query_with_flags(INTERNET_PER_CONN_FLAGS))
}

fn apply(settings: &ProxySettings) -> io::Result<()> {
    let mut server: Vec<u16> = settings.server.encode_utf16().chain([0]).collect();
    let mut options = [
        INTERNET_PER_CONN_OPTIONW {
            dwOption: INTERNET_PER_CONN_PROXY_SERVER,
            Value: INTERNET_PER_CONN_OPTIONW_0 {
                pszValue: server.as_mut_ptr(),
            },
        },
        INTERNET_PER_CONN_OPTIONW {
            dwOption: INTERNET_PER_CONN_FLAGS,
            Value: INTERNET_PER_CONN_OPTIONW_0 {
                dwValue: settings.flags,
            },
        },
    ];
    let list = options_list(&mut options);
    // The original PAC URL and bypass rules are never written.
    unsafe {
        if InternetSetOptionW(
            null(),
            INTERNET_OPTION_PER_CONNECTION_OPTION,
            (&list as *const INTERNET_PER_CONN_OPTION_LISTW).cast::<c_void>(),
            list.dwSize,
        ) == 0
        {
            return Err(io::Error::last_os_error());
        }
        InternetSetOptionW(null(), INTERNET_OPTION_PROXY_SETTINGS_CHANGED, null(), 0);
        InternetSetOptionW(null(), INTERNET_OPTION_REFRESH, null(), 0);
    }
    Ok(())
}

fn load(dir: &Path) -> Result<Option<Recovery>, String> {
    match fs::read(dir.join(JOURNAL)) {
        Ok(data) => serde_json::from_slice(&data)
            .map(Some)
            .map_err(|err| err.to_string()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err.to_string()),
    }
}

fn restore_target<'a>(
    recovery: &'a Recovery,
    current: &ProxySettings,
) -> Option<&'a ProxySettings> {
    // Do not overwrite changes another application made after RoutePilot enabled the proxy.
    (current == &recovery.applied).then_some(&recovery.previous)
}

pub fn is_owned(dir: &Path) -> Result<bool, String> {
    let Some(recovery) = load(dir)? else {
        return Ok(false);
    };
    Ok(restore_target(&recovery, &query().map_err(|err| err.to_string())?).is_some())
}

pub fn restore(dir: &Path) -> Result<(), String> {
    let Some(recovery) = load(dir)? else {
        return Ok(());
    };
    let current = query().map_err(|err| err.to_string())?;
    if let Some(previous) = restore_target(&recovery, &current) {
        apply(previous).map_err(|err| err.to_string())?;
    }
    fs::remove_file(dir.join(JOURNAL)).map_err(|err| err.to_string())
}

pub fn enable(dir: &Path, port: u16) -> Result<(), String> {
    if is_owned(dir)? {
        return Ok(());
    }
    restore(dir)?;
    let previous = query().map_err(|err| err.to_string())?;
    let applied = ProxySettings {
        flags: PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY,
        server: format!("127.0.0.1:{port}"),
    };
    if previous == applied {
        return Err("Windows already uses this address. RoutePilot did not take ownership.".into());
    }

    let recovery = Recovery { previous, applied };
    let contents = serde_json::to_vec(&recovery).map_err(|err| err.to_string())?;
    let temporary = dir.join("system-proxy-recovery.tmp");
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&temporary)
        .map_err(|err| err.to_string())?;
    file.write_all(&contents)
        .and_then(|_| file.sync_all())
        .map_err(|err| err.to_string())?;
    drop(file);
    fs::rename(&temporary, dir.join(JOURNAL)).map_err(|err| err.to_string())?;

    let result = apply(&recovery.applied)
        .map_err(|err| err.to_string())
        .and_then(|()| {
            if is_owned(dir)? {
                Ok(())
            } else {
                Err("Windows did not apply the expected proxy settings".into())
            }
        });
    if let Err(error) = result {
        // Leave the recovery journal intact when the result of a partial write is uncertain.
        return Err(error);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_only_restores_exact_owned_settings() {
        let recovery = Recovery {
            previous: ProxySettings {
                flags: 9,
                server: "previous:8080".into(),
            },
            applied: ProxySettings {
                flags: 3,
                server: "127.0.0.1:7890".into(),
            },
        };
        assert_eq!(
            restore_target(&recovery, &recovery.applied),
            Some(&recovery.previous)
        );
        assert_eq!(restore_target(&recovery, &recovery.previous), None);
        assert_eq!(
            restore_target(
                &recovery,
                &ProxySettings {
                    flags: 1,
                    server: recovery.applied.server.clone()
                }
            ),
            None
        );
    }
}
