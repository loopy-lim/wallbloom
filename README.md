# 🌸 Wallbloom

**macOS에서 돌아가는 오픈소스 Wallpaper Engine.** 한김에 Windows까지.

영상·웹 배경화면을 하드웨어 미디어 엔진으로 재생합니다.
Apple Silicon 기준 **CPU ~2%, RAM ~20MB** (4K HEVC 루프).

| | |
|---|---|
| macOS | ✅ 영상 엔진 완성 (M1) |
| Windows | 🔮 예정 (M4, C#) |
| 라이선스 | MIT |

## 빠른 시작

```bash
make && make install
open /Applications/Wallbloom.app --args /path/to/video.mp4
```

## 사용법

- **앱 재실행** (`open -a Wallbloom`) → 설정 창 표시: 현재 재생 중인 영상 확인, 영상 교체(열기), 화면 맞춤 모드(cover/contain/stretch), 로그인 시 시작, Dock에 아이콘 표시, 메뉴바에 아이콘 표시, 일시정지/재개, Wallbloom 끄기. 설정 창을 닫아도 배경화면은 계속 재생되며, 앱을 다시 실행하면 창이 다시 뜹니다.
- Wallbloom은 기본적으로 배경화면 앱이라 Dock 아이콘과 cmd-Tab에 나타나지 않습니다. 설정 창의 **'Dock에 아이콘 표시'** 토글을 켜면 Dock 아이콘(메뉴: 일시정지/재개, 끄기)이 즉시 나타나고, **'메뉴바에 아이콘 표시'** 토글을 켜면 메뉴바 아이콘(메뉴: 일시정지/재개, 영상 교체…, Wallbloom 끄기)이 즉시 생깁니다. 두 설정은 재시작 후에도 유지됩니다.

인자 없이 실행하면 `sample-hevc.mp4` 또는 `~/Movies/wallbloom.mp4`를 재생합니다.

> ⚠️ HEVC 영상은 `hvc1` 태그 필수 (`hev1`은 렌더링 불가):
> `ffmpeg -i in.mp4 -c:v hevc_videotoolbox -b:v 12M -tag:v hvc1 -an out.mp4`

## 문서

| 문서 | 내용 |
|---|---|
| [docs/ROADMAP.md](docs/ROADMAP.md) | M1~M5 마일스톤 (M1 완료, M2 = Tauri UI) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 엔진/UI 분리 구조 + 알려진 함정 |
| [docs/WALLPKG_SPEC.md](docs/WALLPKG_SPEC.md) | wallpkg / active.json 계약 스펙 |
| [docs/DEV_GUIDE.md](docs/DEV_GUIDE.md) | 개발 이어하기 가이드 |
| [docs/NAMING.md](docs/NAMING.md) | 이름 결정 기록 |
| [MEASUREMENTS.md](MEASUREMENTS.md) | 리소스 측정 기록 |

## 리소스 비교 (M1 Max, 4K 25fps 루프, 듀얼 모니터)

| 구성 | CPU | RAM |
|---|---|---|
| 상용 서드파티 앱 | ~8.3% | 822 MB |
| Wallbloom + H.264 | ~7.7% | 62 MB |
| **Wallbloom + HEVC(hvc1)** | **~2.2%** | **~20 MB** |

## 라이선스

MIT — [LICENSE](LICENSE)
