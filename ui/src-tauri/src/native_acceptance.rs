//! Opt-in native acceptance executable. Uses the real runtime and AppHandle,
//! but calls commands from Rust: this is not JavaScript IPC or GUI acceptance.
use super::*;
use std::{sync::{Arc, Mutex}, time::Instant};
use tauri::Listener;

pub fn run() {
    let home = PathBuf::from(std::env::var_os("HOME").expect("isolated HOME required"));
    assert!(home.join(".wallbloom-native-fixture").is_file(), "refusing non-fixture HOME");
    let base = std::env::var("WALLBLOOM_FIXTURE_URL").expect("fixture URL required");
    let parsed = reqwest::Url::parse(&base).unwrap();
    assert_eq!(parsed.host_str(), Some("127.0.0.1"));
    let evidence = PathBuf::from(std::env::var_os("WALLBLOOM_NATIVE_EVIDENCE").unwrap());
    let mut context = app_context();
    for window in &mut context.config_mut().app.windows {
        window.visible = false;
    }
    tauri::Builder::default()
        .setup(move |app| {
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let started = Instant::now();
                let events = Arc::new(Mutex::new(Vec::<Value>::new()));
                let captured = events.clone();
                let listener = handle.listen("download-progress", move |event| {
                    captured.lock().unwrap().push(serde_json::from_str(event.payload()).unwrap());
                });
                let result = async {
                    let id = download_wallpaper(handle.clone(), format!("{base}/fixture.mp4")).await?;
                    if id != "fixture" { return Err(format!("unexpected id: {id}")); }
                    let packages = scan_library()?;
                    if packages.len() != 1 { return Err("library publication failed".into()); }
                    select_wallpaper(id)?;
                    let root = app_root()?;
                    let active: Value = serde_json::from_slice(&fs::read(root.join("active.json")).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
                    if active["active"] != packages[0].path || active["paused"] != false {
                        return Err("selection contract mismatch".into());
                    }
                    let length = fs::metadata(root.join("library/fixture/entry.mp4")).map_err(|e| e.to_string())?.len();
                    let progress = events.lock().unwrap().clone();
                    if progress.len() < 2 { return Err("missing real AppHandle progress events".into()); }
                    let mut previous = 0;
                    for event in &progress {
                        let received = event["receivedBytes"].as_u64().ok_or("invalid progress")?;
                        if received <= previous || event["totalBytes"] != length {
                            return Err("non-monotonic or invalid progress".into());
                        }
                        previous = received;
                    }
                    if previous != length { return Err("missing final progress".into()); }
                    let mut failures = Vec::new();
                    for path in ["unavailable.mp4", "broken.mp4", "fixture.mp4"] {
                        let failure = download_wallpaper(handle.clone(), format!("{base}/{path}")).await;
                        failures.push(failure.err().ok_or("expected failed download")?);
                        if fs::read_dir(&root).map_err(|e| e.to_string())?.count() != 2 {
                            return Err("staging files leaked".into());
                        }
                    }
                    Ok::<_, String>(serde_json::json!({"bytes":length,"progress_events":progress,"failures":failures,"selected":active}))
                }.await;
                handle.unlisten(listener);
                let success = result.is_ok();
                let report = serde_json::json!({"result":result,"elapsed_ms":started.elapsed().as_millis(),"live_app_handle":true,"rust_commands":true,"javascript_ipc":false,"gui_interactions":false});
                fs::write(evidence.join("app-handle.json"), serde_json::to_vec_pretty(&report).unwrap()).unwrap();
                handle.exit(if success { 0 } else { 1 });
            });
            Ok(())
        })
        .run(context)
        .expect("native Tauri runtime failed");
}
