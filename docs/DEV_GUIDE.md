# 개발 가이드 (M2부터 여기서 이어서)

이 문서 하나로 개발을 이어받을 수 있게 쓴 것. 폴더: `~/dev/ll3/wallbloom`

## 현재 상태 (2026-09-25 최종 직렬 재검증; 전체 수락 미완료)

- **M1** 구현 및 과거 성능 수치는 기존 기록이며 이번 감사에서 CPU/RAM 재측정하지 않음.
- **M2** 이번 integrated acceptance는 initial 1627 ms와 자동 OS click 1492 ms 후 키보드 보고서 timeout, exit 2/FAIL. 전체 통합 완료가 아니다.
- **M3** web wallpkg/grid/demo UI와 WebKit/WebGL runtime은 검사됨. `verify-web.sh` exit 0, `runtime_failures=0`. 이번 전체 재실행에서 무거운 reactive shader CPU 평균/최대 14.638%/90.500% (13 samples); 경량 기본 WebGL 직전 측정 13.531%/93.300% (13 samples). 두 모드 모두 <10% 목표 FAIL. 저전력·다중 Spaces·물리 마우스 미검증.
- 이번 직렬 acceptance는 integrated 단계에서 exit 2로 중단되어 전체 FAIL; 그 이전 `make -B`, install, bridge check, UI 9/9/build, Rust 16/16/check, scene, registry, hotswap, web, web-perf는 exit 0. `git diff --check`는 && 체인에서 실행되지 않아 별도로 확인해야 함. web CPU <10% 성능 목표는 FAIL. HITL/다중 Space/Unity·Unreal 미완료. 상세 수치/증거는 `MEASUREMENTS.md` 및 이번 작업 결과.
- 이번 integrated 재실행은 초기 Enter 입력 후 `gui-integrated-initial-input.json` 대기 timeout, exit 2/FAIL로 전환 측정이 생성되지 않음. 이전 integrated fixture 결과(1657/1717/1600 ms; 엔진 CPU 평균 0.42%, RSS 평균 53.98 MiB/최대 54.73 MiB, 15 samples)는 과거 자동 전환 결과이며 물리 마우스 HITL이 아니다.
- Spaces probe는 video/web 모두 단일 Space 환경을 보고했으며 현재 Space에서 가시 픽셀 확인. 다중 Space 순환은 계측되지 않았다. 저전력 모드는 권한 부족으로 HITL 대기. 물리 입력도 미완료.
- M5 scene fixture의 캡처/child 종료와 archive round-trip/안전성/local HTTP registry fixture는 통과. 외부 GitHub 실서비스 및 Unity/Unreal 미검증. Unity Hub/Editor, Epic Games Launcher/Unreal Editor 및 standalone player가 없어 M5 런타임 실측은 불가로 판정(호환 실패 아님); 상세 검색/후속 절차는 `docs/ROADMAP.md`. 사용자 실행 방법: `bash ui/scripts/physical-input-hitl.sh`에서 실제 입력; 저전력은 기존 `pmset -g custom` 저장 후 `sudo pmset -a lowpowermode 1` 확인 및 원복. 자동화/미실행은 PASS가 아니다. M4 Windows 미완료.
- rustra 생성 계약 drift 검사 `cd ui && bun run check:bridge`도 종료 코드 0. 생성 scan + rustra download-progress 이벤트가 실제 Tauri transport를 사용하고 select/download는 기존 native command 경로를 유지한다.
- OpenUI 실제 Renderer가 선택된 wallpkg의 로컬 메타데이터를 표시하며 화면에 AI 생성이 아님을 명시한다. GUI에서 renderer/빈 라이브러리/다운로드 실패를 확인했고 단위 테스트는 안전한 문자열 렌더링·빈 상태를 확인한다.
- 가시 픽셀 전환 A→B 1262.5 ms, B→A 1500.7 ms. 격리 `active.json` 선택 기준이며 GUI→엔진 단일 end-to-end 시간 아님.
- 실제 Tauri WebView에서 rustra scan, 선택, trusted OS Enter, OpenUI 정보 패널, 다운로드 진행/완료 및 503 오류 표시 통과. HTTP payload 13,104,509 bytes 일치, progress 215회.
- 임포트 재검증은 승인된 로컬 샘플(네트워크 0)을 라이브러리에 넣고 설치 PID 68589의 영상 창을 두 차례 캡처(pixel delta 2.9323)했다. 현재 `active.json`은 `user-video-sample`을 가리킨다. 적용 전 부재 상태 복원은 아래 임포트 절차를 참조. 물리 마우스 HITL, 저전력 HITL, 다중 Space, Windows M4 미완료.

## 저장소 구성

```
wallbloom/
├── engine/main.swift     # macOS 엔진 (active.json 감시 구현)
├── Makefile              # make / make install
├── Info.plist
├── sample-hevc.mp4       # 테스트 영상
├── MEASUREMENTS.md       # 리소스 측정 기록
└── docs/
    ├── NAMING.md         # 이름/네이밍 규칙 (단일 출처)
    ├── ROADMAP.md        # M1~M5 마일스톤
    ├── ARCHITECTURE.md   # 구조 + 알려진 함정
    ├── WALLPKG_SPEC.md   # wall.json / active.json 계약
    └── DEV_GUIDE.md      # 이 문서
```

현재 UI 구조:

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

- [x] `make` 종료 코드 0 (최종 감사 호출은 기존 산출물이 최신이라 재빌드하지 않음)
- [x] `cd ui && bun run build` 종료 코드 0
- [x] `cd ui/src-tauri && cargo check` 종료 코드 0
- [x] `cd ui && bun run test && bun run build` 종료 코드 0 (8 tests; jsdom은 native GUI 증거와 구분)
- [x] `cd ui && bun run check:bridge` 종료 코드 0 (Rust 원본에서 생성된 rustra 계약 drift 없음)
- [x] `bash ui/scripts/verify-hotswap.sh` 종료 코드 0; 가시 픽셀 A→B 1262.5 ms, B→A 1500.7 ms
- [x] `bash ui/scripts/verify-native.sh` 종료 코드 0; Tauri WebView rustra scan/OpenUI renderer/select/download 진행·완료/503 실패 확인
- [ ] 설치된 UI 선택 입력부터 엔진 표시 프레임까지 단일 end-to-end 지연 측정
- [ ] 클릭이 배경화면을 뚫고 지나가는지 (데스크톱 클릭 동작)
- [ ] CPU/RAM 재측정 및 기존 한계(CPU < 5%, RAM < 100MB)와 비교
- [x] 문서에 이번 검증 결과와 미검증 항목 기록

## 컨벤션

- 커밋: 한국어 간결 요약 + 본문 선택 (기존 이력 참고)
- 문서가 곧 단일 출처: 이름(NAMING), 계약(WALLPKG_SPEC), 함정(ARCHITECTURE)은
  코드 바꿀 때 반드시 같이 갱신

## 사용자 영상 임포트 및 복원 (2026-09-25)

`bash ui/scripts/import-user-videos.sh`는 `$HOME/Movies`, `Desktop`, `Downloads`,
`Pictures`의 mp4/mov/m4v 파일을 네트워크 접근 없이 찾는다. 이미지/영상 내용을
열람하지 않고 `sample-hevc.mp4`와 바이트 단위로 동일한 후보만 수입하며, 다른
개인 영상은 사용자 승인 없이 건드리지 않고 중단한다. 수입처는
`~/Library/Application Support/Wallbloom/library/user-video-sample/`이며 소스 영상은
저장소에 추가되지 않는다. 패키지 검증은 H.265 `hvc1` 태그를 요구한다.

이번 수행에서 `~/Movies/wallbloom.mp4`는 저장소의 유일한 무료 HEVC 샘플과 SHA-256
동일(02cd52d148a2223d90cd525e9d5371384bdac6c9309ec9c744f3cbe0876357e0)이었다.
`user-video-sample`을 active로 선택했고, 설치 엔진 PID 68589 창의 2개 캡처에서 평균
RGB 절대 픽셀 차이 2.9323을 확인했다. 증거는
`~/Library/Application Support/Wallbloom/import-evidence/` 및
`ui/scripts/import-verification.json`에 있다. 캡처는 픽셀 변화 증거이지 물리 입력,
Spaces 또는 전력/CPU 수락 증거는 아니다. 설치 앱 PID를 종료/재시작하지 않았다.

적용 전 사용자 `active.json`은 없었다. 현재 선택을 되돌려 부재 상태로 복구하려면:

```bash
rm -f "$HOME/Library/Application Support/Wallbloom/active.json"
```

이전 active.json이 존재하는 경우 임포트 스크립트는 이를 증거 디렉터리의
`active-before.json`으로 보존하고, `cp -p <증거경로>/active-before.json \\
"$HOME/Library/Application Support/Wallbloom/active.json"`로 복원한다.
