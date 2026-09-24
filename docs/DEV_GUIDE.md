# 개발 가이드 (M2부터 여기서 이어서)

이 문서 하나로 개발을 이어받을 수 있게 쓴 것. 폴더: `~/dev/ll3/wallbloom`

## 현재 상태 (2026-09-24)

- **M1 완료**: macOS 영상 엔진이 `/Applications/Wallbloom.app`로 설치·실행 중
- GitHub: `github.com/loopy-lim/wallbloom` (main 브랜치)
- 다음 작업: **M2 — Tauri UI + wallpkg** (docs/ROADMAP.md)

## 저장소 구성

```
wallbloom/
├── main.swift            # macOS 엔진 (M1 완성 — M2에서 active.json 감시 추가)
├── Makefile              # make / make install
├── Info.plist
├── sample-hevc.mp4       # 테스트 영상 (gitignore됨)
├── MEASUREMENTS.md       # 리소스 측정 기록
└── docs/
    ├── NAMING.md         # 이름/네이밍 규칙 (단일 출처)
    ├── ROADMAP.md        # M1~M5 마일스톤
    ├── ARCHITECTURE.md   # 구조 + 알려진 함정
    ├── WALLPKG_SPEC.md   # wall.json / active.json 계약
    └── DEV_GUIDE.md      # 이 문서
```

M2부터 추가될 구조:

```
wallbloom/
├── engine/               # main.swift를 이동 (엔진 전용)
├── ui/                   # Tauri 앱 (Rust + TypeScript)
│   ├── src-tauri/        # 다운로더, 라이브러리 스캔, active.json 기록
│   └── src/              # 라이브러리 그리드 UI
└── docs/
```

## 사전 준비 (M2용)

```bash
# Rust (없으면)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Tauri CLI + 프론트 툴체인
bun add -g @tauri-apps/cli     # 또는 cargo install tauri-cli
bun --version                  # 1.4.1 확인됨
```

macOS 빌드 요구사항은 이미 충족 (Xcode + Swift 6.2 설치됨).

## 자주 쓰는 명령

```bash
# 엔진 빌드/설치/실행
make && make install && open /Applications/Wallbloom.app --args <영상경로>

# 엔진 종료
pkill -f 'Wallbloom.app/Contents/MacOS'

# 윈도우 렌더링 검증 (전체화면 캡처 금지! ARCHITECTURE.md 함정 #3)
screencapture -x -o -l<windowID> /tmp/cap.png

# hvc1 테스트 영상 만들기
ffmpeg -i input.mp4 -c:v hevc_videotoolbox -b:v 12M -tag:v hvc1 -an out.mp4
```

## M2 작업 순서 (제안)

1. `engine/` 분리 + `active.json` 감시 추가 (~20줄, WALLPKG_SPEC.md §3 규칙 준수)
2. `ui/` Tauri 스캐폴딩 (`bun create tauri-app` 대신 수동 구성도 무방)
3. 라이브러리 스캔: `library/` 폴더의 wallpkg 매니페스트 읽기
4. 그리드 UI: 썸네일 클릭 → `active.json` 원자적 쓰기 → 3초 내 전환 확인
5. URL 다운로드 v1 (Rust reqwest, 진행률 이벤트)

## 검증 체크리스트 (커밋 전)

- [ ] `make` 경고/에러 0
- [ ] 설치 후 실행, 두 모니터 모두 재생 확인
- [ ] 클릭이 배경화면을 뚫고 지나가는지 (데스크톱 클릭 동작)
- [ ] MEASUREMENTS.md 수치 유지 (CPU < 5%, RAM < 100MB)
- [ ] 문서 갱신: 체크박스/스펙 버전/측정치

## 컨벤션

- 커밋: 한국어 간결 요약 + 본문 선택 (기존 이력 참고)
- 문서가 곧 단일 출처: 이름(NAMING), 계약(WALLPKG_SPEC), 함정(ARCHITECTURE)은
  코드 바꿀 때 반드시 같이 갱신
