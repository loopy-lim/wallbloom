# 이름 결정 기록 (NAMING)

**확정: Wallbloom** (2026-09-24)

## 후보 검토

GitHub 전체 저장소 검색(`api.github.com/search/repositories?q=<이름>+in:name`)으로
충돌을 확인한 결과:

| 후보 | 검색 결과 | 판정 |
|---|---|---|
| **wallbloom** | 1개 (0★, 방치) | ✅ **채택** — 사실상 미사용, 의미가 좋음 |
| openpaper | 77개, khoj-ai/openpaper 482★ | ❌ 기존 프로젝트와 충돌 |
| wallcore | 2개 (0★) | 🟡 가능하나 범용적임 |
| scenewall | 2개 (0★) | 🟡 "씬"에만 국한되는 느낌 |

## 선정 이유

- **의미**: wallpaper + bloom(피어나다). 정적인 벽이 살아 피어나는 이미지로
  영상/웹/씬 배경화면이라는 제품 정체성과 맞음
- **발음/기억**: 짧고 부르기 쉬움, "Wallpaper Engine" 검색 대체어로도 자연스러움
- **충돌 없음**: 상징적 프로젝트와 겹치지 않아 브랜드로 성장 가능

## 네이밍 규칙 (이 문서가 단일 출처)

| 대상 | 값 |
|---|---|
| 프로젝트/저장소 | `wallbloom` (`github.com/loopy-lim/wallbloom`) |
| macOS 앱 | `Wallbloom.app` |
| Bundle ID | `dev.loopylim.wallbloom` |
| 설정 디렉토리 (macOS) | `~/Library/Application Support/Wallbloom/` |
| 활성 배경화면 계약 파일 | `active.json` (아래 WALLPKG_SPEC 참고) |
| Windows (예정) | `%APPDATA%\Wallbloom\` |
| UI(Tauri) 앱 이름 | `Wallbloom` |

새 컴포넌트(데몬, CLI 등)가 생기면 이 표에 추가할 것.
