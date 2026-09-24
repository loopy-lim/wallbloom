# 리소스 측정 기록

환경: MacBook Pro M1 Max, 64GB, macOS 26.6, 듀얼 모니터 (내장 1728×1117 + 외장 3200×2000)
영상: 4K 3840×2160, 25fps, 10초 루프

| 구성 | CPU (%) | RAM | 비고 |
|---|---|---|---|
| Dynamic Wallpaper (상용, 제거 전 기준선) | 8.3 (앱 4.0 + VTDecoder 4.3) | 822 MB | 소프트웨어 경로 H.264 |
| Wallbloom + H.264 4K | 7.7 (앱 4.8 + 디코더 2.9) | 62 MB | 해상도 제한 적용 |
| **Wallbloom + HEVC(hvc1) 4K** | **2.2** | **20 MB** | 미디어 엔진(ASIC) 디코딩 |

## 교훈

1. **HEVC + hvc1 태그**가 핵심. `hev1` 태그는 디코드는 되지만 AVPlayerLayer에서 렌더링 안 됨.
2. `preferredMaximumResolution`을 화면 크기로 제한하면 디코더 부담 감소.
3. AVPlayerLayer는 `makeBackingLayer()` 패턴으로 백킹 레이어로 쓰는 게 정석.
4. 데스크톱 레벨 배치: Dock 배경화면(-2147483624) 위, Finder 데스크톱(-2147483603) 아래 → -2147483610.
