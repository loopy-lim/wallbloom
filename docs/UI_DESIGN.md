# UI 및 실제 수락 테스트 설계

> **최신 상태 (2026-09-24):** 아래의 초기/통합 설계 결정 중 “OpenUI/rustra 미적용” 부분은 구현 및 재수락으로 대체됐다. 현재 실제 구현/검증 결과는 이 문서의 마지막 `OpenUI + rustra 재수락` 절과 `ui/INTEGRATIONS.md`를 따른다.

## 현재 UI 결정

- **shadcn/ui + Tailwind 유지.** `ui/src/App.tsx`가 로컬 Button/Card/Input을 사용하고 Tailwind 스타일로 화면을 구성한다. 테스트와 프로덕션 빌드는 `bash ui/scripts/verify-ui.sh`로 확인하되, jsdom/Tauri mock 결과는 native GUI 증거로 취급하지 않는다.
- **OpenUI는 로컬 정보 패널의 Renderer로 적용.** 모델 응답이나 cloud/GenUI 생성 기능은 아니다. 설치된 API는 native Tauri WebView에서 검증했으며 공식 docs host는 DNS 제한으로 직접 대조하지 못했다. 상세 경계와 증거는 아래 재수락 기록 참조.
- **rustra: typed contract를 실제 Tauri runtime에 연결했다.** 생성 scan 및 progress event가 UI에서 사용되고, 기존 select/download Tauri command는 보존한다. rustra는 인증·백엔드·AI 기능을 제공하지 않는다. 고정 버전, 생성 및 runtime 흐름은 `ui/INTEGRATIONS.md` 참조.

## 초기 설계 기록: 파일 쓰기 != 화면 적용

아래 사전 점검/다음 작업자 항목은 이전 시점 기록이다. 최신 구현 경계는 마지막 절을 따른다.

`select_wallpaper` 성공 및 `active.json` 변경은 UI→파일 계약만 증명한다. 엔진은 750ms 주기로 파일을 읽고, `buildWindows()`가 창/플레이어를 재구성하지만 현재 native 엔진은 새 영상의 표시 완료 ACK/frame identity를 내보내지 않는다. 그러므로 현재 상태만으로 **3초 핫스왑 PASS를 측정할 수 없다.** 다음 구현은 테스트 관측 수단을 먼저 제공해야 한다.

권장 최소 관측 설계:

1. 실행별 격리된 임시 `HOME`으로 UI와 엔진을 모두 실행한다. 둘 다 `HOME/Library/Application Support/Wallbloom`을 기준으로 하므로 동일한 임시 홈을 공유한다. `mktemp -d`로 만들고 종료 trap에서 프로세스 종료 후 임시 디렉터리를 제거한다. `/Applications/Wallbloom.app`의 기존 프로세스를 재사용·종료하지 말고 사용자 기본 홈의 active/library 파일도 덮어쓰지 않는다.
2. 실제 Tauri UI에서 localhost fixture URL을 다운로드한다. fixture server는 테스트 프로세스가 loopback에만 바인딩하고 요청 로그/상태 코드/전송 byte 수를 남긴다. 응답 본문은 저장 가능한 테스트 영상 fixture로 하고 Content-Length를 제공한다. 통제된 속도/크기의 응답으로 진행 이벤트도 확인한다. 다운로드 PASS는 HTTP server의 실제 GET 및 전체 byte 전송, Rust 저장 파일의 크기/hash, 완성된 wallpkg 검증, UI 다운로드 완료 상태를 함께 대조할 때만 준다. 단순 `download_wallpaper` 반환만으로는 충분하지 않다.
3. A/B 각각 서로 다른 시각적 식별이 명확한 유효 wallpkg fixture를 준비한다. 기준 시점은 실제 선택 입력 직전 단조 시계(monotonic clock)의 `t0`로 기록한다. Rust command 성공 및 active.json 확인은 중간 단계일 뿐이다.
4. 엔진은 선택 패키지에 대한 적용 ACK를 로그/테스트 IPC로 내야 한다. ACK는 파일 파싱이 아니라 AVPlayerItem의 준비 상태 이후 실제 영상 프레임이 표시 가능한 상태임을 확인하고, package ID 및 단조 시각을 담는다. 동시에 GUI 자동화/화면 캡처에서 A→B 고유 영상 픽셀 전환을 확인한다. `t_visible - t0 <= 3.000s`를 모든 관측 반복에서 만족해야 한다. ACK만으로 실제 화면을, screenshot만으로 다운로드를 주장하지 않는다. 둘의 신호가 불일치하면 FAIL/원인 조사다.
5. 임시 HOME에 앱 데이터/설정만 격리한다. native wallpaper 창은 실제 사용자 데스크톱을 가릴 수 있으므로 명시적 GUI 테스트 세션에서만 수행하고, 시작 전 화면 상태를 기록하며 끝난 뒤 앱 종료와 원상태 복원을 확인한다. 권한/자동화 불가 시 성공으로 위장하지 않고 `ATTENTION`으로 보고한다.

### 수락 결과 분류

- **PASS:** 관측한 완전한 시나리오와 측정값, 로그/artifact가 남음.
- **FAIL:** 실행했지만 기대 결과나 시간 기준을 만족하지 못함.
- **ATTENTION (미실행/환경 차단):** 권한 또는 GUI/runtime 전제 미충족. 체크 스크립트는 0을 반환하는 SKIP 대신 nonzero 또는 명시적 `ATTENTION` 결과를 내며, 이를 PASS 집계에서 제외한다.

## 이번 작업 환경의 사전 점검 (2026-09-24)

- macOS arm64/Darwin 25.6.0. `launchctl print gui/$(id -u)` 결과에 `session = Aqua`가 있어 GUI login session은 존재한다. `osascript -e 'tell application "System Events" to get name'`가 `System Events`를 반환해 해당 Apple Event 호출은 동작했다. 이것은 TCC Accessibility/Automation 권한 전체나 화면 캡처 권한을 증명하지 않는다. `Wallbloom` 프로세스 `/Applications/Wallbloom.app/Contents/MacOS/Wallbloom` (PID 68589)가 이미 실행 중이므로 이번 점검에서는 조작하거나 종료하지 않았다. 실제 Tauri 창 자동 조작 및 화면 픽셀 검증은 실행하지 않았으며 권한/접근성 수락은 **미검증**이다.
- 저장소의 `Wallbloom.app/Contents/MacOS/Wallbloom`은 executable이고 `sample-hevc.mp4`는 존재(12 MB)한다. 이는 native 앱 빌드물/fixture의 존재만 증명한다. Tauri GUI 실행 가능 여부는 별도이며 이번에 `tauri dev/build` 창을 띄워 확인하지 않았다. 따라서 Tauri 창 실행성은 **미검증**, not PASS.
- `python3` loopback socket bind 성공, 임시 `ThreadingHTTPServer`로 `127.0.0.1`에 HTTP GET을 보내 응답 `b'wallbloom-test'` 수신(HTTP 200 로그) 성공. localhost HTTP fixture 실행은 가능하다. 단, 이번 smoke test는 Tauri Rust downloader 통합 테스트가 아니다.
- 환경 변수는 `PI_PROVIDER=openai-codex`, `PI_MODEL=gpt-6-luna`. 이는 이 worker의 실행 환경이 보고한 식별자이며, 별도 Loop 라우팅 로그가 없으므로 DAS 여부나 Loop 전체 모델 라우팅에 대한 추가 주장은 하지 않는다.

## 다음 작업자: 파일별 검증 및 완료 기준

> 아래 체크리스트는 현재 구현 이전의 계획 기록이다. OpenUI/rustra 검증은 문서 마지막 재수락 절을 기준으로 한다.

1. **`engine/main.swift`** — 최소한의 테스트 관측 가능한 적용 ACK 추가. ACK는 선택 ID 및 monotonic timestamp를 포함하고, 플레이어 준비/첫 유효 표시 프레임 이전에는 내지 않는다. `active.json` 파싱/창 생성만으로 ACK를 내지 않는다. 임시 HOME의 A→B 전환에서 ACK와 화면 영상 ID를 대조하고 각 전환 3초 이내를 증명한다. 기존 사용자 앱/배경 상태를 변경하지 않는다.
2. **`ui/src-tauri/src/lib.rs` 및 `ui/scripts/` 통합 테스트** — 임시 HOME, `127.0.0.1` 테스트 HTTP server, 고유 fixture 이름을 사용. 실제 GET/bytes/hash, 진행 event, package 생성/scan/select를 확인한다. download 중단·비정상 HTTP도 확인하고 cleanup한다. 외부 인터넷에 의존하지 않는다.
3. **`ui/src/App.tsx` / UI 테스트** — 기존 jsdom 테스트는 유지한다. native 창에서 다운로드→그리드 새 항목→선택 흐름을 실제로 수행하고 UI 상태 및 이벤트를 관찰한다. jsdom PASS를 native GUI PASS와 합산하지 않는다.
4. **`ui/scripts/verify-hotswap.sh`** — 실행 전제 부재는 0/성공 SKIP으로 끝내지 말고 명시적 nonzero 또는 구조화된 ATTENTION으로 반환한다. native GUI/실제 Tauri/적용 ACK/고유 프레임 관측이 모두 있어야 PASS 가능. 선택 직전부터 표시 완료까지 monotonic latency와 원시 로그를 저장한다.
5. **`docs/ROADMAP.md`** — M2 완료 체크는 위 GUI 선택 및 실제 표시 3초 측정, localhost 실다운로드가 모두 PASS하고 로그가 보존된 이후에만 갱신한다. 각 PASS/FAIL/ATTENTION과 실행 환경을 기록한다.
6. **모델 증거** — worker 시작/완료 보고에 실제 실행 식별자 및 provider/model을 기록하고, 가능한 경우 Loop의 worker 로그/실행 요약을 첨부한다. 환경변수만 있으면 그 출처를 명시하며 Loop 자체가 DAS라고 단정하지 않는다.

`verify-ui.sh`는 계속 유효한 자동 UI/build 검사지만, 위 native accept checks의 대체물이 아니다. 기존 `verify-hotswap.sh`는 조건이 부족하면 종료 코드 0으로 SKIP하므로 현재 M2 완료 증거로 인정하지 않는다.

## 독립 최종 재실행 결과 (2026-09-24)

직렬 acceptance 전체는 종료 코드 0. 가시 캡처 픽셀 A→B 1305 ms, B→A 1486 ms(격리 `active.json` 선택부터 캡처 분석 완료). 실제 Tauri WebView IPC scan/select, OS Enter, 다운로드 진행/완료 및 503 실패 렌더링 통과; localhost downloader 실제 bytes 13,104,509 일치, progress 208회. 설치 앱 PID 68589 및 사용자 active.json 미존재 상태는 전후 동일. 증거와 실행 로그는 `MEASUREMENTS.md`의 경로 참고.

전체 명령의 첫 병행 시도에서는 cargo HTTP fixture test가 `WouldBlock` bind 오류로 실패했고, 직렬 재실행에서는 통과했다. `make`는 `Nothing to be done`이라 Swift clean rebuild는 아니며 CPU/RAM 회귀도 미측정이다. M2 완료 전체를 주장하지 않는다.

## OpenUI + rustra 통합 결정 (integration-design)

### 결정 요약

- **rustra: 생성된 scan/event 계약을 실제 Tauri bridge로 사용한다.** select/download는 기존 Tauri command를 그대로 사용하며, 전체 command를 rustra 경로로 옮겼다고 주장하지 않는다.
- **OpenUI: 실제 로컬 renderer를 제한된 wallpkg 정보 패널에 사용한다.** OpenUI는 앱이 생성한 결정적 로컬 정보를 렌더링하며 모델 호출/GenUI cloud 응답은 아니다. 화면에 AI 생성이 아님을 명시한다. 현재 제품에 생성 백엔드/사용자 모델 자격증명은 없다.
- 실제 API/렌더링은 설치된 `@openuidev/react-lang@0.3.0` API와 Tauri WebView에서 검증했다. 공식 docs host는 DNS 제한으로 대조하지 못했으며, 근거/경계는 `ui/INTEGRATIONS.md`에 기록돼 있다.

### rustra 버전, 데이터 흐름 및 경계

조사 시점의 고정 후보 버전은 `@rustra/tauri@0.9.3`, `@rustra/types@0.12.0`, `@rustra/cli@0.11.3`이다. 기존 `@tauri-apps/api`는 유지한다. Tauri crate는 조사 결과에서 2.11.5 exact pin으로 확인됐으나 lockfile의 2.11.6과 공존/호환 검증이 남아 있으므로 설치 전 crate·lockfile 조합을 확인하고 무리하게 downgrade하지 않는다. 버전은 설치 직전에 registry와 upstream README/release를 재확인하며, 실제 채택 버전 및 lockfile 결과를 구현 PR에 기록한다.

기대 데이터 흐름:

1. rustra 설정은 `ui/src-tauri/src/lib.rs`의 제품 command와 이벤트 payload를 계약 원본으로 삼는다. `scan_library() -> Vec<WallPackage>`, `select_wallpaper(id) -> ()`, `download_wallpaper(url) -> String`, `download-progress` payload `{ receivedBytes, totalBytes }`를 포함한다. GUI acceptance 전용 `gui_acceptance_report`는 `native-acceptance` feature에서만 노출되므로 제품 계약에 넣지 않는다.
2. 고정 CLI로 Rust에서 TypeScript 계약/client를 생성한다. 생성 파일은 재생성 가능한 산출물이며 `bun run check:bridge`로 drift를 검사한다. 앱은 generated scan과 progress event를 사용한다.
3. select/download는 현재 handwritten Tauri `invoke` command를 유지한다. bridge가 적용되지 않은 나머지 제품 command를 generated client 사용으로 계산하지 않는다. 생성 scan/event와 기존 명령 간 단일 실행 경로를 유지한다.
4. 데이터/권한 경계는 현재와 동일하게 로컬 라이브러리 및 사용자가 입력한 다운로드 URL뿐이다. rustra는 타입/전송 bridge이지 인증·백엔드·생성 기능이 아니다. OpenAI Codex OAuth 또는 개발자 세션을 앱 서비스 자격증명으로 재사용하지 않으며, 없는 비밀 키나 cloud service를 가정하지 않는다.

### 후속 구현의 검증과 롤백

- 구현 근거: `ui/src-tauri/src/lib.rs`, `ui/src-tauri/src/bridge.rs`, `ui/src/lib/bridge.ts`, `ui/src/App.tsx`, `ui/src/components/LibraryInfoPanel.tsx`, `ui/package.json`, `docs/WALLPKG_SPEC.md` §4. OpenUI 실제 export/API와 rustra upstream 및 생성 artifact 조사 근거·한계는 `ui/INTEGRATIONS.md`.
- 적용 버전: `@rustra/tauri@0.9.3`, `@rustra/types@0.12.0`, `@rustra/cli@0.11.3`, Rust crate `rustra=0.11.0`; 실제 install/codegen 명령은 `ui/INTEGRATIONS.md`에 기록. OpenUI `@openuidev/react-lang@0.3.0`.
- 테스트: 변경 전후 `bash ui/scripts/verify-ui.sh`; 생성 산출물 재생성 후 diff가 깨끗한지 검사; frontend 단위 테스트에서 generated client의 scan/select와 event subscribe/unsubscribe를 검증; Rust build/test; `verify-native.sh`로 실제 embedded frontend의 GUI 다운로드 진행/완료/실패 및 선택 경로를 재검증한다. 기존 Tauri IPC GUI acceptance가 rustra 통합 증거를 대신하지 않는다. `event.listen not allowed` 사례처럼 실제 WebView 권한을 포함한 결과를 확인하고, 기존 native 선택·다운로드·핫스왑 및 사용자 앱 상태 보존을 회귀 검사한다.
- OpenUI 로컬 renderer, escaping, 빈 상태/갱신 테스트 및 native GUI 선택 정보 표시는 재수락 절에서 통과했다. parser-invalid 경로는 explicit alert가 구현되어 있지만 실제 생성 응답이 없으므로 native 생성 응답 오류 검증은 미수행. Cloud 생성 요구는 서비스 소유자·인증/키 관리·비용/오류 정책이 승인되기 전까지 blocker이며 로컬 renderer를 AI 기능으로 홍보하지 않는다.
- 롤백 조건: 생성 코드/runtime adapter의 Tauri 호환 실패, event 누락/중복 또는 lifecycle 누수, 제품 command 회귀, UI/native acceptance 실패, lockfile 충돌, 또는 기존 사용자 상태 변경 시 rustra bridge 변경을 되돌리고 기존 Tauri API 호출을 사용한다. `lib.rs`의 command 구현과 wallpkg 파일 계약은 이관 실패만으로 변경하지 않는다.

## 최신 수락 구현 (native-visual-and-gui attempt 3)

아래 본 절은 OpenUI/rustra 통합 전 수락 기록이다. 뒤에 추가된 `OpenUI + rustra 재수락` 절이 이 부분의 오래된 통합 관련 문장을 대체한다.

`native-hotswap.py`는 격리 HOME 아래 ffmpeg `red`/`blue` 단색 H.264 wallpkg를 생성하고, CGWindowList에서 격리 엔진의 창 ID를 찾은 뒤 `screencapture -l` 결과를 보존한다. A/B 캡처를 ffmpeg로 24×24 RGB로 정규화해 평균 픽셀 차이를 계산하며 B 선택 시 monotonic 시간과 ACK를 함께 남긴다. JSON 결과에 screenshot 경로/전환 ms/프로세스 및 사용자 active.json 전후 상태를 기록한다. 캡처 불가, 차이 부족, 3초 초과 또는 사용자 상태 변경은 nonzero다. 이 harness의 선택 드라이버는 격리 `active.json` 교체이며 Tauri GUI 입력이 아니다.

가시 검사는 A→B→A의 두 전환을 모두 요구한다. 시간은 선택 직전 monotonic부터 첫 확인 캡처/픽셀 분석 완료까지의 보수적인 상한이며 정확한 디스플레이 presentation timestamp가 아니다. ACK만으로 통과하지 않는다. 두 화면 환경에서 격리 엔진 소유의 창을 관측하되 모든 모니터 동시 전환을 주장하지 않는다.

`verify-native.sh`는 HTTP 및 live AppHandle 검사에 이어 실제 제품 frontend를 임베드한 Tauri/Wry 창을 격리 HOME으로 실행한다. `native-acceptance` feature에만 포함된 `gui-harness.js`가 실제 React DOM 카드/새로고침/다운로드 버튼을 클릭하고 제품의 invoke/listen 경로를 그대로 사용한다(mock 없음). 카드에 focus 후 AppleScript가 실제 Enter를 보내며 WebView에서 `isTrusted` keydown 및 선택 결과를 확인한다. GUI 전용 localhost 서버는 다운로드를 지연 전송하고 503 실패도 제공한다. 진행/완료/실패 렌더링, 새 카드, 저장 영상 hash, active.json, staging 정리까지 만족해야 exit 0이다. `gui-acceptance.json`, 단계별 JSON, HTTP/프로세스 로그와 GUI window-ID 스크린샷을 증거 디렉터리에 남긴다. 일반 제품 빌드에는 하네스/report command가 포함되지 않는다.

실제 GUI 검증 중 `event.listen not allowed`를 발견해 `tauri.conf.json`에 main 창의 listen/unlisten 최소 권한을 추가했다. Rust 직접 호출 검사만으로 발견할 수 없던 다운로드 차단이었다. 기존 Tailwind/shadcn 컴포넌트는 변경하지 않았다.

한계: UI 카드 클릭은 실제 WebView 안의 DOM 자동화이지 물리 마우스 클릭은 아니다. 엔진 가시 시간 검사와 GUI IPC 검사는 별도 격리 실행이므로 GUI 클릭→엔진 표시의 단일 end-to-end 시간을 주장하지 않는다. OpenUI/rustra 미적용 및 `gpt-6-astra`는 이 통합 전 기록이며, 아래 재수락 기록이 최신 상태다.

## OpenUI + rustra 재수락 (2026-09-24)

- 필수 직렬 전체 acceptance 명령 종료 코드 **0**: `make`(no-op, Swift 재컴파일 아님), UI **8/8** tests + build, Rust **7/7** tests + `cargo check`, `verify-hotswap.sh`, `verify-native.sh`, `git diff --check` 통과. 추가 `cd ui && bun run check:bridge`도 종료 코드 **0**으로 Rust 원본에서 생성된 코드 drift가 없음을 확인.
- rustra는 `@rustra/tauri@0.9.3`, types `0.12.0`, CLI `0.11.3`, Rust crate `0.11.0`을 사용한다. UI에서 generated `scanLibrary`와 `download-progress` 이벤트가 실제 Tauri adapter/event transport에 연결된다. 제품 select/download command는 기존 native 경로를 유지한다. GUI acceptance에서 rustra scan 및 실제 WebView IPC를 확인했다.
- OpenUI `@openuidev/react-lang@0.3.0` Renderer는 선택 패키지의 로컬 메타데이터/미리보기 현황을 표시한다. 정보는 결정적 로컬 렌더링이고 화면에 “AI 생성 아님”으로 명시한다. GenUI cloud 모델/생성 백엔드/외부 인증은 없으며 해당 생성형 기능은 미완료다. 로컬 패널은 메타데이터를 JSON 문자열로 escaping하고 read-only 허용 컴포넌트만 쓴다.
- 상태 경로: 빈 라이브러리와 OpenUI 로컬 정보 렌더링/업데이트, escaping, 다운로드 진행/완료 및 503 오류를 테스트와 실제 GUI에서 확인. parser-invalid 경로는 오류 UI를 구현했으나 실제 GUI의 잘못된 생성 응답 검증은 범위 밖(생성 응답 경로 자체가 없음).
- 핫스왑 가시 픽셀: A→B **1262.5 ms**, B→A **1500.7 ms**. 선택 기준은 격리 `active.json` 교체→실제 캡처/픽셀 변화이며 UI 클릭→프레임 end-to-end 시간이 아니다.
- native GUI: rustra scan, WebView DOM card select, trusted OS Enter, OpenUI 패널, localhost download progress/completion 및 503 UI 통과. 13,104,509 byte payload 일치, progress 215회, staging/failure cleanup 통과. 설치 앱 PID 68589와 사용자 active.json 부재 상태 전후 보존.
- 증거 디렉터리: hotswap `/var/folders/z8/h16kj6d16t53dj0lfvlkxf0h0000gn/T/wallbloom-hotswap-evidence-10qlygun`; native `/var/folders/z8/h16kj6d16t53dj0lfvlkxf0h0000gn/T/wallbloom-native-evidence-ywnPJ0`; 재현/버전 상세 `ui/INTEGRATIONS.md`.
- 환경 모델 식별자는 `PI_PROVIDER=openai-codex`, `PI_MODEL=gpt-6-luna` (worker 환경 출처, 라우팅 attestation 아님). 앱은 API key/Codex OAuth를 읽거나 서비스 자격증명으로 사용하지 않는다. Swift clean rebuild, CPU/RAM 회귀, 물리 마우스, UI 선택부터 프레임까지 단일 지연, wallpkg 전체 외부 호환성은 미검증.

## 웹 CPU 절감 대안 조사 (web-cpu-alternatives-2, 2026-09-25)

> 목표: web 배경화면의 WebKit 트리 CPU(직렬 재측정 4회 평균 13.362/13.531/14.262/14.771%, 목표 <10% 전부 FAIL, `MEASUREMENTS.md`)를 **"보기만 하는 용도"** 전제로 낮추는 대안을 조사하고 우선순위를 확정한다. 이 절은 조사·문서 기록이며 코드 변경은 없다. 1차 실행(loop-34c69f29…)은 조사만 하고 이 문서에 기록하지 않아 alternatives-documented 검사가 실패했다. 이번에는 기록까지 포함한다.

### 근거 원천 (1차 자료)

- 설치된 SDK 공개 헤더: `$(xcrun --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Headers/` 아래 `WKPreferences.h`, `WKWebView.h`, `WKSnapshotConfiguration.h`, `WKWebpagePreferences.h` (macOS 26 SDK, 본문에 직접 인용).
- 현재 엔진 소스: `engine/main.swift` (`installWebWindows`, `applyPlaybackState`, `setInteractive`, WebPackage CSP/콘텐츠 룰).
- 기존 실측: `MEASUREMENTS.md`의 WebKit 트리 CPU/RAM 4회 기록, `ui/scripts/verify-web-perf.sh` 샘플링 방식.
- **자체 프로브 실측(이번 신규)**: `/tmp/wallbloom-cpu-research/`의 독립 Swift 프로브(저장소 밖, 코드 변경 없음). fixture heavy 셰이더와 동일한 WebGL 로직을 1024×768pt 가시 창에서 구동, `verify-web-perf.sh`와 같은 ps 프로세스 트리 합산을 1초 간격 수집. **절대값은 전체 화면 wallpaper 측정과 비교 불가**이며, 아래에서는 변형 간 상대비와 정성 증거(프레임 카운터)만 근거로 사용한다. 임시 디렉터리는 소거될 수 있으므로 수치를 본문에 전부 기록한다.

### 프로브 실측 요약 (draw 빈도가 CPU를 지배한다)

| 변형 (페이지 기법) | 실측 draw 빈도 | CPU 평균 (%) | CPU 최대 (%) | 비고 |
|---|---:|---:|---:|---|
| unlimited (매 rAF draw) | 약 63fps | 2.662 | 3.2 | 표본 13 |
| cap30gate (현재 fixture의 rAF gate) | 약 21~23fps | 2.108 | 2.5 | gate 방식은 30fps에도 못 미침, 절감 약 21% |
| timer10 (setTimeout+단일 rAF 하이브리드) | 약 10.3fps | 0.592 | 0.7 | unlimited 대비 약 22% |
| **timer1 (1fps 저빈도 갱신)** | 약 1.0fps | **0.008** | 0.1 | 사실상 무료, unlimited 대비 약 0.3% |
| static (첫 프레임 후 정지) | 1회 | 0.000 | 0.0 | 스냅샷 폴백의 페이지 측 등가 |
| snapshot (엔진이 캡처 후 뷰 계층에서 분리) | 분리 후 0 | 2.367(부착) → **0.000**(분리) | 0.0 | 8.4초 분리 구간 표본 6 |

snapshot 변형의 정성 증거: `inactiveSchedulingPolicy = .suspend` 상태에서 `WKWebView`를 뷰 계층에서 분리하자 분리 8.4초 동안 프레임 카운터가 동결됐다(분리 직전 138 → 재부착 2.5초 후 197, 증분 59프레임 ≈ 재부착 구간 2.5초 × 약 23fps분. JS가 계속 돌았다면 약 190프레임이 더 늘었어야 함). 재부착 후 rAF가 정상 재개됐다. RSS는 스냅샷 NSImageView 비트맵만큼 74.7→110.5 MiB(+35.8) 증가했다. 이는 "스냅샷 폴백으로 JS/레이아웃이 완전히 멈추고 상호작용 시 원복 가능"함을 본 머신에서 직접 증명한 결과다.

### 방향 1: WKWebView/WebKit 공개 설정 기반

| 대안 | 예상 절감 근거 | 난이도 | 위험 | 검증 |
|---|---|---|---|---|
| 이미 적용된 설정 유지: `setAllMediaPlaybackSuspended`(`WKWebView.h`, macOS 12+), `mediaTypesRequiringUserActionForPlayback = .all`, `javaScriptCanOpenWindowsAutomatically = false`, nonPersistent store — `engine/main.swift` `applyPlaybackState`/`installWebWindows` | 미디어 중심 페이지 절감. 현재 fixture는 미디어가 없어 추가 절감 여지 작음(13%대 유지가 간접 증거) | — | — | 기존 `verify-web.sh` |
| `WKPreferences.inactiveSchedulingPolicy` (macOS 14+, `WKPreferences.h`) | 헤더 원문: "when it is inactive **and detached from the view hierarchy** … A suspended web view will **pause JavaScript execution and page layout**". 단, 현재 엔진은 WKWebView가 항상 창에 부착돼 있어 단독으로는 무효. **스냅샷 폴백(부착 해제)과 결합할 때만 유효** → 방향 3의 핵심 근거 | 낮음(설정 1줄) | detachment 조건을 모르고 쓰면 효과 없음 | 프로브의 프레임 동결 관찰(위 표) |
| `WKWebpagePreferences.allowsContentJavaScript = false` (macOS 11+) | 헤더 원문: JS 비실행. 단 "your application can still execute JavaScript using evaluateJavaScript … WKUserScripts" — 엔진 훅(`window.wallbloom`)은 유지 가능. 정적 HTML/CSS 패키지 폴백용 | 낮음 | JS 기반 패키지를 무력화 → 패키지 선언 또는 폴백 전용으로 제한해야 함 | 정적 fixture CPU 측정 |
| WKWebView 프레임레이트 자체를 캡하는 공개 설정 | **공개 헤더에 존재하지 않음**(헤더 검색 결과 없음). 따라서 프레임 캡은 페이지 주입(방향 2) 또는 스냅샷 폴백(방향 3)으로만 가능 | — | — | — |
| `prefers-reduced-motion` 강제 | 공개 API로 웹뷰별 강제 수단 없음. 시스템 Reduce Motion 설정을 페이지가 자발적으로 존중하는 구조(표준 미디어 쿼리) | 문서 수준 | 강제 아님 | 패키지 제작 가이드 |

### 방향 2: 페이지 측 기법

| 대안 | 예상 절감 근거 | 난이도 | 위험 | 검증 |
|---|---|---|---|---|
| rAF/setInterval 저빈도화(1fps~10fps) — 엔진이 `WKUserScript`(atDocumentStart, mainFrameOnly, 공개 API, 엔진이 이미 `window.wallbloom` 훅 주입에 사용)로 `requestAnimationFrame`/`setInterval`을 래핑해 주입 | 프로브: 10fps 0.592%, **1fps 0.008%**(unlimited 2.662% 대비). wallpaper 수준 외삽 시 13%대 → 1% 미만 추정(선형 비례 가정, **추정 표시**) | 중 | (1) 페이지 타이밍 가정 깨짐 → 애니메이션이 계단식으로 변함(배경화면 용도로는 수용 가능). (2) 상호작용 시 원본 rAF 복원 필요(주입 스크립트에 `window.wallbloom.setFrameRate()` 형태의 해제 훅 포함). (3) 게이트 방식은 60Hz rAF 콜백 자체가 계속 돌므로 절감이 제한적(프로브 cap30gate 2.108%) — **setTimeout 대기 + 단일 rAF 하이브리드여야 실제 저빈도** | `verify-web-perf.sh` 재측정 <10%, fixture에 프레임 카운터 검증 추가 |
| 현재 fixture의 rAF gate 30fps | 프로브에서 실측 21~23fps, 절감 약 21%(2.662→2.108%) — **목표 <10% 달성에 불충분** | — | — | 기존 MEASUREMENTS.md 13%대와 정합 |
| `prefers-reduced-motion` 존중, visibility 기반 정지 | 표준 미디어 쿼리/`document.visibilityState`이나, 데스크톱 레벨 창은 WebKit에 visible로 보여 자동 스로틀을 기대할 수 없음(본 실측 13% 유지가 간접 정합. WebKit 내부 스로틀 정책 세부는 공개 문서 확인 필요 — **추측 표시**) | 페이지 제작자 협력 | 보장 없음 | 가이드 문서 |
| CSS transform/opacity GPU 애니메이션, 정적 이미지·CSS 그라디언트 | JS 루프 제거로 절감이 논리적으로 기대되나 본 프로브 미측정 — **추측 표시** | 페이지 제작자 | 시각 자유도 제한 | 별도 fixture 측정 필요 시 추가 |

### 방향 3: 엔진 측 스냅샷 / 1fps 저빈도 갱신 + 상호작용 원복 (추천 1순위)

설계: (a) 상호작용이 없는 기본 상태에서 일정 시간(예: 10초) 경과 후 `WKWebView.takeSnapshot(with:completionHandler:)`(`WKWebView.h`, macOS 10.13+, 공개 API; `WKSnapshotConfiguration.rect`/`snapshotWidth`로 해상도 조절 가능)로 현재 화면을 캡처 → 창의 contentView를 NSImageView로 교체해 WKWebView를 뷰 계층에서 분리 → `inactiveSchedulingPolicy = .suspend`와 결합해 JS/레이아웃 완전 정지. 애니메이션이 필요한 패키지는 대안 (b) 엔진 주입 1fps 스로틀로 저빈도 갱신. (c) 상호작용 시작 시(`setInteractive(true)`, 기존 경로 존재) 원본 WKWebView를 재부착하고 스로틀을 해제해 원복, 종료 시 다시 폴백. 타임아웃·저전력(`applyPlaybackState`의 lowPower 경로)·화면 전환 시에도 동일 폴백 재적용.

- 예상 절감: 프로브에서 부착 2.367% → 분리 0.000%. draw가 0회가 되므로 남는 것은 WebKit 유휴 오버헤드와 정적 이미지 합성뿐. wallpaper 수준 절대치는 재측정 필요(**추정**), 1fps 경로는 timer1 비율 기준 13%대 → 1% 미만 추정. 목표 <10% 달성 가능성이 가장 높다.
- 난이도: 중. 변경은 `engine/main.swift` 단일 파일이고 상호작용 원복 경로(`setInteractive`), 일시정지 경로(`applyPlaybackState`), 화면 재구성(`didChangeScreenParametersNotification`)이 이미 존재해 상태 전이만 추가하면 된다.
- 위험: (1) 시계/뉴스 티커 등 실시간성 페이지가 멈춰 보임 → 패키지별 opt-out 또는 1fps 경로 선택. (2) 스냅순간 시각 불일치 — 스냅샷 직전 프레임과 이미지가 동일하므로 시각 연속성은 유지되나 재부착 첫 프레임 지연 가능. (3) 화면당 스냅샷 비트맵 RAM(프로브 1024×768pt@2x에서 +35.8 MiB; 풀스크린 Retina 2x는 약 30 MB/화면 추정, `snapshotWidth`로 저감 가능). (4) 분리 조건은 "view hierarchy로부터 detached"여야 하므로 window를 숨기는 방식이 아니라 contentView 교체가 필요(헤더 조건).
- 검증: `verify-web-perf.sh` 재측정(격리 HOME, CPU <10% 목표), `verify-web.sh` 보안/입력/왕복 회귀, 스냅샷 전후 창 캡처 픽셀 일치, 재부착 후 rAF 재개 카운터(프로브 방식을 harness에 이식), 원복 상호작용에서 OS-posted 입력 왕복. 미검증은 PASS로 취급하지 않는다.

### 방향 4: 타 앱 사례

Wallpaper Engine 등의 웹 배경화면은 게임 실행 시 정지, 배경화면별 프레임 제한, 저전력 연동 같은 저전력 처리를 제공한다고 알려져 있으나, 이번 오프라인 환경에서 원문 문서를 확인하지 못했다 — **추측 표시**, 설계 참고로만 사용. Wallbloom 엔진에는 이미 `isLowPowerModeEnabled` 관찰과 `willSleepNotification` 연동(`engine/main.swift` `setupObservers`)이 있어 동일 방향 확장 지점으로 유효하다.

### 추천 우선순위 (보기 전용 전제)

1. **엔진 측 스냅샷 폴백 + 상호작용 시 원복** (필요 시 1fps 저빈도 병행). 이유: 유일하게 공개 API가 JS 실행·레이아웃 정지를 명시하는 경로이고(`WKPreferences.h` inactiveSchedulingPolicy + takeSnapshot), 본 머신 프로브에서 CPU 2.367%→0.000%, 분리 중 프레임 동결, 재부착 재개까지 직접 검증됐다. 현재 13%대 vs 목표 <10% 괴리를 구조적으로 해소한다.
2. 엔진 주입 1fps rAF/setInterval 스로틀 — 스냅샷 정지가 부자연한 실시간성 패키지용(프로브 0.008% 근거).
3. `allowsContentJavaScript = false` 정적 폴백 — 정적/선언형 패키지 한정.
4. 패키지 제작 가이드(prefers-reduced-motion, CSS 위주 애니메이션, 저주파 자체 스로틀 권장) — 문서 수준.
보류: 프라이빗 API 기반 스로틀(정책 위반), visibility 의존 자동 정지(데스크톱 레벨에서 무효), gate식 30fps 유지(절감 불충분).

### 후속 구현 시 변경될 파일 경계 (이번 실행은 코드 변경 없음)

- `engine/main.swift` — 유일한 제품 코드 변경점: `installWebWindows`(스냅샷/스로틀 상태 추가), `applyPlaybackState`(저전력·일시정지와 폴백 통합), `setInteractive`(원복 진입/종료).
- `docs/WALLPKG_SPEC.md` §3 — web pause 계약에 스냅샷 폴백/저빈도 명시(문서).
- `ui/scripts/web-fixtures/`(스냅샷·1fps 모드 fixture)와 `ui/scripts/verify-web-perf.sh`(재측정) — 테스트 전용.
- `MEASUREMENTS.md` — 재측정 기록.

한계: 프로브 창은 1024×768pt로 전체 화면이 아니므로 절대 CPU를 wallpaper 수준으로 읽지 않는다(상대비·정성 증거만 사용). wallpaper 수준 절대 절감은 후속 구현 후 `verify-web-perf.sh` 재측정으로 확정해야 한다. 프로브 원시 데이터: `/tmp/wallbloom-cpu-research/*.analysis.json`, `*.jsonl`, `*.markers`. 모델 식별자: `PI_MODEL=glm-5.3-flash`, `PI_PROVIDER=zai`(환경 보고값, 라우팅 증명 아님).

## 저전력 웹 렌더러 조사 (lowpower-browser-research)

조사 범위는 **보기 전용 배경화면에서 1~30fps 동작을 유지**하는 경우다. 현재 Wallbloom은 화면마다 WKWebView를 만들며 WebKit 트리 평균 CPU가 13.362%, 14.262%, 14.771%(디스플레이 설정별; `MEASUREMENTS.md`)로 목표 <10%를 넘는다. 기존 조사/실측에 따르면 WKWebView를 snapshot으로 대체하고 view hierarchy에서 분리하면 `inactiveSchedulingPolicy = .suspend`가 JS/layout을 멈추며, 분리 구간 CPU 0.000%였다. 이 수치와 다른 엔진의 이론상 기능은 직접 비교 가능한 벤치마크가 아니다.

### 대안별 1차 근거 및 평가

| 선택 | macOS arm64 / 라이선스 | 임베딩, WebGL, fps | 크기 및 판단 |
|---|---|---|---|
| **CEF windowless/off-screen** | CEF 공식 플랫폼 빌드는 macOS용이지만, 확인한 CEF API 문서만으로 최신 배포물에 arm64 아키텍처가 모두 포함되는지 확정할 수 없다. 채택 시 다운로드한 고정 버전의 `Chromium Embedded Framework.framework`와 helper binary의 `lipo -archs`를 검사해야 한다. CEF 자체는 BSD-style, Chromium 구성요소의 개별 고지도 함께 준수해야 한다. | `CefBrowserSettings.windowless_frame_rate`는 windowless `OnPaint` 최대 fps이며 최소 1, 기본 30; 런타임 `CefBrowserHost::SetWindowlessFrameRate`로 조절 가능. 목표 1~30fps를 API가 직접 지원한다. `windowless_rendering_enabled`와 `CefRenderHandler::OnPaint`로 렌더링 버퍼를 받아 AppKit surface에 합성해야 한다. 헤더는 WebGL 설정 가능을 명시하나 하드웨어 지원에 의존. Chromium급 HTML 호환성이 장점이며 WKWebView 코드/보안 경계/입력/화면 lifecycle은 재구현 필요(높은 난이도). | Chromium 프레임워크, helper, locale/resources를 함께 배포하는 **대형 의존성(수백 MB급 설치물 가능)**. 버전/압축/필수 resource 구성에 따라 크게 달라지므로 공식 문서에서 단일 크기는 확인 불가; 실제 arm64 app bundle 실측이 필요. FPS cap이 WebView의 JS timer/DOM 계산 모두를 같은 비율로 제한한다고 보장하지는 않는다. |
| **Ultralight** | 공식 배포/가격 정보는 macOS 플랫폼을 지원한다고 표시하나, 읽은 자료만으로 macOS arm64 아티팩트 제공 여부는 확인 불가(릴리스별 확인 필요). 라이선스는 현재 공식 가격 페이지에서 Indie 조건(연매출 및 투자 각 $100K 미만) 상업 사용 가능 및 그 이상 Pro 라이선스 요구를 표시한다. 제품 출시 전 해당 시점의 계약을 확인. 과거 AGPL로 배포됐다는 주장은 현재 공식 페이지로 검증하지 못했으므로 여기서 AGPL이라고 단정하지 않는다. | C/C++ API로 뷰 생성/표시 및 렌더 target 연동이 필요해 중~높은 native 통합 난이도. API 문서에서 프레임 cap 1~30 또는 WebGL 지원의 구체 보장을 확인하지 못함: 둘 다 검증 필요/불확실. HTML/CSS는 Chromium/WebKit 완전 대체로 간주할 수 없으며 호환성 평가 필요. | 공식 자료에서 arm64 runtime 크기의 확정 수치를 확인하지 못함. 패키지/실제 산출물 측정 필요. 라이선스 비용/조건과 미확정 WebGL이 주요 위험. |
| **Sciter** | 공식 SDK 저장소에 `build.macosx`와 `demos.osx` 존재는 macOS 지원을 입증하지만, arm64 slice 여부는 해당 배포 바이너리의 `file`/`lipo` 검사 전 미확정. Sciter SDK는 상용 임베딩 라이선스를 안내하며 재배포/제품 조건을 확인해야 한다. | 공식 SDK의 native API로 host window에 임베딩. 별도 CSS/스크립트 엔진으로 Chromium/WebKit과 웹 표준 호환성이 다름. WebGL 지원과 1~30fps native cap은 이번에 확인한 1차 자료에서 근거를 찾지 못함(불확실). 세부 custom-draw/timer 제어는 가능하더라도 엔진 전체 절전 cap과 동치라고 보지 않는다. 난이도 높음. | SDK 바이너리 용량은 공식 고정치 미확인. CEF보다 작을 가능성은 추정일 뿐, 후보 버전의 arm64 runtime과 실제 bundle로 확인해야 한다. |
| **Servo / 실험 엔진** | Servo 공식 README는 64-bit macOS 개발을 명시하지만 macOS **arm64 지원/안정된 임베딩 SDK**를 보증하지 않는다. Servo는 prototype browser engine이며 MPL-2.0 라이선스(저장소 LICENSE)다. | 실험적 Rust engine API/embedder이며 안정된 macOS wallpaper host API, offscreen fps cap, WebGL의 제품용 보장을 확인할 수 없음. 통합/유지보수 위험 매우 높음. | 일반 사용자가 붙일 수 있는 안정판 arm64 embed binary 및 크기 근거 없음. 연구/프로토타입 외 비추천. |
| **WKWebView 유지 + snapshot / 1fps** | 현재 제품 API와 macOS 지원 유지, 추가 제3자 license/dependency 없음. | 기존 `takeSnapshot`, 이미지 표시, view 분리, `.suspend` 사용. 1fps 지속 움직임은 페이지 측 또는 엔진 정책이 필요하며 WKWebView 자체의 공개 fps cap은 없음. 기존 WebGL 동작을 유지할 수 있으나 스냅샷 상태에서는 정지 화면. 구현 난이도 중간, 기존 화면/보안/입력 경로 재사용. | 추가 엔진 바이너리 없음. Retina 다중 화면 비트맵은 메모리 추가(기존 조사 프로브에서 1024×768pt@2x snapshot 때 +35.8 MiB; 전체 화면 환산은 해상도별 실측 필요). |

### 공식 선례: CEF 및 배경화면 앱

- CEF upstream `include/internal/cef_types.h`의 `cef_browser_settings_t.windowless_frame_rate` 주석은 WLS `OnPaint` 최대 프레임률, 최소 1/default 30 및 동적 `SetWindowlessFrameRate`를 명시한다. 같은 헤더는 `webgl` 설정이 가능하나 hardware support에 좌우된다고 명시한다. `include/cef_browser.h`는 창 없는 브라우저의 paint handler 및 off-screen rendering 인터페이스를 정의한다.
- Wallpaper Engine 공식 디자이너 문서에는 **FPS Limiter** 항목이 있고, 웹 배경화면 문서가 web wallpaper 제작을 다룬다. 문서만으로 그 앱 내부가 CEF인지 직접 증명하지 못하므로 **Wallpaper Engine이 CEF를 사용한다는 주장은 확인 불가**로 남긴다. 이 조사는 “CEF 기반”이라는 유통 설명을 1차 근거 없이 사실로 채택하지 않는다. FPS limiter 선례 자체는 공식 문서로 확인된다.
- Lively 공식 GitHub 프로젝트 `rocksdanister/lively-cef`는 자기 설명이 “Lively Wallpaper Browser Plugin”이며 CEF 플러그인 저장소로 공개돼 있다. Lively 메인 저장소도 이를 연결한다. 이는 **CEF 기반 web 경로의 강한 1차 소스 근거**다. 다만 Lively의 web wallpaper에 사용자가 선택 가능한 FPS 제한이 있다는 점은 이번에 확인한 공식 소스에서 검증되지 않았다. 추정하지 않는다.

### 3개 경로 비교 및 추천

절감량은 엔진간 같은 fixture/기기 비교가 없어 정성/미측정으로 구분한다. 현 단계에서 “CEF가 더 낮은 CPU”라는 실측 증거는 없다.

| 순위/경로 | CPU 절감 기대 | 웹 호환성 | 구현 난이도 / 유지보수 | 의존성 |
|---|---|---|---|---|
| **1 — WKWebView + snapshot 기본, 필요 콘텐츠만 1fps로 계속 갱신** | snapshot 정지 구간은 기존 프로브에서 CPU 0.000% 관측(해당 프로브 조건). 1fps timer 변형은 별도 프로브 0.008%였으나 전체 화면 제품 수치 아님. 실제 배경화면 재측정 필수. | 정지 snapshot은 모든 콘텐츠를 정지 이미지로 보여주며, 1fps는 복잡한 애니메이션/게임형 web 콘텐츠를 크게 저하시킴. 재부착 시 기존 WebKit/WebGL 호환성 유지. | 중간. 기존 엔진과 interaction 경로를 재사용하며 새 엔진 lifecycle/배포물 없음. snapshot 메모리와 상태전이를 검증. | 없음(기존 WebKit). |
| **2 — WKWebView 실시간 재생 유지 + CEF WLS 대체/선택형 backend** | FPS cap이 CPU를 줄일 수 있으나 감소율은 **미측정**; Chromium 프로세스와 compositing 비용으로 증가할 수도 있음. 실제 A/B 벤치마크 없이는 절감 단정 불가. | Chromium 계열 표준 지원이 강점. WKWebView와 차이 및 CEF WebGL/GPU 경로 검증 필요. | 매우 높음: CEF 초기화/helper processes, AppKit offscreen surface 합성, IPC/lifecycle, 보안 정책, arm64 서명·업데이트·크래시 분석과 큰 버전 업데이트 부담. | 매우 큼(Chromium runtime). arm64 bundle 사이즈 측정 전 미확정. |
| **3 — 혼합: WK snapshot이 기본, CEF는 명시적 호환 모드** | 보통 콘텐츠는 suspend 이득을 얻고 호환성 민감 콘텐츠는 CEF에서 cap 적용 가능하나, CEF CPU 비용은 미측정. | WebKit 우선 + Chromium fallback은 선택 폭이 넓으나 backend 차이/패키지별 호환성 분기가 생김. | 가장 높음(두 엔진 테스트 매트릭스, 설정/지원/장애처리). CEF 수요와 실제 이득이 입증되기 전 구현하지 않음. | CEF 전체 bundle 추가. |

**권고:** 1순위는 WKWebView 유지 + 기본 snapshot/suspend 및 사용자가 움직임을 택한 콘텐츠에 한해 저빈도(초기 1fps 후보, 상한 30fps 정책은 별도 설계) 재생을 검증한다. 기존 실측에서 suspend CPU 0.000%이고 구현/유지비/추가 바이너리가 가장 낮다. 움직임을 유지하는 1fps가 제품 체감에 충분한지 사용자 확인이 필요하다. 2순위 CEF는 snapshot 후에도 실제 콘텐츠의 최소 요구 fps를 만족하지 못하고 WKWebView 대비 CPU <10%를 같은 fixture에서 증명한 경우에만 제한된 기술 프로토타입으로 진행한다. CEF fps API는 목표 범위에 정확히 맞지만 프레임 상한은 CPU 절감률 보장이 아니다. 3순위 혼합은 CEF의 호환성 이점/수요와 bundle 비용이 계측·승인된 뒤에만 고려한다. Ultralight/Sciter/Servo는 arm64·WebGL·fps cap 또는 계약/성숙도 공백 때문에 현 제품 후보에서 제외한다.

### 후속 결정 및 검증 필요

1. 제품 기본값을 정지 snapshot, 1fps, 사용자 선택 fps 중 무엇으로 할지와 상호작용 시 원복/opt-out을 승인한다. 움직임 1fps가 “보기 전용”에 수용 가능한지 UX 결정이 필요하다.
2. 동일 M1 Max, 동일 webpkg, 동일 해상도/창 수/측정 구간에서 WK live, snapshot detached, WK 1fps를 재측정한다. CEF 실험을 승인한다면 동일 fixture CEF WLS 1/10/30fps도 별도 빌드로 측정하고 CPU 평균/RSS/전력 및 시각 품질을 기록한다.
3. CEF 검토 착수 전 배포 버전과 arm64 slice, helper/resource 포함 최종 app 크기, BSD 및 Chromium notices, signing/notarization, 업데이트 전략을 고정한다. Ultralight/Sciter는 공급사의 arm64 runtime/WebGL/fps 문서와 상용 재배포 계약을 서면 확인한다.
4. Wallpaper Engine 내부 엔진과 Lively fps UI 제한 여부는 현재 확보한 1차 소스에서 확인되지 않은 채로 남는다. 추후 repo/tag별 코드·제품 공식 문서가 발견되기 전까지 확정 표현 금지.

### 출처 (1차 자료)

- CEF API header `cef_types.h`: https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types.h (windowless_frame_rate, webgl, macOS helper 경로).
- CEF browser API: https://github.com/chromiumembedded/cef/blob/master/include/cef_browser.h ; CEF license: https://github.com/chromiumembedded/cef/blob/master/LICENSE.txt .
- Wallpaper Engine 공식 웹 FPS limiter: https://docs.wallpaperengine.io/en/web/performance/fps.html ; 웹 콘텐츠 공식 문서: https://docs.wallpaperengine.io/en/web/overview.html .
- Lively 공식 CEF plugin source: https://github.com/rocksdanister/lively-cef ; 프로젝트: https://github.com/rocksdanister/lively .
- Ultralight 공식 가격/라이선스/플랫폼 정보: https://ultralig.ht/pricing/ . SDK 상세 문서는 이번 조사 환경에서 접근 제한으로 확인하지 못함.
- Sciter SDK 공식 저장소: https://github.com/c-smile/sciter-sdk (macOS build/demo 경로 및 SDK 라이선스 안내).
- Servo 공식 upstream README/license: https://github.com/servo/servo ; 릴리스: https://github.com/servo/servo/releases .
- 제품 실측/현재 구현: `MEASUREMENTS.md`, `engine/main.swift`, `docs/WALLPKG_SPEC.md` §2 Web pause.

모델 식별자: 환경 보고값 `PI_PROVIDER=openai-codex`, `PI_MODEL=gpt-6-luna` (`openai-codex/gpt-6-luna`). 이는 worker 실행 환경 식별자이며 독립 라우팅 증명은 아니다. 비OpenAI 라우팅이 수행되지 않았다는 별도 attestation은 제공되지 않음.
