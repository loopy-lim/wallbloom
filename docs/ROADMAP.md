# 로드맵

> 목표: **macOS에서 돌아가는 오픈소스 Wallpaper Engine**. 한김에 Windows까지.
> 배경: Wallpaper Engine(Steam)은 macOS 미지원, Lively는 Windows 전용, Plash는 웹만.
> "맥에서 영상+웹 배경화면" 자리가 비어 있음.

## 마일스톤

### M1 ✅ macOS 영상 엔진 구현 (2026-09-24 기록; 이번 감사에서 재수락시험 안 함)

- Swift + AVPlayerLayer 데스크톱 레벨 루프 재생
- 측정: HEVC(hvc1) 4K 기준 **CPU 2.2%, RAM 20MB** (MEASUREMENTS.md)
- 기존 완료 기록의 기능 수치/조건은 이번 감사에서 재검증하지 않음. 현재 GUI 수락시험은 별도 필요.

### M2 🟡 진행 중 — Tauri UI + wallpkg 포맷

- [x] Tauri 스캐폴딩: `ui/` 디렉토리, Rust + TypeScript (최종 감사: `make` 0, `bun run build` 0, `cargo check` 0; make는 no-op)
- [x] 라이브러리 스캔과 그리드 렌더링; 패키지 preview 경로가 있으면 썸네일 표시
- [x] 활성 배경화면 선택 시 `active.json` 원자적 기록 구현
- [x] HTTP(S) URL 다운로드 및 진행률 이벤트 구현
- [x] 엔진의 `active.json` 폴링 및 wallpkg 영상 교체 구현 (`engine/main.swift`)
- [x] `wall.json` v0.2 핵심 video 계약의 Rust 선택/엔진 검증 경로 및 호환 fixture 확인; 다른 외부 wallpkg 변형 호환성은 미검증
- [x] 실제 GUI에서 rustra scan, 선택, OpenUI 정보 패널, 다운로드 진행/완료와 HTTP 503 실패 확인 (`verify-native.sh`)
- [x] 격리 엔진 실제 창의 가시 핫스왑 A→B 1262.5 ms, B→A 1500.7 ms (`verify-hotswap.sh`; 선택은 GUI가 아닌 격리 active.json 교체)
- [ ] UI 입력부터 native 엔진 표시 프레임까지 독립 통합 재검증: 2026-09-24 실행은 initial 1857.3 ms 후 mouse-input 보고서 timeout으로 FAIL (`MEASUREMENTS.md`); 물리 마우스 검증도 미완료
- 완료 조건: wallpkg 전반 호환성 및 실제 제품 UI 선택부터 표시까지 3초 이내 통합 검증

### M2 독립 재수락 증거 (2026-09-24, OpenUI/rustra)

- 필수 직렬 acceptance 전체 종료 코드 0: UI 8/8, Rust 7/7, frontend build, `cargo check`, `make`, strict hotswap/native 및 `git diff --check` 통과. 별도 `cd ui && bun run check:bridge`도 0(생성물 drift 없음). `make`는 `Nothing to be done`으로 Swift 재컴파일 아님.
- rustra 계약은 Rust 원본에서 독립 생성되며 UI가 generated scan과 progress event를 공식 Tauri adapter/기존 Tauri event transport로 사용한다. select/download는 기존 Tauri commands를 유지한다.
- OpenUI **로컬 renderer만**: 실제 Tauri WebView에서 선택 wallpkg의 로컬 정보가 나타나고 AI 생성이 아님을 표시. 빈 라이브러리와 오류 UI, escape 안전성/갱신은 테스트·GUI에서 확인. 생성 모델/GenUI cloud backend나 인증은 제공하지 않으며 해당 기능은 미완료/범위 외.
- 가시 프레임 핫스왑 **PASS**: A→B 1262.5 ms, B→A 1500.7 ms. 격리 active.json 선택→캡처 픽셀 확인이며 UI click-to-frame 시간은 아니다.
- Tauri GUI **PASS**: rustra scan, DOM 카드 native select, trusted OS Enter, OpenUI panel, 다운로드 progress/completion 및 503 error UI. DOM 자동화이지 물리 마우스 클릭 아님.
- localhost downloader PASS: payload 13,104,509 bytes, progress 215회, 실패/절단/중복 경로 cleanup. 사용자 설치 PID 68589 및 사용자 active.json 부재 상태 전후 동일.
- 증거: hotswap `/var/folders/z8/h16kj6d16t53dj0lfvlkxf0h0000gn/T/wallbloom-hotswap-evidence-10qlygun`; native `/var/folders/z8/h16kj6d16t53dj0lfvlkxf0h0000gn/T/wallbloom-native-evidence-ywnPJ0`; 통합 상세 `ui/INTEGRATIONS.md`.
- 미완료: UI 선택→엔진 표시의 단일 end-to-end 시간, 물리 마우스 검증, 외부 wallpkg 전반 호환성, Swift clean rebuild 및 CPU/RAM 회귀 측정. 따라서 M2는 계속 진행 중이다.

### M3 🟡 macOS Web 엔진 (기능 구현, 전체 수락 미완료)

- 데스크톱 레벨 WKWebView로 HTML 배경화면 재생 (Wallpaper Engine의 web 타입 대응)
- wallpkg의 `type: "web"` 처리, 폴더 통째로 임포트 지원
- [x] wallpkg 폴더 임포트, 그리드 선택 및 반응형 웹 데모 UI 구현 (UI/Rust tests/build 통과)
- [x] 로컬 WebGL shader demo 실제 WebKit 실행·가시 캡처, web/video 왕복 및 보안 경계 검사 (`verify-web.sh`, runtime_failures=0)
- [ ] 전체 수락: Web CPU < 10% 실측, 저전력/여러 Spaces/물리 마우스 검증. 2026-09-25 직렬 run의 무거운 reactive shader CPU 평균/최대 13.946%/92.500% (13 samples), 경량 기본 WebGL 직전 측정 13.531%/93.300% (13 samples)로 양쪽 모두 목표 FAIL. 저전력 HITL 대기. Spaces probe는 video/web 각각 현재 단일 Space만 계측했으며 다중 Space 검증 아님. 물리 입력 미완료.
- 완료 조건: shadertoy 스타일 HTML 배경이 안정 구동 (CPU < 10%) 및 위 환경 검증

### 이전 독립 재검증 (2026-09-24)

- `make -B`, UI bridge/tests 9/9/build, Rust 12/12/check, integrated, hotswap, web, spaces 환경 계측, `git diff --check` 통과. Web CPU 목표 미달; 저전력 HITL 대기.
- Integrated 실측 Enter→A 1657 ms, OS click→B 785 ms, Enter→A 1097 ms. 엔진 video CPU 평균 0.48%, RSS 평균 53.70 MiB (15 samples). 입력은 OS 자동화이며 물리 입력 검증이 아니다.
- Spaces probe가 video/web 각각 Space 1개와 해당 Space 엔진 픽셀 가시성을 기록. 실제 순환 없음은 설정/환경 결과로 남기며 전체 Spaces 수락으로 처리하지 않는다.
- HITL 실행 방법 및 증거 조건은 `MEASUREMENTS.md`에 기록. Windows M4 및 Unreal/Unity M5 미완료 유지.

### M4 🔜 Windows 영상 엔진 (C#) — 미구현·미검증

- Win32 WorkerW 트릭으로 데스크톱 아이콘 뒤에 창 부착
- MediaElement/Win2D 기반 루프 재생, 같은 `active.json` 계약 소비
- 같은 Tauri UI 재사용 (WebView2)
- 완료 조건: Windows 11에서 멀티 모니터 영상 배경화면 + 클릭 통과

### M5 🟡 씬 엔진 & 생태계 — 일부 구현 및 fixture 검증, 전체 수락 미완료

- 계약: `type: "scene"` wallpkg의 `entry` 실행 파일을 macOS 엔진이 자식 프로세스로 실행하고 데스크톱 레벨 렌더링한다. 실행 파일 및 `scene.interactive` 계약/JSON 예시는 `docs/WALLPKG_SPEC.md` §2.3 참조. Unity/Unreal macOS standalone player는 포함 파일을 실행하는 호환 경로일 뿐 엔진 내장 런타임이 아니며, 창 부착·입력·Spaces·리소스 동작은 별도 검증한다.
- 우선 범위: macOS 첫 Metal 반응형 파티클/셰이더 씬 런타임. 공유 v0.1은 폴더↔단일 `.wallpkg` 아카이브 export/import; 레지스트리는 GitHub `index.json` + HTTPS 다운로드 URL 및 hash 검증, UI 브라우징/사용자 선택 설치. 파일/계약 경계는 `docs/WALLPKG_SPEC.md` §2.3에 둔다. Steam Workshop 콘텐츠는 가져오지 않는다.
- [x] `verify-scene.sh`: standalone Metal fixture 캡처의 fixture 유사 픽셀 7,997개, scene 자식 실행·전환 종료·엔진 종료 시 회수 검증. 입력 정책, Spaces/저전력 및 지속 성능 측정 증거는 아님.
- [x] `verify-registry.sh`: archive round-trip, ZIP traversal/symlink 거부, local HTTP registry fetch/install tests 및 UI wiring 통과.
- [ ] 실시간 GitHub registry/외부 제작자 패키지 호환성 검증 (이번 검사는 local fixture만).
- [ ] scene interactive opt-in/복원 실제 입력, 다중 Space/저전력 및 지속 CPU/RAM 측정.
- [ ] Unity/Unreal standalone player 호환성 검증. 문서화한 실행 파일 contract는 검증 결과가 아니다.
- WebGL 데모는 M3 경로로 유지하며 scene으로 대체하지 않는다. 2026-09-25 직렬 재검증에서 reactive shader CPU 평균/최대 13.946%/92.500%, 경량 기본 모드 13.531%/93.300% (각 13 samples)로 양쪽 모두 CPU < 10% 목표 미달(FAIL)이며 M5 통과 근거가 아니다. 저전력 HITL 대기, 다중 Spaces 및 물리 마우스 미검증이며 SKIP/HITL은 성공이 아니다. Windows M4 미완료 상태를 유지한다.
- M5 수락 기준: scene fixture가 엔진 자식 프로세스로 시작·종료되고 macOS 데스크톱 배경에서 Metal 반응형 픽셀이 확인될 것; interactive false 입력 통과 및 true opt-in/복원이 실제 입력으로 검증될 것; `.wallpkg` export→안전 임포트 왕복과 손상/경로 이탈 거부, 레지스트리 인덱스 조회→URL/hash/패키지 검증 설치가 확인될 것. 씬 CPU/RAM, 다중 화면/Spaces, 저전력 동작은 수치·증거와 함께 별도 기록하며 미검증은 미완료로 남긴다. Unity/Unreal standalone 검증은 별도 호환성 표로 기록한다.

### M5 + 임포트 통합 재검증 (2026-09-24 23:43–23:45 KST)

`MEASUREMENTS.md`에 증거 경로와 상세 수치를 기록했다. `make -B`, UI 9/9/build, Rust 16/16/check, scene, registry, hotswap, web 및 `git diff --check` PASS. Scene 캡처에서 fixture 유사 픽셀 7,997개를 확인했고 registry는 local HTTP fixture에 한정된다. 실제 사용자 영상은 네트워크 없이 승인 샘플과 동일한 `~/Movies/wallbloom.mp4`에서 Application Support 라이브러리로 임포트했으며 설치 앱 PID 68589 창의 두 캡처 pixel delta는 2.9323이었다.

`verify-integrated.sh`는 자동 OS Enter→A 1627 ms, click→B 1492 ms 후 마지막 키보드 evidence timeout으로 exit 2/FAIL; 세 전환 수락이 아니며 물리 마우스 증거도 아니다. 저전력 HITL 미수행, 다중 Space 미검증. Web CPU 최신 수치는 13.108%(13 samples), 목표 <10% FAIL이며 이번 감사에서 재측정하지 않았다. Windows M4 미완료. SKIP/HITL은 PASS가 아니다. 사용자 영상 적용 전 active.json은 부재였고 복원 방법은 `docs/DEV_GUIDE.md`에 유지한다.

#### M5 독립 full-rerun (2026-09-24 23:51 KST)

동일 full-rerun을 직렬로 독립 재실행: 전체 종료 코드 **0**. `make -B`, bridge check, UI 9/9/build, Rust 16/16/check, `verify-scene.sh`(fixture 유사 픽셀 8,074), `verify-registry.sh`(local fixture), `verify-hotswap.sh`(A→B 1126 ms, B→A 736 ms), `verify-web.sh`(248 WebGL frames, runtime_failures=0), `git diff --check`가 모두 종료 코드 0. 세부 명령별 결과 및 증거 경로는 `MEASUREMENTS.md`의 같은 시각 기록을 참조한다. 사용자 영상 적용은 앞선 임포트 exit 0 기록에 한정해 인정하며, 현 active.json의 `user-video-sample` 상태와 복원 명령을 재확인했다.

이 rerun은 M5에서 실제 검사한 씬 fixture 런타임/패키징·로컬 레지스트리 경로만 확인한다. 외부 live registry·외부 제작자 호환성, interactive 실제 입력, 지속 성능은 미완료다. 물리 마우스 HITL(통합 재시도 exit 2), 저전력 HITL, 다중 Space, Web CPU <10%(기록값 13.108%, 이번에 재측정 안 함), Windows M4를 완료로 표시하지 않는다. 따라서 M5는 부분 검증, 전체 수락 미완료로 유지한다. 모델 식별자 `gpt-6-luna`, provider `openai-codex`(환경 식별이며 라우팅 증명 아님).

#### Unity/Unreal standalone 실측 가능 여부 (2026-09-25 00:01 KST)

- **현재 머신에서는 실측 불가**: macOS 26.6.2 arm64에서 Unity Hub/Editor, Epic Games Launcher/Unreal Editor 및 빌드된 Unity/Unreal player를 찾지 못했다. 따라서 `type: "scene"` standalone player의 빌드→Wallbloom 실행→창 부착·종료·CPU/RAM 검증은 시도할 입력 바이너리와 빌드 도구가 없어 수행하지 않았다. 이는 호환 실패가 아니라 필수 설치물 부재이며 M5 완료 증거가 아니다.
- 확인 명령과 관측 출력: `find /Applications /Users/loopy/Applications ...` 및 Spotlight bundle-ID 조회 결과 후보 0개, `find /Applications/Unity/Hub/Editor ...` 결과 0개, `/Users/Shared/Epic Games`는 `MISSING`, `command -v unity Unity UnrealEditor ue4editor` 결과 0개였다. `pkgutil --pkgs | grep -Ei 'unity|unreal|epic'`, Homebrew cask 조회, `UnityPlayer.dylib`·`globalgamemanagers`·`GameAssembly.dylib`·`.uproject` 검색도 결과 0개였다. 실행 중인 `UnityPosterApp` 프로세스는 iOS Simulator의 Apple Poster extension 경로로, Unity Editor나 제작된 Unity player로 판정하지 않았다.
- 다음 단계(Unity): 공식 [Unity Hub](https://unity.com/download)를 설치하고 Hub에서 Apple silicon을 지원하는 Editor를 설치한다. 최소 scene을 macOS standalone `.app`으로 빌드한 뒤 필요한 데이터/라이브러리를 포함한 앱 번들 전체를 wallpkg 내부에 두고, `entry`를 `.app/Contents/MacOS/<실행 파일>`로 지정한다.
- 다음 단계(Unreal): 공식 [Epic Games Launcher](https://www.unrealengine.com/download)를 설치하고 Launcher에서 macOS용 Unreal Engine을 설치한다. 최소 프로젝트를 macOS `.app`으로 package한 뒤 앱 번들 전체를 wallpkg에 넣고 같은 `entry` 실행 파일 계약을 적용한다.
- 설치 후 각 엔진별로 별도 패키지를 만들고 `verify-scene.sh`에 준하는 격리 HOME에서 시작 ACK, 실제 픽셀, scene 전환/엔진 종료 시 자식 회수부터 확인한다. 그 다음 데스크톱 레벨 창 부착, `scene.interactive` 입력·복원, 여러 화면/Spaces, 저전력 pause/resume, 지속 CPU/RAM을 각각 실측해 호환성 표에 기록한다. 설치만으로 통과 처리하지 않는다.
- 이 확인 워커의 환경 식별자는 `openai-codex/gpt-5.6-sol`이다. 최종 직렬 수락 워커는 `openai-codex/gpt-6-luna` 환경을 보고했다.

## 원칙

1. **엔진-UI 분리**: UI는 `active.json`만 쓰고, 엔진은 `active.json`만 읽는다.
   플랫폼별 엔진이 달라도 UI는 하나.
2. **리소스 상한 의식**: 영상 엔진은 CPU < 5%, RAM < 100MB를 유지한다. 회귀 시 측정 문서 갱신.
3. **독립 포맷**: Steam Workshop 콘텐츠를 긁어오지 않는다. 같은 경험을 자체 오픈 포맷으로.
4. **문서 갱신**: 마일스톤 완료 시 이 파일의 체크박스와 MEASUREMENTS.md를 함께 갱신.
