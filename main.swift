// Wallbloom — minimal native macOS video wallpaper
//
// 영상 배경화면을 데스크톱 레벨에서 루프 재생하는 최소 앱.
// AVPlayerLayer(AVFoundation) 하드웨어 디코딩을 사용한다. 서드파티 의존성 없음.
//
// 사용법: Wallbloom [영상파일경로]
//   경로를 주지 않으면 기본 후보 경로 중 존재하는 것을 재생한다.

import AppKit
import AVFoundation

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

// MARK: - WallpaperController

/// 화면마다 하나의 데스크톱 레벨 윈도우를 만들고 AVPlayer로 루프 재생한다.
final class WallpaperController: NSObject {

    private var currentVideo: URL
    private var windows: [NSWindow] = []
    private var players: [AVQueuePlayer] = []
    private var loopers: [AVPlayerLooper] = []
    private var statusItem: NSStatusItem?
    private var lowPowerObserver: NSKeyValueObservation?
    private var isPausedByUser = false

    init(video: URL) {
        self.currentVideo = video
        super.init()
    }

    func start() {
        buildWindows()
        setupMenuBar()
        setupObservers()
    }

    // MARK: 윈도우 / 재생 구성

    private func buildWindows() {
        teardown()

        for screen in NSScreen.screens {
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
            playerLayer.videoGravity = .resizeAspectFill

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
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true   // 클릭 완전 통과
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            window.orderFrontRegardless()

            windows.append(window)
            player.play()
        }
    }

    private func teardown() {
        loopers.removeAll()
        players.forEach { $0.pause(); $0.removeAllItems() }
        players.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
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
            self?.buildWindows()
        }
    }

    private func applyPlaybackState() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let shouldPlay = !isPausedByUser && !lowPower
        players.forEach { shouldPlay ? $0.play() : $0.pause() }
        statusItem?.menu?.items.first?.title = isPausedByUser ? "재생" : "일시정지"
    }

    // MARK: 액션

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
        buildWindows()
    }
}

// MARK: - 부트스트랩

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: WallpaperController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let video: URL
        if args.count > 1 {
            video = URL(fileURLWithPath: args[1])
        } else {
            video = resolveDefaultVideo()
        }
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
