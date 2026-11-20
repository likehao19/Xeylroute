use serde::Deserialize;
use tauri::{
    image::Image,
    menu::{Menu, MenuItem, PredefinedMenuItem, Submenu},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, Window, WindowEvent,
};

const TRAY_ID: &str = "routepilot";
const MAIN_WINDOW: &str = "main";

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrayState {
    english: bool,
    configured: bool,
    running: bool,
    system_proxy: bool,
    tun: bool,
    busy: bool,
    mode: String,
    nodes: Vec<String>,
    selected: String,
}

fn tray_appearance(state: &TrayState) -> ([u8; 3], &'static str) {
    if state.tun {
        ([22, 133, 77], "RoutePilot · TUN")
    } else if state.system_proxy {
        (
            [0, 103, 192],
            if state.english {
                "RoutePilot · System proxy"
            } else {
                "RoutePilot · 系统代理"
            },
        )
    } else {
        (
            [112, 112, 112],
            if state.english {
                "RoutePilot · Idle"
            } else {
                "RoutePilot · 未接管"
            },
        )
    }
}

fn tray_image(icon: &Image<'_>, color: [u8; 3]) -> Image<'static> {
    let mut rgba = icon.rgba().to_vec();
    for pixel in rgba.chunks_exact_mut(4) {
        if pixel[3] == 0 {
            continue;
        }
        // Map shadows and highlights into the status color without changing the silhouette.
        let luminance =
            (54 * u16::from(pixel[0]) + 183 * u16::from(pixel[1]) + 19 * u16::from(pixel[2])) / 256;
        for (channel, base) in pixel[..3].iter_mut().zip(color) {
            let base = u16::from(base);
            let tinted = if luminance < 128 {
                let shadow = base * 3 / 5;
                shadow + (base - shadow) * luminance / 128
            } else {
                base + (255 - base) * (luminance - 128) / 127
            };
            *channel = tinted as u8;
        }
    }
    Image::new_owned(rgba, icon.width(), icon.height())
}

fn menu(app: &AppHandle, state: &TrayState) -> tauri::Result<Menu<tauri::Wry>> {
    let label = |zh: &'static str, en: &'static str| if state.english { en } else { zh };
    let item =
        |id: &str, title: &str, enabled| MenuItem::with_id(app, id, title, enabled, None::<&str>);
    let action = |id: &str, title: &str, checked, enabled| {
        let prefix = if checked { "✓  " } else { "" };
        item(id, &format!("{prefix}{title}"), enabled)
    };
    let available = !state.busy && state.configured;
    let modes = Submenu::new(app, label("代理模式", "Proxy mode"), available)?;
    for (mode, title) in [
        ("rule", label("规则", "Rule")),
        ("global", label("全局", "Global")),
        ("direct", label("直连", "Direct")),
    ] {
        modes.append(&action(
            &format!("mode:{mode}"),
            title,
            state.mode == mode,
            true,
        )?)?;
    }
    let can_select =
        !state.busy && state.running && state.mode != "rule" && !state.nodes.is_empty();
    let nodes = Submenu::new(app, label("选择节点", "Select node"), can_select)?;
    if can_select {
        for name in &state.nodes {
            nodes.append(&action(
                &format!("node:{name}"),
                &name.replace('&', "&&"),
                state.selected == *name,
                true,
            )?)?;
        }
    }
    let window = item("show", label("打开 RoutePilot", "Open RoutePilot"), true)?;
    let proxy = action(
        if state.system_proxy {
            "system:off"
        } else {
            "system:on"
        },
        label("系统代理", "System proxy"),
        state.system_proxy,
        !state.busy && (state.configured || state.system_proxy),
    )?;
    let tun = action(
        if state.tun { "tun:off" } else { "tun:on" },
        "TUN",
        state.tun,
        !state.busy && (state.configured || state.tun),
    )?;
    let core = item(
        if state.running {
            "power:off"
        } else {
            "power:on"
        },
        if state.running {
            label("停止内核", "Stop core")
        } else {
            label("启动内核", "Start core")
        },
        !state.busy && (state.configured || state.running),
    )?;
    let quit = item(
        "quit",
        label("退出 RoutePilot", "Quit RoutePilot"),
        !state.busy,
    )?;
    Menu::with_items(
        app,
        &[
            &window,
            &PredefinedMenuItem::separator(app)?,
            &proxy,
            &tun,
            &modes,
            &nodes,
            &core,
            &PredefinedMenuItem::separator(app)?,
            &quit,
        ],
    )
}

/// Tells the page whether anyone can see it, so it can stop rendering and poll slowly while the
/// window sits hidden in the tray.
const VISIBILITY_EVENT: &str = "routepilot-window-visible";

#[tauri::command]
pub fn show_routepilot(app: AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW) {
        window.show()?;
        window.unminimize()?;
        window.set_focus()?;
        let _ = app.emit_to(MAIN_WINDOW, VISIBILITY_EVENT, true);
    }
    Ok(())
}

pub fn install(app: &AppHandle) -> tauri::Result<()> {
    let state = TrayState::default();
    let (color, tooltip) = tray_appearance(&state);
    let mut builder = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip(tooltip)
        .menu(&menu(app, &state)?)
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if matches!(
                event,
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                }
            ) {
                let _ = show_routepilot(tray.app_handle().clone());
            }
        })
        .on_menu_event(|app, event| match event.id().as_ref() {
            "show" => {
                let _ = show_routepilot(app.clone());
            }
            "quit" => app.exit(0),
            action => {
                if action == "tun:on" {
                    let _ = show_routepilot(app.clone());
                }
                let _ = app.emit_to(MAIN_WINDOW, "routepilot-tray-action", action);
            }
        });
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(tray_image(icon, color));
    }
    builder.build(app)?;
    Ok(())
}

pub fn on_window_event(window: &Window, event: &WindowEvent) {
    if window.label() != MAIN_WINDOW {
        return;
    }
    match event {
        WindowEvent::CloseRequested { api, .. }
            if window.app_handle().tray_by_id(TRAY_ID).is_some() =>
        {
            if window.hide().is_ok() {
                api.prevent_close();
                let _ = window.emit_to(MAIN_WINDOW, VISIBILITY_EVENT, false);
            }
        }
        WindowEvent::Focused(true) => {
            let _ = window.emit_to(MAIN_WINDOW, VISIBILITY_EVENT, true);
        }
        _ => {}
    }
}

#[tauri::command]
pub async fn update_tray_menu(app: AppHandle, state: TrayState) -> Result<(), String> {
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        tray.set_menu(Some(menu(&app, &state).map_err(|error| error.to_string())?))
            .map_err(|error| error.to_string())?;
        let (color, tooltip) = tray_appearance(&state);
        tray.set_tooltip(Some(tooltip))
            .map_err(|error| error.to_string())?;
        if let Some(icon) = app.default_window_icon() {
            tray.set_icon(Some(tray_image(icon, color)))
                .map_err(|error| error.to_string())?;
        }
    }
    Ok(())
}

#[cfg(test)]
#[test]
fn tray_tints_the_whole_mark_while_preserving_transparency() {
    let mut state = TrayState {
        running: true,
        ..TrayState::default()
    };
    let idle = tray_appearance(&state).0;
    state.system_proxy = true;
    let proxy = tray_appearance(&state).0;
    state.tun = true;
    let tun = tray_appearance(&state).0;
    assert_ne!(idle, proxy);
    assert_ne!(proxy, tun);
    assert_ne!(idle, tun);
    state.system_proxy = false;
    assert_eq!(tray_appearance(&state).0, tun);

    let original = Image::new_owned(
        vec![
            1, 9, 48, 255, 128, 128, 128, 192, 255, 255, 255, 255, 0, 0, 0, 0,
        ],
        2,
        2,
    );
    let idle_image = tray_image(&original, idle);
    let proxy_image = tray_image(&original, proxy);
    let tun_image = tray_image(&original, tun);
    assert_ne!(&idle_image.rgba()[..3], &proxy_image.rgba()[..3]);
    assert_ne!(&proxy_image.rgba()[..3], &tun_image.rgba()[..3]);
    assert_ne!(&tun_image.rgba()[..3], &original.rgba()[..3]);
    assert_eq!(&tun_image.rgba()[4..8], &[tun[0], tun[1], tun[2], 192]);
    assert_eq!(&tun_image.rgba()[8..], &original.rgba()[8..]);
}
