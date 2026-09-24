# wallpkg / active.json 스펙 v0.1

> 상태: 초안. M2 구현하며 확정되면 v0.2로 갱신할 것.

## 1. 배경화면 단위: wallpkg

하나의 배경화면 = **폴더 하나** (또는 `.wallpkg` zip).

```
my-wallpaper/
├── wall.json          # 필수. 매니페스트
├── preview.png        # UI 썸네일 (16:9 권장)
└── (타입별 파일들)
```

## 2. wall.json 매니페스트

```json
{
  "spec": 0.1,
  "id": "sunset-waves",
  "name": "Sunset Waves",
  "type": "video",
  "entry": "waves.mp4",
  "loop": true,
  "volume": 0.0,
  "gravity": "cover"
}
```

### 필드

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `spec` | number | ✅ | 스펙 버전. 현재 0.1 |
| `id` | string | ✅ | 고유 ID. `[a-z0-9-]+` |
| `name` | string | ✅ | 표시 이름 |
| `type` | string | ✅ | `"video"` \| `"web"` (M3) \| `"scene"` (M5) |
| `entry` | string | ✅ | video: 미디어 파일. web: 진입 HTML. |
| `loop` | bool | — | 기본 true |
| `volume` | number | — | 0.0~1.0. 기본 0(음소거) |
| `gravity` | string | — | `"cover"` \| `"contain"`. 기본 cover |
| `author` | string | — | 저자 |
| `source` | string | — | 원본 URL/출처 (라이선스 추적용) |

### 타입별 요구사항

**video**: `entry`는 H.264 또는 **HEVC(hvc1)** mp4. `hev1` 태그 금지(렌더링 불가).
권장 인코딩:
```bash
ffmpeg -i input.mp4 -c:v hevc_videotoolbox -b:v 12M -tag:v hvc1 -an output.mp4
```

**web** (M3): `entry` HTML이 폴더 내 상대 경로 리소스만 참조해야 함.
원격 리소스는 `permissions` 필드로 명시 예정.

## 3. active.json (엔진↔UI 계약)

위치(macOS): `~/Library/Application Support/Wallbloom/active.json`

```json
{
  "active": "/path/to/my-wallpaper",
  "paused": false
}
```

| 필드 | 설명 |
|---|---|
| `active` | wallpkg 폴더의 절대 경로. `"none"`이면 정지 |
| `paused` | UI 전역 일시정지 플래그 |

### 엔진 규칙

1. 파일 감시(폴링 ≤ 1초 또는 FSEvents), 변경 시 재로드
2. `active` 폴더의 `wall.json`을 읽어 재생 시작
3. 파싱 실패 시 **기존 배경화면 유지** (검은 화면 방지) + stderr 로그
4. UI 규칙: 원자적 쓰기(임시 파일 → rename)로 부분 쓰기 방지

## 4. 설치 위치

| 구분 | macOS 경로 |
|---|---|
| 라이브러리 (다운로드/임포트된 wallpkg들) | `~/Library/Application Support/Wallbloom/library/` |
| 활성 계약 | `~/Library/Application Support/Wallbloom/active.json` |
| 앱 번들 | `/Applications/Wallbloom.app` (엔진), UI는 별도 |

Windows (M4): `%APPDATA%\Wallbloom\` 아래 동일 구조.
