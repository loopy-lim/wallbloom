# 🎬 Videowall

macOS용 최소 네이티브 영상 배경화면 앱. Apple Silicon의 하드웨어 미디어 엔진으로
디코딩하여 **CPU 몇 %, 메모리 수십 MB**로 영상 배경화면을 돌릴 수 있습니다.

서드파티 의존성 없음. AppKit + AVFoundation만 사용 (~200줄).

## 특징

- 데스크톱 레벨 윈도우에 무한 루프 재생 (모든 Space, 클릭 완전 통과)
- 멀티 모니터 지원 (화면마다 독립 플레이어)
- 메뉴바 🎬 아이콘에서 일시정지 / 영상 변경 / 종료
- 저전력 모드 진입 시 자동 일시정지
- 화면 해상도 이상으로 디코드하지 않도록 제한 (`preferredMaximumResolution`)

## 빌드

```bash
make          # Videowall.app 생성
make install  # /Applications에 복사
```

요구사항: Xcode Command Line Tools (Swift 5.9+)

## 사용

```bash
open /Applications/Videowall.app --args /path/to/video.mp4
```

인자 없이 실행하면 기본 후보 경로(`sample-hevc.mp4`, `~/Movies/videowall.mp4`) 중
존재하는 영상을 재생합니다. 메뉴바의 "영상 열기…"로 언제든 교체 가능합니다.

## ⚠️ 중요: HEVC 영상은 `hvc1` 태그 필수

AVPlayerLayer는 HEVC라도 codec 태그가 `hev1`이면 디코딩은 되지만 **렌더링이 안
됩니다** (검은 화면). `hvc1` 태그로 인코딩하세요:

```bash
ffmpeg -i input.mp4 -c:v hevc_videotoolbox -b:v 12M -tag:v hvc1 -an output.mp4
```

`hevc_videotoolbox`(하드웨어 인코더) + `hvc1` 조합이 Apple Silicon에서 가장 효율적입니다.

## 리소스 측정 (M1 Max, 4K 25fps 10초 루프, 듀얼 모니터)

| 구성 | CPU | RAM |
|---|---|---|
| 상용 서드파티 앱 (Dynamic Wallpaper) | ~8.3% (앱 4.0% + 디코더 4.3%) | 822 MB |
| Videowall + H.264 4K | ~7.7% | ~62 MB |
| **Videowall + HEVC(hvc1) 4K** | **~2.2%** | **~20 MB** |

HEVC는 M 시리즈 칩의 전용 미디어 엔진(ASIC)으로 디코딩되어 CPU를 거의 쓰지 않습니다.

## 동작 원리

1. 화면마다 `NSWindow`를 하나씩 만들어 레벨 `-2147483610`(데스크톱 그림 위, 파인더
   데스크톱 아래)에 띄웁니다
2. `makeBackingLayer()`로 `AVPlayerLayer`를 백킹 레이어로 사용
3. `AVPlayerLooper`로 끊김 없는 루프 재생
4. `ignoresMouseEvents = true` + `canJoinAllSpaces`로 배경화면처럼 동작

## 라이선스

MIT
