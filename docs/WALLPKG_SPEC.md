# wallpkg / active.json 스펙 v0.2

> 상태: **M2 구현 계약**
>
> 엔진과 UI는 `active.json` 외의 런타임 IPC를 사용하지 않는다. 이 문서는 M2에서
> UI가 만들고 엔진이 소비하는 파일 형식과 교체 절차의 단일 기준이다.

## 1. 저장 구조와 wallpkg 정체성

macOS의 루트 디렉터리는 `~/Library/Application Support/Wallbloom/`이다.
`~`는 현재 사용자의 `$HOME`이며, 구현에서는 플랫폼 API로 Application Support
경로를 구한다.

```text
~/Library/Application Support/Wallbloom/
├── active.json
└── library/
    └── sunset-waves/
        ├── wall.json
        ├── preview.png
        └── waves.mp4
```

하나의 wallpkg는 `library/` 바로 아래의 폴더 하나다. `.wallpkg` zip을 가져오거나
URL에서 내려받은 경우에는 검증과 압축 해제를 staging 디렉터리에서 끝낸 뒤 이
형태로 저장한다. 스캐너는 다운로드 중인 staging/tmp 항목과 `library/`의 파일을
무시하고, 바로 아래 디렉터리만 후보로 읽는다.

wallpkg의 정체성은 폴더의 basename이다. `wall.json`의 `id`는 폴더명과 반드시
같아야 한다. 불일치는 단순 경고가 아니라 **유효하지 않은 패키지**이며, UI
그리드에서 제외한다.

## 2. wall.json 계약

### v0.2 예시

```json
{
  "spec": 0.2,
  "id": "sunset-waves",
  "title": "Sunset Waves",
  "type": "video",
  "entry": "waves.mp4",
  "preview": "preview.png",
  "loop": true,
  "volume": 0.0,
  "gravity": "cover",
  "author": "Wallbloom",
  "source": "https://example.com/waves.mp4"
}
```

### 필드

| 필드 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---:|---|---|
| `spec` | number | ✅ | — | 이 문서의 쓰기 버전인 `0.2` |
| `id` | string | ✅ | — | `[a-z0-9-]+`, 패키지 폴더명과 동일 |
| `title` | string | ✅ | — | 비어 있지 않은 UI 표시 이름 |
| `type` | string | ✅ | — | `"video"`(M2), `"web"`(M3 WKWebView), `"scene"`(M5 외부 런타임; 아래 §2.3) |
| `entry` | string | ✅ | — | 패키지 폴더 기준 미디어 상대 경로 |
| `preview` | string | — | `"preview.png"` | 패키지 폴더 기준 썸네일 상대 경로. 16:9 권장 |
| `loop` | bool | — | `true` | 영상 반복 여부 |
| `volume` | number | — | `0.0` | `0.0` 이상 `1.0` 이하 |
| `gravity` | string | — | `"cover"` | `"cover"` 또는 `"contain"` |
| `author` | string | — | — | 저자 표시 |
| `source` | string | — | — | 원본 URL 또는 출처 |

M2 엔진은 `type: "video"`만 적용한다. video의 `entry`는 H.264 또는 HEVC
`hvc1` 태그의 mp4여야 한다. `hev1`은 지원하지 않는다.

### Web 패키지 (M3 macOS)

`type: "web"`은 `entry`가 패키지 루트 기준 HTML 문서인 wallpkg다. HTML은 JS/CSS,
이미지, 폰트, 셰이더 등 패키지 내부 상대 자산을 사용할 수 있다. URL은 상대 경로만
지원하며 외부 URL을 entry로 지정할 수 없다. 예시:

```json
{
  "spec": 0.2,
  "id": "orbit-webgl",
  "title": "Orbit WebGL",
  "type": "web",
  "entry": "index.html",
  "preview": "preview.png",
  "author": "Wallbloom"
}
```

`entry`와 `preview`에는 기존의 상대경로·정규화·심볼릭 링크 이탈 검증을 적용한다.
WebView는 `loadFileURL`에 패키지 디렉터리만 `allowingReadAccessTo`로 전달하고,
최종 canonical URL도 같은 패키지 내부 파일이어야 한다. 자산 요청은 읽기 전용이며
파일을 쓰거나 패키지 밖 경로를 읽을 수 없다. 디렉터리/특수 파일, 깨진 UTF-8/HTML,
존재하지 않는 entry 및 패키지 루트 이탈을 거부한다. 압축 임포트 시에도 추출 경로
이탈(symlink 및 `..`)을 차단하고 압축 해제 후 전체 파일을 검증한다. 링크/redirect의
외부 탐색은 차단하며 앱 내 배경 WebView에서 새 창/다운로드를 허용하지 않는다.

기본 네트워크 정책은 **차단**이다: 외부 HTTP(S), WebSocket, 원격 script/font/image,
폼 제출 및 새 창 탐색을 허용하지 않는다. CSP를 적용해 기본 소스를 패키지 로컬로
제한하고 `connect-src`, `form-action`, `frame-src`는 차단한다. 외부 콘텐츠를 허용하는
user grant나 임의 예외는 이 계약에 없다. 로컬 WebGL은 허용하되 임의 native bridge,
파일 chooser, 자동화 권한은 제공하지 않는다. 이 경계는 OS sandbox 그 자체가 아니므로
WKWebView 구현의 navigation/resource delegate와 실제 네트워크 차단 검증이 수락 조건이다.

상호작용은 기본 off이며 배경 창은 `ignoresMouseEvents=true`로 클릭을 통과시킨다.
제품 UI에서 사용자가 명시적으로 시작한 경우에만 화면별 WebView를 입력 대상으로
전환한다(`ignoresMouseEvents=false`). 모드 종료는 메뉴바 명령 및 앱 전역 Escape
단축 조작으로 항상 가능해야 하며 즉시 모든 창을 클릭 통과로 돌리고 포커스를
반환한다. 패키지 JS가 상호작용 모드를 스스로 활성화하거나 종료를 가로챌 수 없다.

#### Web pause 및 저전력 계약

WKWebView 공개 API는 AVPlayer처럼 임의의 페이지 JavaScript 실행/타이머를 강제로
suspend하지 않는다. 따라서 web pause는 **엔진 미디어 정지 + 페이지의 협력적 pause
훅 호출**로 정의하며, 모든 페이지의 실행 정지를 보장한다고 주장하지 않는다.

엔진은 각 WebView 문서에 다음 API를 제공한다. 페이지는 이 객체를 교체하지 말고,
필요한 함수를 등록한다.

```js
window.wallbloom = window.wallbloom || {};
window.wallbloom.pause = () => { /* 타이머·애니메이션 등 페이지 작업 정지 */ };
window.wallbloom.resume = () => { /* 페이지 작업 재개 */ };
```

정지 요청 시 엔진은 `setAllMediaPlaybackSuspended(true)`로 WebKit 미디어를
정지하고, 현재 활성 페이지의 `window.wallbloom.pause()`를 존재 여부 확인 후
호출한다. 재개 시에는 페이지 `resume()`을 호출하고, 미디어 재개는 전역 pause,
사용자 pause, 저전력 상태가 모두 해제된 경우에만 허용한다. 훅 누락 또는 훅 예외는
엔진 미디어 정지를 취소하지 않으며, 페이지의 임의 스크립트/타이머는 계속 실행될 수
있다. 이는 명시적인 기능 제한이지 pause 성공이나 완전 suspend로 간주하지 않는다.
엔진은 그 제한을 사용자/진단 상태에 노출해야 하며 임의 JS가 강제 정지됐다고
표시해서는 안 된다. CSS 숨김은 pause 구현으로 인정하지 않는다.

wallpkg 작성자는 `pause`/`resume`를 멱등하게 구현하고, 직접 관리하는 `setInterval`,
`requestAnimationFrame`, 애니메이션 루프 및 페이지 오디오 상태를 정지/복원해야 한다.
초기 로드 전 또는 문서 교체 시 호출될 수 있으므로 등록 전 호출을 안전하게 처리하고,
재개 시 중복 루프를 만들지 않아야 한다. WebView 내 `<audio>`/`<video>` 및 기타
WebKit 미디어는 엔진의 공개 미디어 API로 정지한다. video 타입은 기존 AVPlayer
pause 계약을 그대로 유지하며 이 협력적 JS 제한의 적용 대상이 아니다.

검증은 두 종류를 구분한다. (1) 훅 구현 fixture에서 pause/resume 호출 횟수와 순서를
관측하고, fixture가 관리하는 타이머가 pause 동안 진행하지 않고 resume 뒤 다시
진행하는지 확인한다. (2) 훅 미구현 fixture에서는 미디어 정지 API 완료를 확인하고,
임의 JS 타이머가 계속 진행할 수 있음을 관측/기록한다. 이 경우 타이머 0회를 요구하거나
실패로 판정하지 않고, 완전 JS pause 미보장을 PASS 조건으로 명시한다. media pause의
검증 가능한 조건은 정지 API completion callback 완료와 재생 미디어의 정지 상태이며,
API 완료만으로 임의 JS 정지를 추론하지 않는다.

macOS 저전력 모드는 위와 같은 web pause 요청을 수행한다: WebKit 미디어 정지 및
등록된 페이지 훅 호출. 훅이 없는 페이지의 임의 JS 실행은 계속될 수 있으므로
저전력 모드가 web 콘텐츠 전체의 CPU/전력 사용을 제한한다고 보장하지 않는다. video는
기존대로 AVPlayer를 pause한다. 화면별 WKWebView는 현재 NSScreen마다 하나씩이며
연결/해제, 해상도 변경 때 재구성한다. 모든 화면 및 Spaces 동작은 실제 다중
디스플레이 테스트로 확인해야 한다.

3초 판정은 M2와 M3에서 각각 독립한다. M2는 제품 UI의 실제 선택 입력 직전 monotonic
`t0`부터 선택한 video 패키지의 고유 픽셀이 엔진 배경에서 관측되는 `t_visible`까지
`t_visible - t0 <= 3.000s`를 요구한다. UI 선택 완료/active.json 쓰기/엔진 ACK만으로는
충족하지 않으며, 같은 격리 HOME의 UI와 엔진, 외부 제작 video fixture, 실제 마우스
입력 증거를 한 실행으로 남긴다. M3는 별도로 로컬 Web 패키지 첫 가시 프레임을 측정하고
HTML/CSS/JS 및 WebGL 데모, 입력 복원, pause/보안/다중화 검증을 요구한다. 한 gate의
성공으로 다른 gate를 대체하지 않는다.

```bash
ffmpeg -i input.mp4 -c:v hevc_videotoolbox -b:v 12M -tag:v hvc1 -an output.mp4
```

### Scene 패키지 (M5 계약, macOS 우선)

`type: "scene"`은 WebGL/WKWebView 콘텐츠가 아니라 패키지가 제공하는 별도 실행 파일을 엔진이 자식 프로세스로 기동하는 계약이다. 실행 파일은 패키지 안에 포함하고, 엔진은 이를 데스크톱 레벨 렌더링을 위한 자식 프로세스로 실행한다. 자식 창의 데스크톱 부착, 화면별 배치, 종료·재기동은 플랫폼 엔진 책임이며 임의의 창을 허용하는 보안 샌드박스가 아니다. M5 구현 우선 플랫폼은 macOS다. 이것은 Unity/Unreal 엔진 런타임을 Wallbloom에 내장하는 방식이 아니다.

```json
{
  "spec": 0.2,
  "id": "particle-garden",
  "title": "Particle Garden",
  "type": "scene",
  "entry": "runtime/ParticleGarden.app/Contents/MacOS/ParticleGarden",
  "preview": "preview.png",
  "scene": { "interactive": false }
}
```

`entry`는 패키지 루트 기준 상대 경로이며 실행 가능한 일반 파일이어야 한다. M5 런타임 실행 계약은 macOS 실행 파일을 대상으로 한다. `scene.interactive`는 필수 boolean이며 기본 정책은 `false`: scene 창은 입력을 통과한다. true인 경우에만 사용자 opt-in 입력을 허용하며 앱 제공 종료 조작으로 즉시 통과 상태에 복귀한다. 엔진은 인자를 쉘 문자열로 조립하지 않고 검증된 실행 파일 URL을 직접 실행하며, 종료 시 자식 프로세스를 정리한다. 패키지는 신뢰할 수 없는 코드 실행 위험이 있으므로 임포트 전 출처/신뢰 확인을 UI가 분명히 고지해야 한다. Web 타입의 CSP/네트워크 정책은 네이티브 실행 파일에 대한 격리 수단이 아니다.

Unity/Unreal 호환 경로는 각각 macOS standalone player 빌드를 패키지의 `entry`로 포함해 실행하는 방식이다(필요한 데이터 디렉터리·동적 라이브러리·리소스도 패키지 안에 둔다). 엔진 내장 플러그인/런타임 통합은 제공하지 않으며, 빌드별 창 제어·데스크톱 레벨 부착·화면/Spaces·입력·종료·전력/메모리 사용은 호환성 보장 밖에서 별도 검증해야 한다. M5 우선순위는 macOS이며 Windows WorkerW 및 Windows standalone player는 M4/M5 후속 범위다. Steam Workshop 콘텐츠는 가져오거나 재배포하지 않는다.

### 공유 아카이브와 레지스트리 (v0.1)

공유 포맷 v0.1은 검증된 wallpkg 폴더를 단일 `.wallpkg` 아카이브로 내보내고 가져온다. 아카이브는 루트에 `wall.json`을 두고 나머지 상대 경로 자산을 보존한다. 임포트는 staging에 추출하고 절대 경로, `..`, 심볼릭 링크, 특수 파일 및 루트 이탈을 거부한 뒤 전체 패키지를 검증한다. 성공 후에만 `Application Support/Wallbloom/library/<id>/`로 원자적으로 반영하며 기존 ID 덮어쓰기는 거부한다. export는 사용자 선택 패키지만 대상으로 하며 원본을 수정하지 않는다.

GitHub 기반 레지스트리 v0.1은 별도 GitHub 저장소의 `index.json` 인덱스와 각 항목의 HTTPS 다운로드 URL을 사용한다. 항목은 최소 `id`, `title`, `type`, `version`, `download_url`, `sha256`를 갖고, 다운로드 후 해시와 wallpkg 검증을 모두 통과해야 설치한다. 브라우저 UI는 인덱스를 읽어 목록/상세를 표시하고 사용자가 선택한 항목만 내려받는다. 초기 계약에 서명·자동 업데이트·사용자 업로드·검색 서버는 포함하지 않으며 네트워크 콘텐츠도 실행 코드일 수 있음을 고지한다. Steam Workshop은 소스·중계·수입 경로로 사용하지 않는다.

### 파싱과 경로 검증

1. v0.2 작성자는 항상 `spec: 0.2`와 `title`을 쓴다.
2. 읽기 호환을 위해 `spec: 0.1`인 매니페스트에 `title`이 없고 문자열 `name`이
   있으면 이를 `title`로 정규화한다. 다른 버전은 유효하지 않다.
3. 필수 필드 누락, 타입 오류, 빈 `title`, 잘못된 enum/범위, `id`와 폴더명
   불일치는 패키지 전체를 무효로 만든다. 알 수 없는 필드는 무시한다.
4. `entry`와 `preview`는 절대 경로가 아니어야 하고 `.` 또는 `..` 경로 요소를
   포함하지 않아야 한다. 표준화한 실제 경로가 패키지 폴더 밖으로 나가는
   심볼릭 링크도 거부한다.
5. `entry`는 존재하는 일반 파일이어야 한다. `preview`가 없거나 디코딩되지
   않으면 패키지는 유효하지만 UI는 플레이스홀더를 표시한다.
6. UI 스캐너와 엔진은 같은 검증 규칙을 적용한다. 엔진에서 검증이 실패하면
   현재 재생 상태를 유지하고 이유를 stderr에 기록한다.

## 3. active.json 계약

### 위치와 예시

macOS 고정 위치:

```text
~/Library/Application Support/Wallbloom/active.json
```

```json
{
  "spec": 0.2,
  "active": "/Users/loopy/Library/Application Support/Wallbloom/library/sunset-waves",
  "paused": false
}
```

| 필드 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---:|---|---|
| `spec` | number | ✅ | — | `0.2`; 그 외 버전은 적용하지 않음 |
| `active` | string | ✅ | — | wallpkg 폴더의 표준화된 절대 경로 또는 `"none"` |
| `paused` | bool | — | `false` | UI가 정하는 전역 일시정지 상태 |

알 수 없는 필드는 무시한다. `active`가 상대 경로거나 대상 wallpkg가 §2 검증을
통과하지 못하면 active.json 전체를 적용하지 않는다. `"none"`은 재생을 멈추고
배경화면 윈도우를 정리한다.

`active.json`이 없거나 아직 유효한 상태를 한 번도 읽지 못한 경우 엔진은
윈도우 없이 계속 감시한다. 마지막으로 유효하게 적용한 상태가 있다면 이후의
파일 없음, 부분 다운로드, JSON 파싱 실패, 미지원 타입 또는 누락 파일 때문에
그 상태를 지우지 않는다.

### UI의 원자적 쓰기

UI는 다음 순서를 지켜야 한다.

1. Application Support 루트와 `library/`를 필요하면 먼저 생성한다.
2. 현재 유효한 active.json을 읽어 `active`, `paused`의 의미 값이 같으면 쓰지
   않는다.
3. active.json과 **같은 디렉터리**에 충돌하지 않는 임시 파일
   (`active.json.<pid>.<uuid>.tmp`)을 생성한다.
4. 완전한 UTF-8 JSON을 쓰고 파일을 `flush`/`fsync`한 뒤 닫는다.
5. 임시 파일을 `active.json`으로 POSIX `rename`하여 기존 파일을 한 번에
   교체한다. 성공 후 남은 임시 파일을 정리한다.

active.json 자체를 truncate한 뒤 덮어쓰거나, 다른 볼륨의 임시 파일을
복사해서 교체하면 안 된다. M2에서는 UI만 쓰고 엔진은 읽기만 하므로 별도 파일
잠금은 사용하지 않는다.

### 엔진의 변경 감지와 적용

M2 macOS 엔진은 구현이 단순하고 rename에 안전한 **내용 기반 폴링**을 기준으로
한다.

1. 시작 즉시 active.json을 한 번 읽고, 이후 최대 1초 간격으로 파일의 전체
   바이트를 읽는다.
2. `mtime`이나 파일 크기만으로 변경 여부를 판단하지 않는다. 같은 크기의 JSON
   교체를 놓칠 수 있기 때문이다. 직전에 관측한 바이트와 다를 때 파싱하고,
   유효한 정규화 상태(`active`, `paused`)가 마지막 적용 상태와 다를 때만
   적용한다.
3. 읽기 중 `ENOENT`가 발생하면 rename 경계일 수 있으므로 오류 상태를 적용하지
   않고 다음 주기에 다시 읽는다.
4. `active`가 바뀌면 새 wallpkg를 완전히 검증한 뒤에만 모든 화면의 player와
   window를 교체한다. 실패하면 기존 player/window를 유지한다.
5. `paused`만 바뀌면 window를 재구성하지 않고 player에 play/pause만 적용한다.
   실제 재생 여부는 `active.json.paused`, 메뉴바의 사용자 일시정지, macOS
   저전력 모드 중 하나라도 참이면 일시정지다.
6. `active: "none"`은 player/window를 정리하지만 메뉴바와 감시는 유지한다.
7. `argv[1]` 영상 경로가 있으면 M1 호환 모드로 즉시 재생하면서 감시를
   병행한다. 이후 처음 도착한 유효한 active.json이 이를 대체한다. 인자가
   없으면 active.json의 유효 상태를 기다린다.

UI 선택부터 엔진 적용까지의 목표는 3초 이내다. 1초 이하 폴링과 적용 전 검증을
포함한 예산이다. 향후 디렉터리 DispatchSource/FSEvents로 최적화할 수 있지만,
파일 vnode 하나를 계속 감시해서는 안 된다. 원자적 rename은 inode를 교체하기
때문이다.

### 적용 ACK / 실패 관측

엔진은 stdout에 한 줄 JSON 이벤트를 `WALLBLOOM_APPLY ` 접두사로 기록한다.
`event`는 `ack` 또는 `failure`, `id`는 적용 대상 wallpkg 절대 경로(직접 실행
argv 모드에서는 영상 경로), `monotonicSeconds`는 `ProcessInfo.systemUptime` 기준
시각이다. 실패에는 `reason`이 포함된다. `ack`는 단순 파일 읽기/JSON 파싱/패키지
검증/윈도우 생성 시점이 아니다. 화면별 AVQueuePlayer와 실제 `currentItem`의
`status`가 모두 `readyToPlay`인 경우에만 발생한다. AVPlayerLooper의
`templateItem`은 큐에서 재생되지 않으므로 준비 상태 판단에 사용하지 않는다.
메인 스레드의 50ms 준비 상태 폴링은 매번 모든 화면의 현재 항목을 다시 확인하며,
과거 항목의 준비 상태를 누적하지 않는다. player/item/looper 오류는 다음 폴링에서
`failure`로 노출하며, 15초 내 준비되지 않으면 `reason: "timeout"` 실패를 낸다.
화면이 없으면 `reason: "no-screens"`로 실패한다. 성공/실패 시 폴링을 종료하고,
후속 적용/해제 시 이전 세대의 폴링을 취소한다. 일시정지 상태에서도 로드 준비는
확인하되, ACK를 위해 강제로 재생하지 않는다. 화면 재구성에도 pause 정책을 적용한다.

이 ACK는 AVFoundation이 미디어를 로드해 재생 준비 상태가 되었음을 보증할 뿐,
AVPlayerLayer의 첫 디코드 프레임이 실제 데스크톱에 합성/표시되었음을 보증하지
않는다. 따라서 ACK 단독으로 3초 화면 전환을 PASS 처리할 수 없다. 수락 테스트는
별도로 고유 영상 프레임의 실제 화면 표시를 관측해야 한다. 로그의 단조 시각과
선택 입력 시각의 차이 역시 선택→준비 지연이며, 선택→첫 표시 지연과 구분한다.

## 4. M2 컴포넌트별 책임

| 컴포넌트 | 책임 |
|---|---|
| Tauri Rust | 라이브러리 스캔/검증, URL 다운로드와 진행률 이벤트, 원자적 active.json 쓰기 |
| TypeScript UI | Rust가 반환한 유효 패키지의 썸네일 그리드 표시, 선택/다운로드 상태 표시 |
| Swift 엔진 | active.json 감시와 재검증, video 핫스왑, pause/none 적용 |

URL 다운로드는 최종 wallpkg 폴더 밖의 staging 경로에 기록하고, 진행률은
`receivedBytes`와 알 수 있는 경우 `totalBytes`를 함께 전달한다. 다운로드와
wall.json 생성/검증이 끝난 패키지만 `library/<id>/`로 이동하고 재스캔한다.
실패하거나 취소된 다운로드는 라이브러리 그리드와 active.json에 노출하지 않는다.

## 5. 설치/런타임 위치

| 구분 | macOS 경로 |
|---|---|
| wallpkg 라이브러리 | `~/Library/Application Support/Wallbloom/library/` |
| 활성 계약 | `~/Library/Application Support/Wallbloom/active.json` |
| 엔진 바이너리 | `/Applications/Wallbloom.app/Contents/MacOS/Wallbloom` |
| 엔진 앱 번들 | `/Applications/Wallbloom.app` |
| UI 앱 | 별도 Tauri 앱 번들 |

Windows 엔진을 추가하는 M4에서는 `%APPDATA%\Wallbloom\` 아래에 같은 논리
구조를 둔다. 이 절차의 POSIX rename 세부사항은 M4에서 Windows 원자 교체 API로
별도 확정한다.

## 6. v0.1에서 달라진 점

1. 표시 필드를 `name`에서 `title`로 변경했다. v0.1 `name`은 읽기만 지원한다.
2. `preview`와 기본값 `preview.png`를 추가했다.
3. 폴더명을 정체성으로 정하고 `id` 불일치를 무효로 처리한다.
4. active.json에 `spec`을 필수로 추가하고 `active`를 절대 경로 또는 `none`으로
   제한했다. `paused`는 생략 시 false다.
5. 임시 파일의 fsync와 같은 디렉터리 rename을 원자적 쓰기 절차로 정했다.
6. mtime+size가 아닌 전체 내용 기반 1초 이하 폴링을 M2 변경 감지 방식으로
   정했다.
7. 유효성 검사 실패 시 마지막 정상 배경화면을 유지하도록 상태 전이를 정했다.

## 7. 구현 상태와 근거

현재 `engine/main.swift`에는 active.json 폴링, video 패키지 검증, pause 및 준비 ACK가
구현되어 있고 `ui/src-tauri/src/lib.rs`에는 video 전용 scan/download/select 경로가
있다. 따라서 기존 문서의 “엔진에 active.json 구현이 없다”는 설명은 폐기한다.
이 코드는 현재 `type: "web"`을 허용하지 않으며 WKWebView 생성/검증/상호작용도
구현하지 않는다. §2 Web 규칙은 M3 구현자가 따라야 할 수락 계약이지 구현 완료 주장이
아니다. Rust와 Swift validator가 같은 거부 규칙을 유지하고 외부 제작 fixture로
호환성을 확인해야 한다.

M2 잔여 통합의 별도 실측 근거는 루트 `MEASUREMENTS.md` 및 `docs/ROADMAP.md`에
있으며, 두 문서에 인용된 측정값은 별도 실행 증거일 수 있으므로 하나의 실행으로
합쳐 주장하지 않는다. 증거 없는 테스트, SKIP 및 기존 분리형 검사로 미완료 항목을
PASS로 승격할 수 없다.

검토 워커에서 아래 환경값을 직접 조회했다.

```text
PI_PROVIDER=openai-codex
PI_MODEL=gpt-5.6-sol
```

따라서 이 계약 검토를 수행한 실제 워커 라우팅은
`openai-codex/gpt-5.6-sol`이며, 요구된 `openai-codex/*` 범위에 속한다.
