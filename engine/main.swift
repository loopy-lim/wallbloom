// Wallbloom — minimal native macOS video wallpaper
//
// 영상 배경화면을 데스크톱 레벨에서 루프 재생하는 최소 앱.
// AVPlayerLayer(AVFoundation) 하드웨어 디코딩을 사용한다. 서드파티 의존성 없음.
//
// 사용법: Wallbloom [영상파일경로]
//   경로를 주지 않으면 기본 후보 경로 중 존재하는 것을 재생한다.

import AppKit
import AVFoundation
import WebKit
import IOKit.ps
import ServiceManagement

/// 기본 영상 후보 (순서대로 존재 확인)
let DEFAULT_VIDEO_CANDIDATES = [
    URL(fileURLWithPath: "sample-hevc.mp4"),  // 작업 디렉토리
    URL(fileURLWithPath: NSString("~").expandingTildeInPath + "/Movies/wallbloom.mp4"),
]

func resolveDefaultVideo() -> URL {
    for candidate in DEFAULT_VIDEO_CANDIDATES where FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }
    return DEFAULT_VIDEO_CANDIDATES[0]
}

/// AVPlayerLayer를 백킹 레이어로 사용하는 뷰 (macOS 정석 패턴)
final class PlayerView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}

/// Borderless wallpaper windows must explicitly opt in to keyboard focus.
final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
}

/// gravity 문자열을 유효한 모드로 정규화한다. 누락/무효 값은 cover 폴백(WALLPKG_SPEC §2 gravity).
func normalizeGravity(_ raw: String?) -> String {
    switch raw {
    case "contain": return "contain"
    case "stretch": return "stretch"
    default: return "cover"
    }
}

/// Private, immutable rendering copy: policy precedes every untrusted HTML byte.
/// Never rewrite the installed package or trust a package-authored CSP.
final class WebPackage {
    let root: URL
    let entry: URL
    let powerPolicy: String
    static let policy = "default-src 'none'; script-src file: 'unsafe-inline'; style-src file: 'unsafe-inline'; img-src file: data:; font-src file:; media-src file:; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

    init(directory: URL, entry sourceEntry: URL, powerPolicy: String = "auto") throws {
        self.powerPolicy = powerPolicy == "alwaysActive" ? "alwaysActive" : "auto"
        let fm = FileManager.default
        let sourceRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        root = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("wallbloom-web-\(UUID().uuidString)", isDirectory: true)
        let canonicalEntry = sourceEntry.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalEntry.path.hasPrefix(sourceRoot.path + "/") else { throw ActiveJSONError.invalid }
        let relativeEntry = String(canonicalEntry.path.dropFirst(sourceRoot.path.count + 1))
        entry = root.appendingPathComponent(relativeEntry)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            guard let files = fm.enumerator(atPath: sourceRoot.path) else { throw ActiveJSONError.invalid }
            var bytes = 0
            var count = 0
            for case let relativePath as String in files {
                let file = sourceRoot.appendingPathComponent(relativePath)
                count += 1
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                let canonical = file.resolvingSymlinksInPath().standardizedFileURL
                guard count <= 4096, canonical.path.hasPrefix(sourceRoot.path + "/"),
                      values.isSymbolicLink != true else { throw ActiveJSONError.invalid }
                let destination = root.appendingPathComponent(relativePath)
                if values.isDirectory == true {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    continue
                }
                guard values.isRegularFile == true else { throw ActiveJSONError.invalid }
                bytes += values.fileSize ?? 0
                guard bytes <= 256 * 1024 * 1024 else { throw ActiveJSONError.invalid }
                var data = try Data(contentsOf: canonical)
                if ["html", "htm"].contains(file.pathExtension.lowercased()) {
                    guard let html = String(data: data, encoding: .utf8),
                          html.range(of: "<html|<!doctype", options: [.regularExpression, .caseInsensitive]) != nil else { throw ActiveJSONError.invalid }
                    data = Data(("<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(Self.policy)\">" + html).utf8)
                }
                try data.write(to: destination, options: .atomic)
            }
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

// MARK: - WallpaperController

/// 화면마다 하나의 데스크톱 레벨 윈도우를 만들고 AVPlayer로 루프 재생한다.
final class WallpaperController: NSObject {

    private var currentVideo: URL
    private var currentWebEntry: URL?
    private var webPackage: WebPackage?
    private var sceneProcess: Process?
    private var sceneInteractive = false
    private var sceneSuspended = false
    private var previousApplication: NSRunningApplication?
    private var globalEscapeMonitor: Any?
    private var pauseAttentionEmitted = false
    private var webViews: [WKWebView] = []
    private var webSnapshots: [ObjectIdentifier: NSImageView] = [:]
    private var webSnapshotPending = Set<ObjectIdentifier>()
    private var batteryTimer: Timer?
    private var coverageTimer: Timer?
    private var isOnBattery = false
    private var loadedWebViews: Set<ObjectIdentifier> = []
    private var isInteractive = false
    private var escapeMonitor: Any?
    private var windows: [NSWindow] = []
    private var players: [AVQueuePlayer] = []
    private var playerLayers: [AVPlayerLayer] = []
    private var loopers: [AVPlayerLooper] = []
    // 화면 맞춤 모드: wallpkg gravity 기본값 + active.json 오버라이드(모두 정규화됨).
    private var packageGravity = "cover"
    private var activeGravityOverride: String?
    private var lowPowerObserver: NSKeyValueObservation?
    private(set) var isPausedByUser = false
    private var isPausedByContract = false
    private var activeJSONPath: URL {
        if let isolatedRoot = ProcessInfo.processInfo.environment["WALLBLOOM_SUPPORT_DIR"] {
            return URL(fileURLWithPath: isolatedRoot, isDirectory: true).appendingPathComponent("active.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wallbloom/active.json")
    }
    private var lastAppliedData: Data?
    private var lastAppliedActive: String?
    private var hasAppliedContractState = false
    private var pollTimer: Timer?
    private var readinessTimer: Timer?
    private var readinessGeneration = 0
    private var terminationSignal: DispatchSourceSignal?

    init(video: URL) {
        self.currentVideo = video
        super.init()
    }

    func stop() {
        pollTimer?.invalidate()
        terminationSignal?.cancel()
        terminationSignal = nil
        teardown()
        webPackage = nil
    }

    func start() {
        signal(SIGTERM, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource.setEventHandler { [weak self] in self?.stop(); NSApp.terminate(nil) }
        signalSource.resume()
        terminationSignal = signalSource
        if CommandLine.arguments.count > 1 {
            currentVideo = URL(fileURLWithPath: CommandLine.arguments[1])
            buildWindows()
        }
        setupObservers()
        pollActiveJSON()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.pollActiveJSON()
        }
    }

    /// effective gravity = active.json 오버라이드 > wallpkg gravity > cover.
    private var effectiveGravity: String { activeGravityOverride ?? packageGravity }
    private var videoGravity: AVLayerVideoGravity {
        switch effectiveGravity {
        case "contain": return .resizeAspect
        case "stretch": return .resize
        default: return .resizeAspectFill
        }
    }

    private func pollActiveJSON() {
        guard let data = try? Data(contentsOf: activeJSONPath) else { return }
        guard data != lastAppliedData else { return }

        do {
            let state = try parseActiveState(data)
            let overrideGravity = state.gravity.map(normalizeGravity)
            let gravityChanged = overrideGravity != activeGravityOverride
            guard !hasAppliedContractState || state.active != lastAppliedActive || state.paused != isPausedByContract || gravityChanged else { return }
            if state.active != lastAppliedActive {
                if state.active == "none" {
                    teardown()
                    currentWebEntry = nil
                    webPackage = nil
                    lastAppliedActive = "none"
                } else {
                    let packageURL = URL(fileURLWithPath: state.active).standardizedFileURL
                    let entryURL = try validateWallpkg(packageURL)
                    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: packageURL.appendingPathComponent("wall.json"))) as? [String: Any]
                    // Validate/copy before destroying the last working wallpaper.
                    let rawPolicy = manifest?["powerPolicy"] as? String
                    let preparedWeb = manifest?["type"] as? String == "web"
                        ? try WebPackage(directory: packageURL, entry: entryURL, powerPolicy: rawPolicy == "alwaysActive" ? "alwaysActive" : "auto") : nil
                    let sceneConfig = manifest?["type"] as? String == "scene" ? manifest?["scene"] as? [String: Any] : nil
                    lastAppliedActive = state.active
                    isPausedByContract = state.paused
                    packageGravity = normalizeGravity(manifest?["gravity"] as? String)
                    activeGravityOverride = overrideGravity
                    webPackage = preparedWeb
                    if let preparedWeb {
                        currentWebEntry = preparedWeb.entry
                        buildWebWindows(packageRoot: preparedWeb.root)
                    } else if let sceneConfig {
                        currentWebEntry = nil
                        sceneInteractive = sceneConfig["interactive"] as? Bool ?? false
                        launchScene(entryURL)
                    } else {
                        currentWebEntry = nil
                        currentVideo = entryURL
                        buildWindows()
                    }
                }
            } else if gravityChanged {
                // 동일 패키지에서 오버라이드만 바뀜: 핫스왑 재시작 없이 videoGravity만 즉시 적용.
                activeGravityOverride = overrideGravity
                applyVideoGravity()
            }
            isPausedByContract = state.paused
            hasAppliedContractState = true
            lastAppliedData = data
            applyPlaybackState()
        } catch {
            fputs("Wallbloom: ignoring active.json: \(error)\n", stderr)
        }
    }

    private func parseActiveState(_ data: Data) throws -> (active: String, paused: Bool, gravity: String?) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spec = object["spec"] as? NSNumber, spec.doubleValue == 0.2,
              let active = object["active"] as? String,
              !active.isEmpty else {
            throw ActiveJSONError.invalid
        }
        let pausedValue = object["paused"] as? Bool ?? false
        if active != "none" && (!active.hasPrefix("/") || active.contains("\0")) {
            throw ActiveJSONError.invalid
        }
        return (active, pausedValue, object["gravity"] as? String)
    }

    private func validateWallpkg(_ directory: URL) throws -> URL {
        let manifestURL = try safePackageFile("wall.json", in: directory)
        let manifestValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard manifestValues.isRegularFile == true, (manifestValues.fileSize ?? 0) <= 1024 * 1024 else { throw ActiveJSONError.invalid }
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spec = manifest["spec"] as? NSNumber,
              spec.doubleValue == 0.2 || spec.doubleValue == 0.1,
              let id = manifest["id"] as? String,
              id == directory.lastPathComponent,
              let type = manifest["type"] as? String, ["video", "web", "scene"].contains(type),
              let entry = manifest["entry"] as? String, !entry.isEmpty else {
            throw ActiveJSONError.invalid
        }
        let entryURL = try safePackageFile(entry, in: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ActiveJSONError.invalid
        }
        guard try entryURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ActiveJSONError.invalid }
        if let preview = manifest["preview"] {
            guard let path = preview as? String else { throw ActiveJSONError.invalid }
            _ = try safePackageFile(path, in: directory)
        }
        if type == "scene" {
            guard let scene = manifest["scene"] as? [String: Any], scene["interactive"] is Bool,
                  (try entryURL.resourceValues(forKeys: [.isExecutableKey]).isExecutable == true) else { throw ActiveJSONError.invalid }
        }
        if type == "web" {
            guard ["html", "htm"].contains(entryURL.pathExtension.lowercased()),
                  (try entryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1024 * 1024,
                  String(data: try Data(contentsOf: entryURL), encoding: .utf8) != nil else { throw ActiveJSONError.invalid }
        }
        return entryURL
    }

    private func safePackageFile(_ path: String, in directory: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains(":"),
              !path.contains("\\"), !components.contains(""), !components.contains("."), !components.contains("..") else {
            throw ActiveJSONError.invalid
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let file = directory.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root) else { throw ActiveJSONError.invalid }
        return file
    }

    // MARK: 윈도우 / 재생 구성

    private func buildWindows() {
        teardown()
        let generation = readinessGeneration
        let readinessID = lastAppliedActive ?? currentVideo.path
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            emitReadiness(event: "failure", id: readinessID, reason: "no-screens")
            return
        }

        for screen in screens {
            let player = AVQueuePlayer()
            player.isMuted = true

            // 화면마다 독립된 AVPlayerItem/Looper (템플릿 아이템 공유 금지)
            let item = AVPlayerItem(url: currentVideo)
            // 화면 해상도 이상으로 디코드하지 않도록 제한 → 디코더 부담 절감
            item.preferredMaximumResolution = CGSize(
                width: screen.frame.width,
                height: screen.frame.height
            )
            loopers.append(AVPlayerLooper(player: player, templateItem: item))
            players.append(player)

            let view = PlayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let playerLayer = view.playerLayer!
            playerLayer.player = player
            playerLayer.videoGravity = videoGravity
            playerLayers.append(playerLayer)

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            // 데스크톱 그림(-2147483624) 위, 파인더 데스크톱(-2147483603) 아래
            window.level = NSWindow.Level(rawValue: -2147483610)
            window.isOpaque = false
            // contain 레터박스를 검정으로 렌더링한다(WALLPKG_SPEC §2 gravity: 남는 부분은 투명/검정).
            window.backgroundColor = .black
            window.ignoresMouseEvents = true   // 클릭 완전 통과
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            window.orderFrontRegardless()

            windows.append(window)
        }
        applyPlaybackState()

        // Looper templates never enter the queue. Sample the actual current items
        // together on the main thread, including replacements at loop boundaries.
        // Readiness does not require playback/time advancement (paused is valid).
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, self.readinessGeneration == generation else {
                timer.invalidate()
                return
            }
            var failure: String?
            for player in self.players {
                if player.status == .failed {
                    failure = player.error?.localizedDescription ?? "player-failed"
                } else if let item = player.currentItem, item.status == .failed {
                    failure = item.error?.localizedDescription ?? "player-item-failed"
                }
            }
            for looper in self.loopers where looper.status == .failed {
                failure = looper.error?.localizedDescription ?? "looper-failed"
            }
            let ready = self.players.count == screens.count && self.players.allSatisfy {
                $0.status == .readyToPlay && $0.currentItem?.status == .readyToPlay
            }
            if failure == nil && ProcessInfo.processInfo.systemUptime >= deadline {
                failure = "timeout"
            }
            guard failure != nil || ready else { return }
            timer.invalidate()
            self.readinessTimer = nil
            self.emitReadiness(event: failure == nil ? "ack" : "failure", id: readinessID, reason: failure)
        }
    }

    private func launchScene(_ executable: URL) {
        teardown()
        guard !NSScreen.screens.isEmpty else { emitReadiness(event: "failure", id: lastAppliedActive ?? executable.path, reason: "no-screens"); return }
        let child = Process()
        child.executableURL = executable
        child.arguments = sceneInteractive ? ["--interactive"] : []
        child.currentDirectoryURL = executable.deletingLastPathComponent()
        child.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.sceneProcess === process else { return }
                self.sceneProcess = nil
                self.emitReadiness(event: "failure", id: self.lastAppliedActive ?? executable.path, reason: "scene-exited-\\(process.terminationStatus)")
                self.currentWebEntry = nil
                self.packageGravity = "cover"   // raw 폴백 영상에는 wallpkg gravity 계약이 없다
                self.activeGravityOverride = nil
                self.buildWindows()
            }
        }
        do {
            try child.run()
            sceneProcess = child
            applyPlaybackState()
            emitReadiness(event: "ack", id: lastAppliedActive ?? executable.path, reason: nil)
        } catch {
            emitReadiness(event: "failure", id: lastAppliedActive ?? executable.path, reason: "scene-launch-failed: \\(error)")
            buildWindows()
        }
    }

    private func applyVideoGravity() {
        let gravity = videoGravity
        playerLayers.forEach { $0.videoGravity = gravity }
    }

    private func teardown() {
        readinessGeneration += 1
        if let child = sceneProcess {
            child.terminationHandler = nil
            if sceneSuspended { child.resume(); sceneSuspended = false }
            child.terminate()
            sceneProcess = nil
        }
        readinessTimer?.invalidate()
        readinessTimer = nil
        loopers.removeAll()
        players.forEach { $0.pause(); $0.removeAllItems() }
        playerLayers.removeAll()
        setInteractive(false)
        webViews.forEach { $0.navigationDelegate = nil; $0.uiDelegate = nil; $0.stopLoading(); $0.removeFromSuperview() }
        webViews.removeAll()
        loadedWebViews.removeAll()
        players.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func emitReadiness(event: String, id: String, reason: String?) {
        var payload: [String: Any] = [
            "event": event,
            "id": id,
            "monotonicSeconds": ProcessInfo.processInfo.systemUptime,
        ]
        if let reason { payload["reason"] = reason }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        print("WALLBLOOM_APPLY \(line)")
    }

    // MARK: 관찰자 (저전력 모드 / 디스플레이 변경)

    private func setupObservers() {
        // 저전력 모드에서 자동 일시정지
        lowPowerObserver = ProcessInfo.processInfo.observe(
            \.isLowPowerModeEnabled,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyPlaybackState() }
        }
        // 디스플레이 연결/해제·해상도 변경 시 윈도우 재구성
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.windows.isEmpty else { return }
            if let package = self.webPackage {
                self.buildWebWindows(packageRoot: package.root)
            } else {
                self.buildWindows()
            }
        }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let source = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            let list = IOPSCopyPowerSourcesList(source).takeRetainedValue() as Array
            self.isOnBattery = list.contains { ref in
                guard let d = IOPSGetPowerSourceDescription(source, ref)?.takeUnretainedValue() as? [String: Any] else { return false }
                return d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            }
            self.applyPlaybackState()
        }
        batteryTimer?.fire()
        coverageTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.webPackage?.powerPolicy != "alwaysActive" else { return }
            self.applyPlaybackState()
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("NSProcessInfoPowerStateDidChange"), object: nil, queue: .main) { [weak self] _ in self?.applyPlaybackState() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setInteractive(false)
        }
    }

    private func applyPlaybackState() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let shouldPlay = !isPausedByUser && !isPausedByContract && !lowPower
        players.forEach { shouldPlay ? $0.play() : $0.pause() }
        if let sceneProcess, sceneProcess.isRunning {
            if shouldPlay && sceneSuspended { sceneProcess.resume(); sceneSuspended = false }
            else if !shouldPlay && !sceneSuspended { sceneProcess.suspend(); sceneSuspended = true }
        }
        let autoWeb = webPackage?.powerPolicy != "alwaysActive"
        let snapshotMode = autoWeb && !isInteractive && (lowPower || isCoveredByWindow)
        for webView in webViews {
            if snapshotMode { detachWebViewWithSnapshot(webView) } else { restoreWebView(webView) }
            let throttled = autoWeb && !isInteractive && isOnBattery && !snapshotMode
            webView.evaluateJavaScript("window.wallbloom && window.wallbloom.setFrameRate && window.wallbloom.setFrameRate(\(throttled ? 1 : 0))")
            webView.setAllMediaPlaybackSuspended(!shouldPlay || snapshotMode, completionHandler: nil)
            let hook = shouldPlay && !snapshotMode ? "resume" : "pause"
            webView.evaluateJavaScript("window.wallbloom && typeof window.wallbloom.\(hook) === 'function' ? window.wallbloom.\(hook)() : undefined")
        }
        if !shouldPlay && !webViews.isEmpty {
            setInteractive(false)
            if !pauseAttentionEmitted {
                fputs("ATTENTION: WKWebView media paused and cooperative window.wallbloom.pause() requested; pages without a hook may continue arbitrary JavaScript timers. Full JavaScript suspension is not guaranteed.\n", stderr)
                pauseAttentionEmitted = true
            }
        } else { pauseAttentionEmitted = false }
    }

    private var isCoveredByWindow: Bool {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return NSScreen.screens.contains { screen in
            info.contains { item in
                guard let number = item[kCGWindowNumber as String] as? Int,
                      (item[kCGWindowOwnerPID as String] as? pid_t) != ProcessInfo.processInfo.processIdentifier,
                      let layer = item[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let bounds = item[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { return false }
                if windows.contains(where: { $0.windowNumber == number }) { return false }
                let rect = CGRect(x: x, y: NSScreen.screens.map { $0.frame.maxY }.max().map { $0 - y - h } ?? y, width: w, height: h)
                return rect.contains(screen.frame)
            }
        }
    }

    private func detachWebViewWithSnapshot(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard loadedWebViews.contains(key), webSnapshots[key] == nil, !webSnapshotPending.contains(key), let window = webView.window else { return }
        webSnapshotPending.insert(key)
        webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
            guard let self, let webView, let image else { self?.webSnapshotPending.remove(key); return }
            self.webSnapshotPending.remove(key)
            guard self.webPackage?.powerPolicy != "alwaysActive", !self.isInteractive else { return }
            let imageView = NSImageView(frame: webView.frame)
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            window.contentView = imageView
            self.webSnapshots[key] = imageView
        }
    }

    private func restoreWebView(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard let snapshot = webSnapshots.removeValue(forKey: key), let window = windows.first(where: { $0.contentView === snapshot }) else { return }
        window.contentView = webView
        webView.setNeedsDisplay(webView.bounds)
    }

    // MARK: 액션

    private func buildWebWindows(packageRoot: URL) {
        teardown()
        guard !NSScreen.screens.isEmpty, currentWebEntry != nil else { return }
        let generation = readinessGeneration
        // loadFileURL alone is not a sufficient boundary: WebKit can retain broader
        // file grants. Block all resources, then allow only this exact snapshot.
        let prefix = NSRegularExpression.escapedPattern(for: packageRoot.absoluteString)
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^" + prefix], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let encoded = String(data: data, encoding: .utf8) else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "wallbloom-package-local-v1", encodedContentRuleList: encoded) { [weak self] rules, error in
            guard let self, self.readinessGeneration == generation else { return }
            guard let rules else {
                self.emitReadiness(event: "failure", id: self.lastAppliedActive ?? "web", reason: error?.localizedDescription ?? "network-policy-unavailable")
                return
            }
            self.installWebWindows(packageRoot: packageRoot, rules: rules)
        }
    }

    private func installWebWindows(packageRoot: URL, rules: WKContentRuleList) {
        guard let entry = currentWebEntry else { return }
        for screen in NSScreen.screens {
            let config = WKWebViewConfiguration()
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(rules)
            config.preferences.inactiveSchedulingPolicy = .suspend
            let rawPolicy = webPackage?.powerPolicy ?? "auto"
            let policyJSON = (try? JSONSerialization.data(withJSONObject: [rawPolicy])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"auto\"]"
            let policyLiteral = String(policyJSON.dropFirst().dropLast())
            let pauseHook = WKUserScript(source: """
                window.wallbloom = window.wallbloom || {};
                window.wallbloom.powerPolicy = \(policyLiteral);
                (()=>{const raf=requestAnimationFrame.bind(window),caf=cancelAnimationFrame.bind(window);let rate=0,timer=null,id=0,callback=null;window.wallbloom.setFrameRate=n=>{rate=n;if(!n&&timer){clearTimeout(timer);timer=null;if(callback){const f=callback;callback=null;raf(f)}}};window.requestAnimationFrame=cb=>{if(!rate)return raf(cb);callback=cb;if(!timer)timer=setTimeout(()=>{timer=null;id=raf(t=>{const f=callback;callback=null;if(f)f(t)})},1000/rate);return id};window.cancelAnimationFrame=n=>{if(n===id){caf(id);callback=null}}})();
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(pauseHook)
            config.mediaTypesRequiringUserActionForPlayback = .all
            let web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: config)
            web.navigationDelegate = self
            web.uiDelegate = self
            let window = WallpaperWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.level = NSWindow.Level(rawValue: -2147483610)
            window.isOpaque = false
            window.backgroundColor = .black
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = web
            window.orderFrontRegardless()
            webViews.append(web)
            windows.append(window)
            web.loadFileURL(entry, allowingReadAccessTo: packageRoot)
        }
        applyPlaybackState()
    }

    @objc private func toggleInteraction() { setInteractive(!isInteractive) }

    @objc private func toggleSceneInteraction() {
        guard sceneProcess?.isRunning == true else { return }
        // Restart with explicit opt-in; the fixture consumes this argument to capture pointer input.
        let wasInteractive = sceneInteractive
        sceneInteractive = !wasInteractive
        if let active = lastAppliedActive, active != "none" {
            do {
                let package = URL(fileURLWithPath: active)
                let entry = try validateWallpkg(package)
                launchScene(entry)
            } catch { fputs("Wallbloom: scene interaction restart failed: \\(error)\\n", stderr) }
        }
    }

    private func setInteractive(_ enabled: Bool) {
        let wasInteractive = isInteractive
        isInteractive = enabled && !webViews.isEmpty
        if isInteractive && !wasInteractive { previousApplication = NSWorkspace.shared.frontmostApplication }
        windows.forEach {
            $0.ignoresMouseEvents = !isInteractive
            $0.level = isInteractive ? .normal : NSWindow.Level(rawValue: -2147483610)
            $0.acceptsMouseMovedEvents = isInteractive
        }
        if isInteractive {
            NSApp.activate(ignoringOtherApps: true)
            let window = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(window?.contentView)
            if escapeMonitor == nil {
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53 else { return event }
                    self?.setInteractive(false)
                    return nil
                }
            }
            if globalEscapeMonitor == nil {
                globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { self?.setInteractive(false) }
                }
            }
        } else {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
            if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor); self.globalEscapeMonitor = nil }
            if wasInteractive {
                windows.forEach { $0.resignKey(); $0.orderFrontRegardless() }
                previousApplication?.activate(options: [])
                previousApplication = nil
            }
        }
        if wasInteractive != isInteractive { DispatchQueue.main.async { self.applyPlaybackState() } }
    }

    @objc func togglePause() {
        isPausedByUser.toggle()
        applyPlaybackState()
    }

    /// 조작 창 표시용: 현재 재생 중인 영상 파일명
    var currentVideoName: String { currentVideo.lastPathComponent }

    /// 조작 창 표시용: 현재 적용 중인 화면 맞춤 모드(cover/contain/stretch)
    var currentGravity: String { effectiveGravity }

    /// 조작 창의 화면 맞춤 모드 선택을 active.json contract의 gravity 필드에 반영한다.
    /// 기존 watcher(pollActiveJSON)가 파일 변경을 감지해 재생 재시작 없이 videoGravity만 갱신한다.
    /// gravity는 normalizeGravity로 검증된다(cover/contain/stretch 외 무시 → cover).
    func setGravity(_ gravity: String) {
        let value = normalizeGravity(gravity)
        guard value != effectiveGravity else { return }
        // 기존 파일의 다른 키(active/paused/spec 등)를 보존하고 gravity만 교체한다.
        var object: [String: Any] = [
            "spec": 0.2,
            "active": lastAppliedActive ?? currentVideo.path,
            "paused": isPausedByContract,
        ]
        if let data = try? Data(contentsOf: activeJSONPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["gravity"] = value
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              (try? out.write(to: activeJSONPath, options: .atomic)) != nil else {
            fputs("Wallbloom: active.json gravity 쓰기 실패\n", stderr)
            return
        }
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .video]
        panel.message = "배경화면으로 재생할 영상을 선택하세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        currentVideo = url
        currentWebEntry = nil
        webPackage = nil
        buildWindows()
    }
}

extension WallpaperController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              url.isFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()),
              webViews.contains(webView), navigationAction.targetFrame?.isMainFrame == true,
              let root = webPackage?.root.resolvingSymlinksInPath().standardizedFileURL.path,
              url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { webFailure(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { webFailure(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webFailure("web-content-process-terminated") }
    private func webFailure(_ reason: String) {
        guard !webViews.isEmpty else { return }
        emitReadiness(event: "failure", id: lastAppliedActive ?? "web", reason: reason)
        // Fail visibly and release focus; never leave an input-capturing blank window.
        setInteractive(false)
        teardown()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webViews.contains(webView) else { return }
        applyPlaybackState()
        loadedWebViews.insert(ObjectIdentifier(webView))
        if loadedWebViews.count == webViews.count {
            // Document load acknowledgement, never a visible-frame assertion.
            emitReadiness(event: "ack", id: lastAppliedActive ?? "web", reason: nil)
        }
    }
}

// MARK: - 부트스트랩

enum ActiveJSONError: Error {
    case invalid
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var controller: WallpaperController!
    private var controlWindow: NSWindow?
    private weak var videoNameLabel: NSTextField?
    private weak var pauseButton: NSButton?
    private weak var gravityPopup: NSPopUpButton?
    private weak var loginButton: NSButton?
    private weak var dockSwitch: NSSwitch?
    private weak var menuBarSwitch: NSSwitch?
    private var statusItem: NSStatusItem?

    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let video = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : resolveDefaultVideo()
        controller = WallpaperController(video: video)
        controller.start()
        applyIconSettings()
    }

    // MARK: Dock / 메뉴바 아이콘 (UserDefaults: showDockIcon / showMenuBarIcon)

    /// 저장된 설정으로 두 아이콘 상태를 적용한다. 기본값은 둘 다 숨김(register로 등록).
    private func applyIconSettings() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["showDockIcon": false, "showMenuBarIcon": false])
        let showDock = defaults.bool(forKey: "showDockIcon")
        let showMenuBar = defaults.bool(forKey: "showMenuBarIcon")
        // register는 휘발성이라 `defaults read`로 기본 숨김(false)이 보이도록 영구 도메인에도 기록한다.
        defaults.set(showDock, forKey: "showDockIcon")
        defaults.set(showMenuBar, forKey: "showMenuBarIcon")
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        if showMenuBar { installStatusItem() } else { removeStatusItem() }
    }

    /// 메뉴바 아이콘 생성: 일시정지/재개, 영상 교체…, Wallbloom 끄기
    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Wallbloom")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// 메뉴바 아이콘 제거: 인스턴스를 놓아주면 시스템 메뉴바에서 사라진다.
    private func removeStatusItem() {
        statusItem?.isVisible = false
        statusItem?.menu = nil
        statusItem = nil
    }

    /// 상태 메뉴를 열 때마다 일시정지 상태를 반영해 다시 만든다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paused = controller?.isPausedByUser ?? false
        let pause = NSMenuItem(title: paused ? "재개" : "일시정지", action: #selector(controlPauseClicked), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let replace = NSMenuItem(title: "영상 교체…", action: #selector(controlReplaceClicked), keyEquivalent: "")
        replace.target = self
        menu.addItem(replace)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Wallbloom 끄기", action: #selector(controlQuitClicked), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    /// Dock 아이콘 표시 시 Dock 메뉴(일시정지/재개, 끄기)를 함께 복원한다.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard UserDefaults.standard.bool(forKey: "showDockIcon") else { return nil }
        let menu = NSMenu()
        let paused = controller?.isPausedByUser ?? false
        let pause = NSMenuItem(title: paused ? "재개" : "일시정지", action: #selector(controlPauseClicked), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let quit = NSMenuItem(title: "Wallbloom 끄기", action: #selector(controlQuitClicked), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    // MARK: 설정 창 (앱 재실행 reopen 시 표시)

    /// 실행 중인 앱을 다시 실행하면 설정 창을 띄운다. 항상 true를 반환해 reopen을 소비한다.
    /// 배경화면 윈도우(데스크톱 레벨, 항상 on-screen)가 flag를 true로 만들므로
    /// 사용자가 조작할 수 있는 창(controlWindow) 기준으로 판단한다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || controlWindow?.isVisible != true { showControlWindow() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if controlWindow?.isVisible != true { showControlWindow() }
    }

    func windowWillClose(_ notification: Notification) {
        // 설정 창을 닫아도 앱은 배경화면을 계속 재생한다. nil로 정리해 다음 reopen에서 다시 뜬다.
        if (notification.object as? NSWindow) === controlWindow { controlWindow = nil }
    }

    private func showControlWindow() {
        guard let controller = controller else { return }
        let window = controlWindow ?? makeControlWindow()
        controlWindow = window
        videoNameLabel?.stringValue = "재생 중: \(controller.currentVideoName)"
        refreshPauseButton()
        refreshSettingsControls()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeControlWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 296),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wallbloom 설정"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle

        // 화면 맞춤 모드: active.json contract의 gravity 필드(cover/contain/stretch)에 반영
        let gravityLabel = NSTextField(labelWithString: "화면 맞춤:")
        let gravity = NSPopUpButton(frame: .zero, pullsDown: false)
        gravity.addItems(withTitles: ["cover", "contain", "stretch"])
        gravity.target = self
        gravity.action = #selector(controlGravityChanged(_:))

 // 로그인 시 시작: SMAppService(macOS 13+)
        let login = NSButton(checkboxWithTitle: "로그인 시 시작", target: self, action: #selector(controlLoginToggled(_:)))

        // Dock / 메뉴바 아이콘 토글: UserDefaults에 저장, 런타임 즉시 적용
        let dockLabel = NSTextField(labelWithString: "Dock에 아이콘 표시")
        let dock = NSSwitch()
        dock.target = self
        dock.action = #selector(controlDockToggled(_:))
        let menuBarLabel = NSTextField(labelWithString: "메뉴바에 아이콘 표시")
        let menuBar = NSSwitch()
        menuBar.target = self
        menuBar.action = #selector(controlMenuBarToggled(_:))

        let pause = NSButton(title: "일시정지", target: self, action: #selector(controlPauseClicked))
        let replace = NSButton(title: "영상 교체…", target: self, action: #selector(controlReplaceClicked))
        let quit = NSButton(title: "Wallbloom 끄기", target: self, action: #selector(controlQuitClicked))
        let buttons = [pause, replace, quit]
        for view in [label, gravityLabel, gravity, login, dock, dockLabel, menuBar, menuBarLabel] + buttons {
            view.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),

            gravityLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            gravityLabel.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            gravity.leadingAnchor.constraint(equalTo: gravityLabel.trailingAnchor, constant: 8),
            gravity.centerYAnchor.constraint(equalTo: gravityLabel.centerYAnchor),
            gravity.widthAnchor.constraint(equalToConstant: 120),
            gravity.trailingAnchor.constraint(lessThanOrEqualTo: window.contentView!.trailingAnchor, constant: -20),

            login.topAnchor.constraint(equalTo: gravityLabel.bottomAnchor, constant: 16),
            login.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),

            dock.topAnchor.constraint(equalTo: login.bottomAnchor, constant: 16),
            dock.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            dockLabel.centerYAnchor.constraint(equalTo: dock.centerYAnchor),
            dockLabel.leadingAnchor.constraint(equalTo: dock.trailingAnchor, constant: 8),

            menuBar.topAnchor.constraint(equalTo: dock.bottomAnchor, constant: 12),
            menuBar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            menuBarLabel.centerYAnchor.constraint(equalTo: menuBar.centerYAnchor),
            menuBarLabel.leadingAnchor.constraint(equalTo: menuBar.trailingAnchor, constant: 8),
        ] + buttons.flatMap { button in
            [
                button.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
                button.widthAnchor.constraint(equalToConstant: 140),
            ]
        } + [
            pause.topAnchor.constraint(equalTo: menuBar.bottomAnchor, constant: 16),
            replace.topAnchor.constraint(equalTo: pause.bottomAnchor, constant: 10),
            quit.topAnchor.constraint(equalTo: replace.bottomAnchor, constant: 10),
            quit.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16),
        ])
        videoNameLabel = label
        pauseButton = pause
        gravityPopup = gravity
        loginButton = login
        dockSwitch = dock
        menuBarSwitch = menuBar
        return window
    }

    private func refreshPauseButton() {
        guard let controller = controller else { return }
        pauseButton?.title = controller.isPausedByUser ? "재개" : "일시정지"
    }

    private func refreshSettingsControls() {
        guard let controller = controller else { return }
        gravityPopup?.selectItem(withTitle: controller.currentGravity)
        loginButton?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        dockSwitch?.state = UserDefaults.standard.bool(forKey: "showDockIcon") ? .on : .off
        menuBarSwitch?.state = UserDefaults.standard.bool(forKey: "showMenuBarIcon") ? .on : .off
    }

    @objc private func controlGravityChanged(_ sender: NSPopUpButton) {
        controller?.setGravity(sender.titleOfSelectedItem ?? "cover")
    }

    @objc private func controlDockToggled(_ sender: NSSwitch) {
        let show = sender.state == .on
        UserDefaults.standard.set(show, forKey: "showDockIcon")
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    @objc private func controlMenuBarToggled(_ sender: NSSwitch) {
        let show = sender.state == .on
        UserDefaults.standard.set(show, forKey: "showMenuBarIcon")
        if show { installStatusItem() } else { removeStatusItem() }
    }

    @objc private func controlLoginToggled(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            fputs("Wallbloom: 로그인 시 시작 설정 실패: \(error)\n", stderr)
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func controlPauseClicked() {
        controller?.togglePause()
        refreshPauseButton()
    }

    @objc private func controlReplaceClicked() {
        controller?.openVideo()
        videoNameLabel?.stringValue = "재생 중: \(controller?.currentVideoName ?? "-")"
    }

    @objc private func controlQuitClicked() {
        NSApp.terminate(nil)
    }
}

setbuf(stdout, nil)  // 리다이렉트 시에도 즉시 로그 출력
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement(Info.plist) 기본 정책: Dock·cmd-Tab에서 숨김. launch 후 applyIconSettings가
// UserDefaults(showDockIcon/showMenuBarIcon) 저장값으로 두 아이콘 상태를 다시 적용한다.
app.setActivationPolicy(.accessory)
app.run()
