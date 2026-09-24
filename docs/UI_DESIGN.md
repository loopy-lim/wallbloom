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
