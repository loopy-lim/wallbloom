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
│ AVPlayerLayer      │          │ WorkerW + MediaElement  │
│ ✅ M1 완성          │          │ 🔮 예정                  │
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

### M2에서 추가될 것

`active.json` 파일 감시 (DispatchSource / FSEvents, ~20줄):
변경 감지 → `currentVideo` 교체 → `buildWindows()` 재호출. UI 없이도
`echo > active.json`로 배경화면이 바뀌면 계약이 맞는 것.

## active.json 계약

위치(macOS): `~/Library/Application Support/Wallbloom/active.json`
스펙: docs/WALLPKG_SPEC.md

## Windows 엔진 (M4, 예정) — 조사 메모

- 창 부착: `Progman` → `SendMessageTimeout(WM_SPAWN_WORKERW)` → `WorkerW` 계층에 자식으로 붙임
  (Wallpaper Engine/Lively가 쓰는 정석 방식, "WorkerW trick" 검색)
- 재생: `MediaElement`/`MediaPlayer` (WPF) 또는 WebView2
- 멀티 모니터: 화면마다 WorkerW 분기 필요 (`SpyHelper` 패턴)
- 클릭 통과: `WS_EX_TRANSPARENT | WS_EX_LAYERED`

## Unity 씬 엔진 (M5, 예정) — 방향

- Unity standalone player 창을 동일하게 WorkerW에 부착
- 용도는 영상 재생이 아니라 **셰이더/파티클 실시간 씬** 배경화면
- 비용: Unity 런타임 RAM ~200-400MB (영상 전용으로는 과함 — 용도 구분 명확히)

## 알려진 함정 (재발 방지)

1. **HEVC `hev1` 태그는 렌더링 불가** — 반드시 `-tag:v hvc1` (README의 ffmpeg 명령)
2. layer-backed 뷰에 서브레이어를 윈도우 진입 전에 붙이면 조용히 무시됨
3. 전체화면 캡처(screencapture)로 배경화면 가시성 검증 금지 — 앱 창에 가려짐.
   `screencapture -l<windowID>`로 윈도우 단독 캡처할 것
4. stdout 파일 리다이렉트 시 블록 버퍼링 → 디버그 로깅은 `setbuf(stdout, nil)`
5. AVPlayerItem 템플릿은 여러 Looper가 공유 불가 — 화면마다 새로 생성
