# 아키텍처

```
┌────────────────────────────────────┐
│   Wallbloom UI (Tauri/Rust, M2)    │  플랫폼 공통, 한 번만 만듦
│   라이브러리 · 다운로드 · 설정      │  (웹 기술 → macOS/Windows 동일)
└──────────────┬─────────────────────┘
               │  active.json 쓰기 (계약 파일)
       ┌───────┴─────────────────────────────┐
       ▼                                     ▼
┌────────────────────┐          ┌─────────────────────────┐
│ macOS 엔진 (Swift) │          │ Windows 엔진 (C#, M4)   │
│ AVPlayerLayer /    │          │ WorkerW + MediaElement  │
│ WKWebView (M3)     │          │ 🔮 예정                  │
│ CPU 2.2% / RAM 20MB│          │                         │
└────────────────────┘          └─────────────────────────┘
```

핵심 원칙: **엔진과 UI는 active.json으로만 대화한다.** 직접 IPC 없음.

## macOS 엔진 (M1, 현재 코드)

- `main.swift` 하나 (~230줄), 서드파티 의존성 0
- 화면마다 `NSWindow` 1개:
  - 레벨 `-2147483610` (Dock 배경화면 -2147483624 위, Finder 데스크톱 -2147483603 아래)
  - `ignoresMouseEvents=true`, `canJoinAllSpaces`, `fullScreenAuxiliary`, `stationary`
- `PlayerView.makeBackingLayer() → AVPlayerLayer` (정석 패턴 — 서브레이어 수동 부착은 실패함)
- `AVPlayerLooper` 무한 루프, muted, `resizeAspectFill`
- `preferredMaximumResolution` = 화면 해상도 (디코더 부담 절감)
- 메뉴바(NSStatusItem 🎬): 일시정지 / 영상 열기 / 종료
- 저전력 모드 자동 일시정지 (KVO)

### M2/M3 수락 경계 (일부 기능 구현, 전체 수락 미완료)

M2는 video wallpkg와 제품 UI→엔진 통합이다. UI에서 실제 선택 입력을 한 시점부터
엔진 창에서 패키지 고유 프레임이 관측될 때까지 한 번의 격리 실행에서 3초 이내여야
한다. `active.json` 교체→픽셀 전환만 잰 엔진 핫스왑, UI DOM 자동화, 준비 ACK,
별도 다운로드 검사는 각각 유용한 하위 증거지만 이 통합 수락을 대신하지 않는다.
수락에는 물리 마우스 입력, 외부 제작 video wallpkg fixture, Swift clean rebuild,
현재 소스 기준 CPU/RAM 실측도 별도로 요구한다. 2026-09-24 clean rebuild는 PASS지만
통합 runner는 최초 프레임 후 mouse-input timeout으로 FAIL했고 성능 샘플은 없다.
실행할 수 없는 항목은 구체적 차단 요소를 ATTENTION으로 남기며 SKIP은 PASS가 아니다.
각 실행은 임시 HOME을
UI와 엔진이 공유하고, 사용자 설치 앱·기본 HOME의 active.json/library를 건드리지
않으며 종료 시 임시 프로세스/파일을 복원·삭제한다. 세부 절차와 증거 분류는
`docs/UI_DESIGN.md`, `docs/ROADMAP.md`를 따른다.

### M3 macOS Web 엔진 계약

`WKWebView`는 macOS 엔진 내부의 별도 렌더 경로이며 video 경로와 기존 `active.json`
외부 인터페이스를 공유한다. `type: "web"` wallpkg의 `entry` HTML 및 패키지 내
상대 자산은 `loadFileURL(_:allowingReadAccessTo:)`로 패키지 루트에 한정해 로드한다.
경로 표준화/심볼릭 링크 검증, 외부 탐색 및 네트워크 정책, 상호작용 opt-in은
`docs/WALLPKG_SPEC.md` §2에 정의한다. 기본은 클릭 통과이며 명시적 상호작용 모드에서만
웹 콘텐츠가 포인터/키보드 입력을 받고, 앱 제공 종료 조작으로 즉시 클릭 통과 상태로
복귀한다. `active.json.paused`, 저전력 모드, 화면 생명주기에 따른 정지는 §2 정책을
따른다. 화면별 WKWebView를 생성하고 화면 연결/해제 시 재구성한다.

M3 전체 수락은 로컬 HTML/CSS/JS 및 최소 WebGL/shader 데모가 macOS에서 패키지로 로드되고,
첫 가시 프레임, 기본 클릭 통과↔opt-in↔복원, pause/저전력, 다중 화면, 보안 경계 및
CPU < 10% 리소스 측정이 검증된 경우다. 현재 `verify-web.sh`는 실제 WebKit/WebGL,
가시 픽셀, 경계 및 video 왕복을 확인(`runtime_failures=0`)했지만 CPU 미측정이다.
저전력, 전체 Spaces, 물리 마우스는 미검증이며 cooperative pause가 임의의 JS timer를
완전히 멈춘다고 보장할 수 없다는 ATTENTION이 있다. M2의 UI click-to-visible-frame 단일 측정은 별도 gate이며
WebGL 데모의 성공으로 대체하지 않는다. Unreal/Unity scene은 WKWebView 콘텐츠가
아니다. 별도 런타임/바이너리 실행·라이선스/배포·창 데스크톱 부착·리소스 예산이
필요하므로 M3 범위에서 완료 처리하지 않는다. Windows WorkerW 런타임도 macOS에서
검증할 수 없으며 M4 별도 플랫폼 수락이다.

### M5 씬 런타임 및 공유 패키지 (구현됨, 전체 수락 미완료)

`type: "scene"` 패키지는 `entry` 실행 파일을 계약으로 사용한다. macOS 엔진은 이를 자식 프로세스로 호스팅하며 종료/콘텐츠 교체 때 회수한다. 첫 Metal fixture는 독립 standalone 런타임이며 엔진 내장 게임 엔진이 아니다. Unity/Unreal standalone player도 포함 실행 파일 호환 경로일 뿐이며 창 부착, 입력, Spaces, 배포/라이선스와 리소스는 별도 검증 대상이다. 세부 계약은 `docs/WALLPKG_SPEC.md` §2.3.

공유 경로는 폴더와 `.wallpkg` export/import 및 GitHub `index.json` 레지스트리 조회/검증 설치다. 이번 검증은 archive round-trip·경로 이탈/symlink 방지와 local HTTP registry fixture, UI 연결을 통과했다. 외부 GitHub 실서비스 및 제3자 패키지 호환은 확인하지 않았다. M5 수락표와 제한은 `docs/ROADMAP.md`, `MEASUREMENTS.md` 참조. WebGL 데모는 계속 `type: web` M3 경로에 남는다.

## active.json 계약

위치(macOS): `~/Library/Application Support/Wallbloom/active.json`
스펙: docs/WALLPKG_SPEC.md

## Windows 엔진 (M4, 예정) — 조사 메모

- 창 부착: `Progman` → `SendMessageTimeout(WM_SPAWN_WORKERW)` → `WorkerW` 계층에 자식으로 붙임
  (Wallpaper Engine/Lively가 쓰는 정석 방식, "WorkerW trick" 검색)
- 재생: `MediaElement`/`MediaPlayer` (WPF) 또는 WebView2
- 멀티 모니터: 화면마다 WorkerW 분기 필요 (`SpyHelper` 패턴)
- 클릭 통과: `WS_EX_TRANSPARENT | WS_EX_LAYERED`

## Unreal/Unity scene (M5 이후, 별도 런타임) — 방향

- scene은 HTML/WebGL이 아니며 WKWebView에서 실행할 수 없다. Unreal/Unity standalone 런타임 또는 별도 통합 SDK/바이너리와 배포/버전 정책이 필요하다.
- macOS 런타임 창을 데스크톱 배경 레벨에 안정적으로 배치하고 다중 화면/Spaces/입력/전력 동작을 별도 검증해야 한다. Unity 런타임의 예상 RAM 비용은 수백 MB 규모일 수 있으나 실제 측정 전 수치는 보장하지 않는다.
- macOS에서 검증하지 않은 Windows WorkerW 및 Unreal/Unity runtime 통합을 완료로 주장하지 않는다.

## 알려진 함정 (재발 방지)

1. **HEVC `hev1` 태그는 렌더링 불가** — 반드시 `-tag:v hvc1` (README의 ffmpeg 명령)
2. layer-backed 뷰에 서브레이어를 윈도우 진입 전에 붙이면 조용히 무시됨
3. 전체화면 캡처(screencapture)로 배경화면 가시성 검증 금지 — 앱 창에 가려짐.
   `screencapture -l<windowID>`로 윈도우 단독 캡처할 것
4. stdout 파일 리다이렉트 시 블록 버퍼링 → 디버그 로깅은 `setbuf(stdout, nil)`
5. AVPlayerItem 템플릿은 여러 Looper가 공유 불가 — 화면마다 새로 생성
