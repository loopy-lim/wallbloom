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

메뉴바 🎬 에서 일시정지·영상 교체·종료. 인자 없이 실행하면
`sample-hevc.mp4` 또는 `~/Movies/wallbloom.mp4`를 재생합니다.

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
