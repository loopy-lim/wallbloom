// Appended to the production engine (without its bootstrap) in a temporary test build.
// No test bridge or test selectors are shipped in the engine.
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print("\(ok ? "PASS" : "FAIL"): \(name)")
    if !ok { failures += 1 }
}
func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
    }
}
func js(_ web: WKWebView, _ source: String) -> Any? {
    var done = false
    var result: Any?
    web.evaluateJavaScript(source) { value, error in
        result = value
        if let error { check(false, "JavaScript evaluation: \(error)") }
        done = true
    }
    let end = Date().addingTimeInterval(5)
    while !done && Date() < end { pump(0.01) }
    check(done, "JavaScript callback completes")
    return result
}
final class ClickReceiver: NSView {
    var clicks = 0
    override func mouseDown(with event: NSEvent) { clicks += 1 }
}
func capture(_ window: NSWindow, to url: URL) -> NSBitmapImageRep? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
    do { try task.run(); task.waitUntilExit() } catch { check(false, "window capture: \(error)"); return nil }
    check(task.terminationStatus == 0, "window capture exit code")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return NSBitmapImageRep(data: data)
}
func pixel(_ image: NSBitmapImageRep?) -> NSColor? {
    guard let image else { return nil }
    return image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
}
extension WallpaperController {
    func acceptance(_ package: URL, evidence: URL) {
        let originalApplication = NSWorkspace.shared.frontmostApplication
        defer { stop(); originalApplication?.activate(options: []) }
        guard activeJSONPath.standardizedFileURL.path.hasPrefix(evidence.standardizedFileURL.path + "/home/") else {
            check(false, "Foundation HOME isolation"); return
        }
        setupMenuBar()
        do {
            _ = try validateWallpkg(package)
            check(true, "valid local package")
        } catch { check(false, "valid local package: \(error)"); return }
        for path in ["../outside.html", "/tmp/outside.html", "./index.html", "index.html\0", "https://example.com/a.html"] {
            do { _ = try safePackageFile(path, in: package); check(false, "reject unsafe path \(path.debugDescription)") }
            catch { check(true, "reject unsafe path \(path.debugDescription)") }
        }
        let link = package.appendingPathComponent("escape.js")
        let outside = evidence.appendingPathComponent("outside.js")
        try? Data("window.outsideCodeRan=true".utf8).write(to: outside)
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            defer { try? FileManager.default.removeItem(at: link) }
            do { _ = try safePackageFile("escape.js", in: package); check(false, "reject symlink escape") }
            catch { check(true, "reject symlink escape") }
            do { _ = try WebPackage(directory: package, entry: package.appendingPathComponent("index.html")); check(false, "reject escaping package asset") }
            catch { check(true, "reject escaping package asset") }
        } catch { check(false, "create isolated symlink fixture") }
        let oversized = package.appendingPathComponent("oversized.bin")
        FileManager.default.createFile(atPath: oversized.path, contents: Data())
        do {
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.truncate(atOffset: 257 * 1024 * 1024)
            try handle.close()
            defer { try? FileManager.default.removeItem(at: oversized) }
            do { _ = try WebPackage(directory: package, entry: package.appendingPathComponent("index.html")); check(false, "reject over-budget package before reading asset") }
            catch { check(true, "reject over-budget package before reading asset") }
        } catch { check(false, "prepare isolated sparse resource fixture") }
        pollActiveJSON()
        pump(4)
        check(webViews.count == NSScreen.screens.count && !webViews.isEmpty, "one web view per display")
        guard let web = webViews.first, let window = windows.first else { return }
        check(windows.allSatisfy { $0.ignoresMouseEvents }, "default click-through policy")
        check(js(web, "!!window.wallbloomFixture") as? Bool == true, "real WebKit executes local JS")
        let frames = js(web, "window.wallbloomFixture.frames") as? Int ?? 0
        pump(0.5)
        check((js(web, "window.wallbloomFixture.frames") as? Int ?? 0) > frames, "real WebGL animation advances")
        print("WebGL status: \(js(web, "document.querySelector('#status').textContent") ?? "missing")")
        check(js(web, "document.querySelector('#status').textContent.startsWith('WEBGL OK')") as? Bool == true, "WebGL shader compiles and draws")
        // The fixture itself must NOT supply this policy. Removing engine enforcement must fail this assertion.
        check(js(web, "Array.from(document.querySelectorAll('meta[http-equiv]')).some(m => m.content.includes(\"worker-src 'none'\"))") as? Bool == true, "engine supplies restrictive CSP")
        let a = pixel(capture(window, to: evidence.appendingPathComponent("web-a.png")))
        check(a != nil && (a?.blueComponent ?? 0) > 0.3, "WebGL pixels visible in actual window capture")
        let outsidePath = String(data: (try? JSONSerialization.data(withJSONObject: [outside.absoluteString])) ?? Data(), encoding: .utf8) ?? "[]"
        _ = js(web, "let outside=document.createElement('script'); outside.src=\(outsidePath)[0]; document.body.append(outside)")
        pump(0.2)
        check(js(web, "window.outsideCodeRan !== true") as? Bool == true, "engine resource policy excludes files outside package snapshot")
        if let base = web.url?.deletingLastPathComponent().absoluteString {
            for traversal in ["../", "%2e%2e/"] {
                let escape = base + traversal + evidence.lastPathComponent + "/outside.js"
                let encoded = String(data: try! JSONSerialization.data(withJSONObject: [escape]), encoding: .utf8)!
                _ = js(web, "(()=>{const escape=document.createElement('script'); escape.src=\(encoded)[0]; document.body.append(escape)})()")
                pump(0.1)
                check(js(web, "window.outsideCodeRan !== true") as? Bool == true, "resource traversal rejected: \(traversal)")
            }
        }
        let port = (try? String(contentsOf: evidence.appendingPathComponent("canary-port"), encoding: .utf8)) ?? "0"
        _ = js(web, """
        window.violations=[]; document.addEventListener('securitypolicyviolation', e=>violations.push(e.effectiveDirective));
        fetch('http://127.0.0.1:\(port)/fetch').catch(()=>{});
        let script=document.createElement('script'); script.src='http://127.0.0.1:\(port)/script'; document.body.append(script);
        let image=new Image(); image.src='http://127.0.0.1:\(port)/image'; document.body.append(image);
        try { new WebSocket('ws://127.0.0.1:\(port)/socket'); } catch(e) {}
        """)
        pump(0.5)
        let violations = js(web, "violations") as? [String] ?? []
        check(violations.contains("connect-src") && violations.contains("script-src-elem") && violations.contains("img-src"), "CSP actively rejects network resource classes")
        _ = js(web, "location.href='http://127.0.0.1:\(port)/navigation'")
        pump(0.3)
        check(web.url?.isFileURL == true, "external navigation rejected")
        check((try? String(contentsOf: evidence.appendingPathComponent("network-requests.log"), encoding: .utf8)) == "", "loopback canary received zero WebKit requests")
        let cursor = CGEvent(source: nil)?.location
        defer {
            if let cursor { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cursor, mouseButton: .left)?.post(tap: .cghidEventTap) }
        }
        setInteractive(true)
        pump(0.2)
        check(window.canBecomeKey && window.isKeyWindow, "opt-in accepts keyboard focus")
        check(!window.ignoresMouseEvents, "opt-in accepts mouse events")
        if CGPreflightPostEventAccess() {
            let bounds = window.frame
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let point = CGPoint(x: bounds.midX, y: top - bounds.midY)
            _ = js(web, "window.clicks=0; document.addEventListener('click',()=>window.clicks++)")
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            pump(0.3)
            let pointer = js(web, "wallbloomFixture.pointer") as? [Double] ?? []
            check(pointer.count == 2 && pointer[0] > 0 && pointer[1] > 0, "OS-posted cursor reaches WebKit (not physical mouse evidence)")
            check(js(web, "window.clicks") as? Int == 1, "OS mouse click reaches opted-in web content")
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
            pump(0.3)
            check(!isInteractive, "OS Escape releases interaction before page JS")
            let receiverWindow = NSWindow(contentRect: NSRect(x: bounds.midX - 100, y: bounds.midY - 100, width: 200, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
            let receiver = ClickReceiver(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            receiverWindow.contentView = receiver
            receiverWindow.orderFrontRegardless()
            pump(0.2)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            pump(0.2)
            check(receiver.clicks == 1 && js(web, "window.clicks") as? Int == 1, "after Escape normal app receives click, wallpaper does not")
            receiverWindow.orderOut(nil)
        } else { check(false, "input posting permission missing; input not verified") }
        setInteractive(false)
        check(windows.allSatisfy { $0.ignoresMouseEvents && $0.level.rawValue == -2147483610 }, "exit restores desktop click-through")
        check(!NSApp.isHidden, "exit does not hide wallpaper windows")
        // The fixture opts into the cooperative pause contract and owns its timer.
        let liveTicks = js(web, "window.wallbloomFixture.timerTicks") as? Int ?? 0
        pump(0.2)
        check((js(web, "window.wallbloomFixture.timerTicks") as? Int ?? 0) > liveTicks, "cooperative fixture timer positive control advances")
        isPausedByContract = true
        applyPlaybackState()
        var mediaSettled = false
        web.setAllMediaPlaybackSuspended(true) { mediaSettled = true }
        let pauseDeadline = Date().addingTimeInterval(5)
        while !mediaSettled && Date() < pauseDeadline { pump(0.01) }
        check(mediaSettled, "WebKit media suspension callback completes")
        pump(0.2)
        let pausedTicks = js(web, "window.wallbloomFixture.timerTicks") as? Int ?? -1
        print("cooperative_pause_timer_ticks=\(pausedTicks - liveTicks) during first 0.2-second pause interval")
        let pauseCalls = js(web, "window.wallbloomFixture.pauseCalls") as? Int ?? 0
        check(pauseCalls > 0, "window.wallbloom.pause hook called")
        let frozenAt = pausedTicks
        pump(0.2)
        check((js(web, "window.wallbloomFixture.timerTicks") as? Int ?? -1) == frozenAt, "hook-managed timer stops during pause")
        isPausedByContract = false
        applyPlaybackState()
        pump(0.2)
        check((js(web, "window.wallbloomFixture.resumeCalls") as? Int ?? 0) > 0, "window.wallbloom.resume hook called")
        check((js(web, "window.wallbloomFixture.timerTicks") as? Int ?? frozenAt) > frozenAt, "hook-managed timer resumes")
        print("LIMITATION: pages without cooperative hooks may continue arbitrary JavaScript timers during pause/low-power mode.")
        // Switch through the real active.json parser; invalid candidates must preserve the window.
        let b = package.deletingLastPathComponent().appendingPathComponent("green-html")
        try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try? Data("{\"spec\":0.2,\"id\":\"green-html\",\"title\":\"Green HTML\",\"type\":\"web\",\"entry\":\"index.html\"}".utf8).write(to: b.appendingPathComponent("wall.json"))
        try? Data("<!doctype html><html><body><script>document.body.style.background='rgb(12,200,24)'</script></body></html>".utf8).write(to: b.appendingPathComponent("index.html"))
        let started = ProcessInfo.processInfo.systemUptime
        let state: [String: Any] = ["spec": 0.2, "active": b.path, "paused": false]
        try? JSONSerialization.data(withJSONObject: state).write(to: activeJSONPath, options: .atomic)
        pollActiveJSON()
        pump(1)
        if let windowB = windows.first {
            let color = pixel(capture(windowB, to: evidence.appendingPathComponent("web-b.png")))
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            check(color != nil && (color?.greenComponent ?? 0) > 0.7 && (color?.redComponent ?? 1) < 0.5 && (color?.blueComponent ?? 1) < 0.4, "HTML/JS B changes actual visible pixels")
            print("engine-only web B visible seconds=\(elapsed); not product UI 3-second acceptance")
            let before = windowB.windowNumber
            try? Data("{\"spec\":0.2,\"active\":\"/missing-wallpkg\"}".utf8).write(to: activeJSONPath, options: .atomic)
            pollActiveJSON()
            check(windows.first?.windowNumber == before, "invalid package preserves working wallpaper")
        }
        let video = package.deletingLastPathComponent().appendingPathComponent("red-video")
        if FileManager.default.fileExists(atPath: video.appendingPathComponent("wall.json").path) {
            let state: [String: Any] = ["spec": 0.2, "active": video.path, "paused": false]
            try? JSONSerialization.data(withJSONObject: state).write(to: activeJSONPath, options: .atomic)
            pollActiveJSON(); pump(2)
            check(webViews.isEmpty && players.count == NSScreen.screens.count, "web to video on all displays")
            if let videoWindow = windows.first {
                let color = pixel(capture(videoWindow, to: evidence.appendingPathComponent("video.png")))
                check(color != nil && (color?.redComponent ?? 0) > 0.7 && (color?.greenComponent ?? 1) < 0.4, "video regression has visible red frame")
            }
            isPausedByContract = true; applyPlaybackState(); pump(0.2)
            check(players.allSatisfy { $0.rate == 0 }, "video pause regression")
            let back: [String: Any] = ["spec": 0.2, "active": package.path, "paused": false]
            try? JSONSerialization.data(withJSONObject: back).write(to: activeJSONPath, options: .atomic)
            pollActiveJSON(); pump(1)
            check(players.isEmpty && webViews.count == NSScreen.screens.count, "video to web on all displays")
            if let resumed = webViews.first { check(js(resumed, "wallbloomFixture.frames > 0") as? Bool == true, "WebGL executes after video round trip") }
        } else { check(false, "video fixture unavailable; video regression not verified") }
        print("ATTENTION: physical mouse, all Spaces and low-power mode require additional evidence; posted OS events are not physical input.")
    }
}
setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let evidence = URL(fileURLWithPath: CommandLine.arguments[2])
let controller = WallpaperController(video: URL(fileURLWithPath: "/nonexistent.mp4"))
controller.acceptance(URL(fileURLWithPath: CommandLine.arguments[1]), evidence: evidence)
print("runtime_failures=\(failures)")
exit(failures == 0 ? 2 : 1)
