pub mod bridge;
use serde_json::Value;
use std::{fs, io::Write, path::{Component, Path, PathBuf}};
use sha2::Digest;
use uuid::Uuid;

#[rustra::bridge_type]
pub struct WallPackage {
    pub id: String,
    pub title: String,
    pub path: String,
    pub preview_path: Option<String>,
    pub package_type: String,
}

#[derive(Debug, serde::Deserialize)]
struct ActiveFile {
    spec: f64,
    active: String,
    #[serde(default)]
    paused: bool,
}

#[tauri::command]
fn import_wallpkg() -> Result<String, String> {
    let source = rfd::FileDialog::new().add_filter("Wallbloom package", &["wallpkg"]).pick_file()
        .ok_or_else(|| "파일 선택이 취소되었습니다".to_string())?;
    import_archive_at(&source, &app_root()?.join("library"))
}

#[tauri::command]
fn export_wallpkg(id: String) -> Result<(), String> {
    let package = scan_library_at(&app_root()?.join("library"))?.into_iter().find(|p| p.id == id)
        .ok_or_else(|| format!("유효한 wallpkg를 찾을 수 없습니다: {id}"))?;
    let Some(destination) = rfd::FileDialog::new().set_file_name(format!("{}.wallpkg", package.id)).save_file() else { return Ok(()); };
    export_archive(&PathBuf::from(package.path), &destination)
}

fn import_archive_at(archive_path: &Path, library: &Path) -> Result<String, String> {
    fs::create_dir_all(library).map_err(|e| e.to_string())?;
    let file = fs::File::open(archive_path).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    let staging = library.join(format!(".import-{}", Uuid::new_v4()));
    fs::create_dir(&staging).map_err(|e| e.to_string())?;
    let result = (|| {
        let package_root = staging.join("package");
        fs::create_dir(&package_root).map_err(|e| e.to_string())?;
        for i in 0..archive.len() {
            let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
            let enclosed = entry.enclosed_name().ok_or_else(|| "아카이브 경로 이탈을 거부했습니다".to_string())?.to_path_buf();
            if entry.unix_mode().is_some_and(|mode| mode & 0o170000 == 0o120000 || mode & 0o170000 != 0 && mode & 0o170000 != 0o100000 && mode & 0o170000 != 0o040000) {
                return Err("아카이브 심볼릭 링크/특수 파일을 거부했습니다".into());
            }
            let output = package_root.join(enclosed);
            if entry.is_dir() { fs::create_dir_all(&output).map_err(|e| e.to_string())?; }
            else {
                if let Some(parent) = output.parent() { fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
                let mut out = fs::File::create(&output).map_err(|e| e.to_string())?;
                std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
            }
        }
        let manifest: Value = serde_json::from_slice(&fs::read(package_root.join("wall.json")).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        let archive_id = manifest.get("id").and_then(Value::as_str).ok_or_else(|| "wallpkg id가 없습니다".to_string())?;
        if !archive_id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') { return Err("잘못된 wallpkg id".into()); }
        let named_root = staging.join(archive_id);
        fs::rename(&package_root, &named_root).map_err(|e| e.to_string())?;
        let package = validate_package(&named_root).ok_or_else(|| "유효하지 않은 wallpkg 아카이브입니다".to_string())?;
        let destination = library.join(&package.id);
        if destination.exists() { return Err(format!("이미 존재하는 배경화면입니다: {}", package.id)); }
        fs::rename(&named_root, destination).map_err(|e| e.to_string())?;
        Ok(package.id)
    })();
    if staging.exists() { let _ = fs::remove_dir_all(staging); }
    result
}

fn export_archive(package: &Path, destination: &Path) -> Result<(), String> {
    if validate_package(package).is_none() { return Err("유효하지 않은 wallpkg입니다".into()); }
    let file = fs::File::create(destination).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    fn add(zip: &mut zip::ZipWriter<fs::File>, root: &Path, dir: &Path, options: zip::write::SimpleFileOptions) -> Result<(), String> {
        for item in fs::read_dir(dir).map_err(|e| e.to_string())? {
            let item = item.map_err(|e| e.to_string())?; let path = item.path();
            let metadata = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() && !metadata.is_file() { return Err("wallpkg 심볼릭 링크/특수 파일 불가".into()); }
            let name = path.strip_prefix(root).map_err(|e| e.to_string())?.to_string_lossy().replace('\\', "/");
            if metadata.is_dir() { zip.add_directory(format!("{name}/"), options).map_err(|e| e.to_string())?; add(zip, root, &path, options)?; }
            else { zip.start_file(name, options).map_err(|e| e.to_string())?; let mut input = fs::File::open(path).map_err(|e| e.to_string())?; std::io::copy(&mut input, zip).map_err(|e| e.to_string())?; }
        }
        Ok(())
    }
    add(&mut zip, package, package, options)?; zip.finish().map_err(|e| e.to_string())?; Ok(())
}

fn copy_package_safely(source: &Path, destination: &Path) -> Result<(), String> {
    fn copy(src: &Path, dst: &Path, root: &Path) -> Result<(), String> {
        let meta = fs::symlink_metadata(src).map_err(|e| e.to_string())?;
        if meta.file_type().is_symlink() { return Err("wallpkg의 심볼릭 링크는 허용되지 않습니다".into()); }
        if meta.is_dir() {
            fs::create_dir_all(dst).map_err(|e| e.to_string())?;
            for item in fs::read_dir(src).map_err(|e| e.to_string())? { let item = item.map_err(|e| e.to_string())?; copy(&item.path(), &dst.join(item.file_name()), root)?; }
        } else if meta.is_file() {
            if !src.canonicalize().map_err(|e| e.to_string())?.starts_with(root) { return Err("wallpkg 경로가 폴더 밖으로 나갑니다".into()); }
            fs::copy(src, dst).map_err(|e| e.to_string())?;
        } else { return Err("특수 파일은 wallpkg에 포함할 수 없습니다".into()); }
        Ok(())
    }
    let root = source.canonicalize().map_err(|e| e.to_string())?;
    copy(&root, destination, &root)
}

#[derive(serde::Deserialize, serde::Serialize, Clone)]
struct RegistryEntry { id: String, title: String, #[serde(rename = "type")] package_type: String, version: String, download_url: String, sha256: String }

#[tauri::command]
async fn fetch_registry(index_url: String) -> Result<Vec<RegistryEntry>, String> {
    let url = reqwest::Url::parse(&index_url).map_err(|e| e.to_string())?;
    if !matches!(url.scheme(), "https" | "http") { return Err("레지스트리 URL은 HTTP(S)여야 합니다".into()); }
    let body: Value = fetch_registry_body(url).await?;
    serde_json::from_value(body.get("packages").cloned().unwrap_or(body)).map_err(|e| e.to_string())
}

async fn fetch_registry_body(url: reqwest::Url) -> Result<Value, String> {
    let response = reqwest::get(url).await.map_err(|e| e.to_string())?.error_for_status().map_err(|e| e.to_string())?;
    serde_json::from_slice(&response.bytes().await.map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

#[tauri::command]
async fn install_registry_entry(entry: RegistryEntry) -> Result<String, String> {
    install_registry_entry_at(entry, &app_root()?).await
}

async fn install_registry_entry_at(entry: RegistryEntry, root: &Path) -> Result<String, String> {
    let url = reqwest::Url::parse(&entry.download_url).map_err(|e| e.to_string())?;
    if !matches!(url.scheme(), "http" | "https") { return Err("잘못된 다운로드 URL".into()); }
    let bytes = reqwest::get(url).await.map_err(|e| e.to_string())?.error_for_status().map_err(|e| e.to_string())?.bytes().await.map_err(|e| e.to_string())?;
    let actual = format!("{:x}", sha2::Sha256::digest(&bytes));
    if !actual.eq_ignore_ascii_case(&entry.sha256) { return Err("레지스트리 파일 SHA-256이 일치하지 않습니다".into()); }
    fs::create_dir_all(root).map_err(|e| e.to_string())?;
    let temp = root.join(format!("registry-{}.wallpkg", Uuid::new_v4())); fs::write(&temp, &bytes).map_err(|e| e.to_string())?;
    let result = import_archive_at(&temp, &root.join("library")); let _ = fs::remove_file(temp);
    let id = result?;
    if id != entry.id { let _ = fs::remove_dir_all(root.join("library").join(&id)); return Err("레지스트리 ID와 패키지 ID가 다릅니다".into()); }
    Ok(id)
}

#[tauri::command]
fn install_web_demo() -> Result<(), String> {
    let library = app_root()?.join("library");
    fs::create_dir_all(&library).map_err(|e| e.to_string())?;
    let demo = library.join("mouse-orbit");
    if demo.exists() { return Ok(()); }
    fs::create_dir(&demo).map_err(|e| e.to_string())?;
    let result = (|| {
        fs::write(demo.join("wall.json"), include_bytes!("../../scripts/web-fixtures/mouse-orbit/wall.json")).map_err(|e| e.to_string())?;
        fs::write(demo.join("index.html"), include_bytes!("../../scripts/web-fixtures/mouse-orbit/index.html")).map_err(|e| e.to_string())?;
        if validate_package(&demo).is_none() { return Err("내장 Web 데모 검증에 실패했습니다".into()); }
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_dir_all(&demo); }
    result
}

#[tauri::command]
fn scan_library() -> Result<Vec<WallPackage>, String> {
    let root = app_root()?;
    scan_library_at(&root.join("library"))
}

#[tauri::command]
async fn download_wallpaper(app: tauri::AppHandle, url: String) -> Result<String, String> {
    use tauri::Emitter;
    download_wallpaper_at(&app_root()?, url, |progress| {
        app.emit("download-progress", &progress).map_err(|error| error.to_string())?;
        app.emit("rustra://download-progress", progress).map_err(|error| error.to_string())
    }).await
}

async fn download_wallpaper_at(root: &Path, url: String, mut progress: impl FnMut(bridge::DownloadProgress) -> Result<(), String>) -> Result<String, String> {
    use futures_util::StreamExt;
    let parsed = reqwest::Url::parse(&url).map_err(|e| e.to_string())?;
    if parsed.scheme() != "https" && parsed.scheme() != "http" {
        return Err("다운로드 URL은 HTTP 또는 HTTPS여야 합니다".into());
    }
    let filename = parsed.path_segments().and_then(Iterator::last).unwrap_or("wallpaper.mp4").to_string();
    let stem = Path::new(&filename).file_stem().and_then(|s| s.to_str()).unwrap_or("wallpaper").to_string();
    let id = safe_id(&stem);
    if id.is_empty() { return Err("URL에서 유효한 파일명을 찾을 수 없습니다".into()); }

    let library = root.join("library");
    fs::create_dir_all(&library).map_err(|e| e.to_string())?;
    let staging = root.join(format!("download-{}-{}", std::process::id(), Uuid::new_v4()));
    fs::create_dir(&staging).map_err(|e| e.to_string())?;
    let result = async {
        let package = staging.join(&id);
        fs::create_dir(&package).map_err(|e| e.to_string())?;
        let response = reqwest::get(parsed.clone()).await.map_err(|e| e.to_string())?.error_for_status().map_err(|e| e.to_string())?;
        let total = response.content_length();
        let mut stream = response.bytes_stream();
        let mut file = fs::File::create(package.join("entry.mp4")).map_err(|e| e.to_string())?;
        let mut received = 0u64;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| e.to_string())?;
            file.write_all(&chunk).map_err(|e| e.to_string())?;
            received += chunk.len() as u64;
            progress(bridge::DownloadProgress { received_bytes: received, total_bytes: total })?;
        }
        file.flush().map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        let manifest = serde_json::json!({"spec":0.2,"id":id,"title":stem,"type":"video","entry":"entry.mp4","preview":"preview.png","loop":true,"volume":0.0,"gravity":"cover","source":url});
        fs::write(package.join("wall.json"), serde_json::to_vec_pretty(&manifest).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        if validate_package(&package).is_none() { return Err("다운로드한 wallpkg 검증에 실패했습니다".to_string()); }
        let destination = library.join(&id);
        if destination.exists() { return Err(format!("이미 존재하는 배경화면입니다: {id}")); }
        fs::rename(&package, &destination).map_err(|e| e.to_string())?;
        Ok(id)
    }.await;
    let _ = fs::remove_dir_all(&staging);
    result
}

fn safe_id(value: &str) -> String {
    let id: String = value.to_ascii_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    id.trim_matches('-').to_string()
}

#[tauri::command]
fn select_wallpaper(id: String) -> Result<(), String> {
    let root = app_root()?;
    let library = root.join("library");
    let package = scan_library_at(&library)?.into_iter().find(|item| item.id == id)
        .ok_or_else(|| format!("유효한 wallpkg를 찾을 수 없습니다: {id}"))?;
    write_active(&root, &package.path)
}

fn app_root() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME")
        .ok_or_else(|| "사용자 홈 디렉터리를 확인할 수 없습니다".to_string())?;
    Ok(PathBuf::from(home).join("Library/Application Support/Wallbloom"))
}

fn scan_library_at(library: &Path) -> Result<Vec<WallPackage>, String> {
    if !library.exists() {
        return Ok(Vec::new());
    }
    let mut packages = Vec::new();
    for item in fs::read_dir(library).map_err(|e| e.to_string())? {
        let item = item.map_err(|e| e.to_string())?;
        let path = item.path();
        if !path.is_dir() { continue; }
        if let Some(package) = validate_package(&path) { packages.push(package); }
    }
    packages.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    Ok(packages)
}

fn validate_package(path: &Path) -> Option<WallPackage> {
    let dir = path.canonicalize().ok()?;
    let folder = path.file_name()?.to_str()?;
    let manifest_path = dir.join("wall.json");
    let value: Value = serde_json::from_slice(&fs::read(manifest_path).ok()?).ok()?;
    let spec = value.get("spec")?.as_f64()?;
    if spec != 0.2 && spec != 0.1 { return None; }
    let id = value.get("id")?.as_str()?;
    if id != folder || !id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        || id.is_empty() { return None; }
    let title = value.get("title").and_then(Value::as_str)
        .or_else(|| (spec == 0.1).then(|| value.get("name").and_then(Value::as_str)).flatten())?;
    let package_type = value.get("type")?.as_str()?;
    if title.trim().is_empty() || !["video", "web", "scene"].contains(&package_type) { return None; }
    if package_type == "web" && !["html", "htm"].contains(&Path::new(value.get("entry")?.as_str()?).extension()?.to_str()?.to_ascii_lowercase().as_str()) { return None; }
    if package_type == "scene" && value.get("scene")?.get("interactive")?.as_bool().is_none() { return None; }
    let entry = safe_file(&dir, value.get("entry")?.as_str()?)?;
    if !entry.is_file() || (package_type == "scene" && !is_executable(&entry)) { return None; }
    let preview_name = value.get("preview").and_then(Value::as_str).unwrap_or("preview.png");
    let preview_path = safe_file(&dir, preview_name).filter(|p| p.is_file())
        .map(|p| p.to_string_lossy().into_owned());
    Some(WallPackage { id: id.to_string(), title: title.to_string(),
        path: dir.to_string_lossy().into_owned(), preview_path, package_type: package_type.to_string() })
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool { use std::os::unix::fs::PermissionsExt; fs::metadata(path).is_ok_and(|m| m.permissions().mode() & 0o111 != 0) }
#[cfg(not(unix))]
fn is_executable(_path: &Path) -> bool { false }

fn safe_file(root: &Path, relative: &str) -> Option<PathBuf> {
    let candidate = Path::new(relative);
    if candidate.is_absolute() || candidate.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir | Component::RootDir | Component::Prefix(_))) { return None; }
    let path = root.join(candidate).canonicalize().ok()?;
    path.starts_with(root).then_some(path)
}

fn write_active(root: &Path, active: &str) -> Result<(), String> {
    fs::create_dir_all(root.join("library")).map_err(|e| e.to_string())?;
    let destination = root.join("active.json");
    if let Ok(bytes) = fs::read(&destination) {
        if let Ok(current) = serde_json::from_slice::<ActiveFile>(&bytes) {
            if current.spec == 0.2 && current.active == active && !current.paused { return Ok(()); }
        }
    }
    let temp = root.join(format!("active.json.{}.{}.tmp", std::process::id(), Uuid::new_v4()));
    let result = (|| {
        let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&temp).map_err(|e| e.to_string())?;
        serde_json::to_writer(&mut file, &serde_json::json!({"spec":0.2,"active":active,"paused":false})).map_err(|e| e.to_string())?;
        file.write_all(b"\n").map_err(|e| e.to_string())?;
        file.flush().map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        drop(file);
        fs::rename(&temp, &destination).map_err(|e| e.to_string())?;
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_file(&temp); }
    result
}

fn app_context() -> tauri::Context<tauri::Wry> {
    tauri::generate_context!()
}

#[cfg(feature = "native-acceptance")]
#[tauri::command]
fn gui_acceptance_report(data: Value) -> Result<(), String> {
    let directory = std::env::var("WALLBLOOM_GUI_EVIDENCE").map_err(|e| e.to_string())?;
    let phase = data["phase"].as_str().unwrap_or("unknown");
    if !["keyboard-ready", "progress", "complete", "integrated-error",
        "integrated-initial-ready", "integrated-initial-input",
        "integrated-mouse-ready", "integrated-mouse-input",
        "integrated-keyboard-ready", "integrated-keyboard-input",
        "integrated-performance-ready", "integrated-performance-input"].contains(&phase) { return Err("invalid phase".into()); }
    fs::write(Path::new(&directory).join(format!("gui-{phase}.json")), data.to_string()).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = rustra::tauri_support::register(bridge::package(), tauri::Builder::default());
    #[cfg(feature = "native-acceptance")]
    let builder = builder
        .invoke_handler(tauri::generate_handler![scan_library, select_wallpaper, download_wallpaper, import_wallpkg, export_wallpkg, fetch_registry, install_registry_entry, install_web_demo, rustra::tauri_support::rustra_dispatch, gui_acceptance_report])
        .on_page_load(|webview, payload| {
            if matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                if std::env::var_os("WALLBLOOM_INTEGRATED").is_some() {
                    webview.eval(include_str!("../../scripts/integrated-harness.js"))
                        .expect("integrated harness injection failed");
                } else if let Ok(base) = std::env::var("WALLBLOOM_GUI_BASE") {
                    let script = include_str!("../../scripts/gui-harness.js").replace("__BASE__", &base);
                    webview.eval(&script).expect("GUI harness injection failed");
                }
            }
        });
    #[cfg(not(feature = "native-acceptance"))]
    let builder = builder.invoke_handler(tauri::generate_handler![scan_library, select_wallpaper, download_wallpaper, import_wallpkg, export_wallpkg, fetch_registry, install_registry_entry, install_web_demo, rustra::tauri_support::rustra_dispatch]);
    builder.run(app_context())
        .expect("error while running Wallbloom");
}

#[cfg(feature = "native-acceptance")]
pub mod native_acceptance;

#[cfg(test)]
mod native_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn archive_import_rejects_zip_slip_and_installs_valid_archive() {
        let temp = tempfile::tempdir().unwrap();
        let archive_path = temp.path().join("evil.wallpkg");
        let file = fs::File::create(&archive_path).unwrap();
        let mut archive = zip::ZipWriter::new(file);
        archive.start_file("../escape.txt", zip::write::SimpleFileOptions::default()).unwrap();
        use std::io::Write;
        archive.write_all(b"escape").unwrap();
        archive.finish().unwrap();
        assert!(import_archive_at(&archive_path, &temp.path().join("library")).is_err());
        assert!(!temp.path().join("escape.txt").exists());
    }

    #[tokio::test]
    async fn registry_local_http_fetch_and_install() {
        use std::{io::Read, net::TcpListener};
        let temp = tempfile::tempdir().unwrap();
        let mut archive_buf = std::io::Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut archive_buf);
            let options = zip::write::SimpleFileOptions::default();
            zip.start_file("wall.json", options).unwrap();
            zip.write_all(br#"{"spec":0.2,"id":"fixture","title":"Fixture","type":"web","entry":"index.html"}"#).unwrap();
            zip.start_file("index.html", options).unwrap(); zip.write_all(b"<html>fixture</html>").unwrap();
            zip.finish().unwrap();
        }
        let archive = archive_buf.into_inner();
        let hash = format!("{:x}", sha2::Sha256::digest(&archive));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let package_body = archive.clone();
        let server = std::thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0u8; 2048]; let count = stream.read(&mut request).unwrap();
                let path = String::from_utf8_lossy(&request[..count]);
                let (content_type, body) = if path.starts_with("GET /index") {
                    let index = format!(r#"{{"packages":[{{"id":"fixture","title":"Fixture","type":"web","version":"1.0","download_url":"http://{address}/fixture.wallpkg","sha256":"{hash}"}}]}}"#);
                    ("application/json", index.into_bytes())
                } else { ("application/octet-stream", package_body.clone()) };
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: {content_type}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
                stream.write_all(&body).unwrap();
            }
        });
        let index_url = reqwest::Url::parse(&format!("http://{address}/index.json")).unwrap();
        let index = fetch_registry_body(index_url).await.unwrap();
        let entry: RegistryEntry = serde_json::from_value(index["packages"][0].clone()).unwrap();
        assert_eq!(install_registry_entry_at(entry, temp.path()).await.unwrap(), "fixture");
        assert!(validate_package(&temp.path().join("library/fixture")).is_some());
        server.join().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn archive_import_rejects_symlink_entries() {
        let temp = tempfile::tempdir().unwrap();
        let archive_path = temp.path().join("symlink.wallpkg");
        let mut zip = zip::ZipWriter::new(fs::File::create(&archive_path).unwrap());
        let options = zip::write::SimpleFileOptions::default().unix_permissions(0o120777);
        zip.start_file("link", options).unwrap(); zip.write_all(b"../../outside").unwrap(); zip.finish().unwrap();
        assert!(import_archive_at(&archive_path, &temp.path().join("library")).is_err());
        assert!(!temp.path().join("outside").exists());
    }

    #[test]
    fn wallpkg_archive_round_trip_preserves_valid_package() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source/demo"); fs::create_dir_all(&source).unwrap();
        fs::write(source.join("index.html"), "<html></html>").unwrap();
        fs::write(source.join("wall.json"), r#"{"spec":0.2,"id":"demo","title":"Demo","type":"web","entry":"index.html"}"#).unwrap();
        let archive = temp.path().join("demo.wallpkg"); export_archive(&source, &archive).unwrap();
        let imported = import_archive_at(&archive, &temp.path().join("library")).unwrap();
        assert_eq!(imported, "demo");
        assert!(validate_package(&temp.path().join("library/demo")).is_some());
    }

    #[test]
    fn download_ids_are_safe_package_names() {
        assert_eq!(safe_id("Cool Video!.mp4"), "cool-video--mp4");
        assert_eq!(safe_id("---"), "");
    }

    #[test]
    fn scan_returns_only_valid_wall_packages() {
        let temp = tempfile::tempdir().unwrap();
        let pkg = temp.path().join("sunset-waves");
        fs::create_dir(&pkg).unwrap();
        fs::write(pkg.join("waves.mp4"), b"video").unwrap();
        fs::write(pkg.join("wall.json"), r#"{"spec":0.2,"id":"sunset-waves","title":"Sunset Waves","type":"video","entry":"waves.mp4"}"#).unwrap();
        let packages = scan_library_at(temp.path()).unwrap();
        assert_eq!(packages.len(), 1);
        assert_eq!(packages[0].title, "Sunset Waves");
    }

    #[test]
    fn scans_web_packages_with_html_entry() {
        let temp = tempfile::tempdir().unwrap();
        let pkg = temp.path().join("web-demo");
        fs::create_dir(&pkg).unwrap();
        fs::write(pkg.join("index.html"), "<!doctype html><html></html>").unwrap();
        fs::write(pkg.join("wall.json"), r#"{"spec":0.2,"id":"web-demo","title":"Web Demo","type":"web","entry":"index.html"}"#).unwrap();
        let result = scan_library_at(temp.path()).unwrap();
        assert_eq!(result[0].package_type, "web");
    }

    #[cfg(unix)]
    #[test]
    fn folder_import_rejects_symlinks_without_copying_outside_files() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("demo");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("index.html"), "<html></html>").unwrap();
        fs::write(source.join("wall.json"), r#"{"spec":0.2,"id":"demo","title":"Demo","type":"web","entry":"index.html"}"#).unwrap();
        std::os::unix::fs::symlink("/etc/passwd", source.join("escape")).unwrap();
        assert!(copy_package_safely(&source, &temp.path().join("destination")).is_err());
        assert!(!temp.path().join("destination").join("escape").exists());
    }

    #[test]
    fn scan_rejects_wallpkg_entries_that_escape_the_package() {
        let temp = tempfile::tempdir().unwrap();
        let library = temp.path().join("library");
        let pkg = library.join("outside-entry");
        fs::create_dir_all(&pkg).unwrap();
        fs::write(temp.path().join("outside.mp4"), b"outside").unwrap();
        fs::write(pkg.join("wall.json"), r#"{"spec":0.2,"id":"outside-entry","title":"Outside","type":"video","entry":"../outside.mp4"}"#).unwrap();

        assert!(scan_library_at(&library).unwrap().is_empty());
    }

    #[test]
    fn external_style_legacy_manifest_supports_nested_media_and_unknown_fields() {
        let temp = tempfile::tempdir().unwrap();
        let package = temp.path().join("legacy-video");
        fs::create_dir_all(package.join("media")).unwrap();
        fs::write(package.join("media/clip.mp4"), b"fixture").unwrap();
        fs::write(package.join("wall.json"), r#"{"spec":0.1,"id":"legacy-video","name":"Legacy","type":"video","entry":"media/clip.mp4","vendor":{"unknown":true}}"#).unwrap();
        let packages = scan_library_at(temp.path()).unwrap();
        assert_eq!(packages.len(), 1);
        assert_eq!(packages[0].title, "Legacy");
        assert!(packages[0].preview_path.is_none());
    }

    #[cfg(unix)]
    #[test]
    fn external_package_symlink_cannot_escape_to_existing_media() {
        let temp = tempfile::tempdir().unwrap();
        let package = temp.path().join("library/escape");
        fs::create_dir_all(&package).unwrap();
        let outside = temp.path().join("outside.mp4");
        fs::write(&outside, b"outside").unwrap();
        std::os::unix::fs::symlink(&outside, package.join("clip.mp4")).unwrap();
        fs::write(package.join("wall.json"), r#"{"spec":0.2,"id":"escape","title":"Escape","type":"video","entry":"clip.mp4"}"#).unwrap();
        assert!(scan_library_at(&temp.path().join("library")).unwrap().is_empty());
    }

    #[test]
    fn active_selection_replaces_file_with_complete_contract() {
        let temp = tempfile::tempdir().unwrap();
        write_active(temp.path(), "/library/sunset-waves").unwrap();
        let active: Value = serde_json::from_slice(&fs::read(temp.path().join("active.json")).unwrap()).unwrap();
        assert_eq!(active["active"], "/library/sunset-waves");
        assert_eq!(active["paused"], false);
        assert_eq!(active["spec"], 0.2);
        assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 2); // library + active.json
    }
}
