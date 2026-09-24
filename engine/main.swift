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
    static let policy = "default-src 'none'; script-src file: 'unsafe-inline'; style-src file: 'unsafe-inline'; img-src file: data:; font-src file:; media-src file:; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

    init(directory: URL, entry sourceEntry: URL) throws {
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
    private var statusItem: NSStatusItem?
    private var lowPowerObserver: NSKeyValueObservation?
    private var isPausedByUser = false
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
        setupMenuBar()
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
                    let preparedWeb = manifest?["type"] as? String == "web"
                        ? try WebPackage(directory: packageURL, entry: entryURL) : nil
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

    // MARK: 메뉴바

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎬"

        let menu = NSMenu()
        let pause = NSMenuItem(
            title: "일시정지",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)
        let interaction = NSMenuItem(title: "웹 배경 상호작용 시작", action: #selector(toggleInteraction), keyEquivalent: "")
        interaction.target = self
        menu.addItem(interaction)
        let sceneInteraction = NSMenuItem(title: "씬 상호작용 시작", action: #selector(toggleSceneInteraction), keyEquivalent: "")
        sceneInteraction.target = self
        menu.addItem(sceneInteraction)

        let open = NSMenuItem(
            title: "영상 열기…",
            action: #selector(openVideo),
            keyEquivalent: "o"
        )
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Wallbloom 종료",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
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
        webViews.forEach { webView in
            webView.setAllMediaPlaybackSuspended(!shouldPlay, completionHandler: nil)
            let hook = shouldPlay ? "resume" : "pause"
            webView.evaluateJavaScript("window.wallbloom && typeof window.wallbloom.\(hook) === 'function' ? window.wallbloom.\(hook)() : undefined")
        }
        if !shouldPlay && !webViews.isEmpty {
            setInteractive(false)
            if !pauseAttentionEmitted {
                fputs("ATTENTION: WKWebView media paused and cooperative window.wallbloom.pause() requested; pages without a hook may continue arbitrary JavaScript timers. Full JavaScript suspension is not guaranteed.\n", stderr)
                pauseAttentionEmitted = true
            }
        } else { pauseAttentionEmitted = false }
        statusItem?.menu?.items.first?.title = isPausedByUser ? "재생" : "일시정지"
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
            let pauseHook = WKUserScript(source: "window.wallbloom = window.wallbloom || {};", injectionTime: .atDocumentStart, forMainFrameOnly: true)
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
        statusItem?.menu?.items.first(where: { $0.action == #selector(toggleSceneInteraction) })?.title = sceneInteractive ? "씬 상호작용 종료" : "씬 상호작용 시작"
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
        if let item = statusItem?.menu?.items.first(where: { $0.action == #selector(toggleInteraction) }) {
            item.title = isInteractive ? "웹 상호작용 종료 (Escape)" : "웹 배경 상호작용 시작"
        }
    }

    @objc private func togglePause() {
        isPausedByUser.toggle()
        applyPlaybackState()
    }

    @objc private func openVideo() {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: WallpaperController!

    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let video = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : resolveDefaultVideo()
        controller = WallpaperController(video: video)
        controller.start()
    }
}

setbuf(stdout, nil)  // 리다이렉트 시에도 즉시 로그 출력
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // Dock 아이콘 없이 실행
app.run()
