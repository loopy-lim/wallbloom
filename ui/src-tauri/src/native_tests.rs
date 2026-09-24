//! Real loopback HTTP and production downloader; not a WebView/IPC test.
use super::*;
use std::{io::Read, net::TcpListener, thread, time::{Duration, Instant}};

fn serve(status: &str, body: Vec<u8>, advertised: usize) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("http://{}/fixture.mp4", listener.local_addr().unwrap());
    let status = status.to_owned();
    let worker = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut socket = loop {
            match listener.accept() {
                Ok((socket, _)) => break socket,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(e) => panic!("fixture accept: {e}"),
            }
        };
        // macOS accepted sockets inherit the listener's nonblocking flag.
        // Only accept is polled; read_exact/write_all below require blocking I/O.
        socket.set_nonblocking(false).unwrap();
        socket.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        socket.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            socket.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
            assert!(request.len() < 16384);
        }
        assert!(request.starts_with(b"GET /fixture.mp4 HTTP/1.1\r\n"));
        write!(socket, "HTTP/1.1 {status}\r\nContent-Length: {advertised}\r\nConnection: close\r\n\r\n").unwrap();
        for chunk in body.chunks(65536) {
            socket.write_all(chunk).unwrap();
            thread::sleep(Duration::from_millis(2));
        }
        println!("HTTP fixture: GET /fixture.mp4 status={status} sent={} advertised={advertised}", body.len());
    });
    (url, worker)
}

#[test]
fn native_http_download_progress_publication_and_failure_cleanup() {
    let started = Instant::now();
    let temp = tempfile::tempdir().unwrap();
    let body = fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../sample-hevc.mp4")).unwrap();
    let (url, server) = serve("200 OK", body.clone(), body.len());
    let mut events = Vec::new();
    let result = tauri::async_runtime::block_on(download_wallpaper_at(temp.path(), url, |event| { events.push(event); Ok(()) }));
    server.join().unwrap();
    assert_eq!(result.unwrap(), "fixture");
    let package = temp.path().join("library/fixture");
    assert_eq!(fs::read(package.join("entry.mp4")).unwrap(), body, "every downloaded byte matches actual video fixture");
    assert_eq!(scan_library_at(&temp.path().join("library")).unwrap().len(), 1);
    assert!(events.len() > 1);
    let mut previous = 0;
    for event in &events {
        let received = event.received_bytes;
        assert!(received > previous && received <= body.len() as u64);
        assert_eq!(event.total_bytes, Some(body.len() as u64));
        previous = received;
    }
    assert_eq!(previous, body.len() as u64);
    write_active(temp.path(), package.to_str().unwrap()).unwrap();
    let active: Value = serde_json::from_slice(&fs::read(temp.path().join("active.json")).unwrap()).unwrap();
    assert_eq!(active["active"], package.to_str().unwrap());
    for (status, bytes, length) in [("503 Unavailable", vec![], 0), ("200 OK", vec![1; 4096], 8192), ("200 OK", body.clone(), body.len())] {
        let (url, server) = serve(status, bytes, length);
        let result = tauri::async_runtime::block_on(download_wallpaper_at(temp.path(), url, |_| Ok(())));
        server.join().unwrap();
        assert!(result.is_err(), "HTTP failure, truncated transfer, and duplicate must fail");
        println!("Expected download error: {}", result.unwrap_err());
        assert_eq!(fs::read(package.join("entry.mp4")).unwrap(), body);
        let names: Vec<_> = fs::read_dir(temp.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names.len(), 2, "only library and active.json may remain: {names:?}");
    }
    println!("NATIVE_HTTP_RESULT bytes={} progress_events={} elapsed_ms={} byte_equality=true staging_cleanup=true; live_tauri_ipc=false gui=false", body.len(), events.len(), started.elapsed().as_millis());
}
