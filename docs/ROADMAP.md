# 로드맵

> 목표: **macOS에서 돌아가는 오픈소스 Wallpaper Engine**. 한김에 Windows까지.
> 배경: Wallpaper Engine(Steam)은 macOS 미지원, Lively는 Windows 전용, Plash는 웹만.
> "맥에서 영상+웹 배경화면" 자리가 비어 있음.

## 마일스톤

### M1 ✅ macOS 영상 엔진 (2026-09-24 완료)

- Swift + AVPlayerLayer 데스크톱 레벨 루프 재생
- 측정: HEVC(hvc1) 4K 기준 **CPU 2.2%, RAM 20MB** (MEASUREMENTS.md)
- 완료 조건 달성: 멀티 모니터, 클릭 통과, 모든 Space, 저전력 자동 일시정지

### M2 🔜 Tauri UI + wallpkg 포맷 (다음 작업)

- [ ] `wall.json` 계약 확정 (docs/WALLPKG_SPEC.md v0.1 → 구현하며 0.2로 갱신)
- [ ] Tauri 스캐폴딩: `ui/` 디렉토리, Rust + TypeScript
- [ ] 라이브러리 그리드: 영상 폴더 스캔 → 썸네일 목록
- [ ] 활성 배경화면 선택 → `active.json` 기록 → 엔진 즉시 전환 (핫스왑)
- [ ] URL 다운로드 v1 (진행률 표시)
- 완료 조건: UI에서 영상 하나 클릭하면 3초 안에 바탕화면이 바뀜

### M3 🔜 macOS Web 엔진

- 데스크톱 레벨 WKWebView로 HTML 배경화면 재생 (Wallpaper Engine의 web 타입 대응)
- wallpkg의 `type: "web"` 처리, 폴더 통째로 임포트 지원
- 완료 조건: shadertoy 스타일 HTML 배경이 안정 구동 (CPU < 10%)

### M4 🔜 Windows 영상 엔진 (C#)

- Win32 WorkerW 트릭으로 데스크톱 아이콘 뒤에 창 부착
- MediaElement/Win2D 기반 루프 재생, 같은 `active.json` 계약 소비
- 같은 Tauri UI 재사용 (WebView2)
- 완료 조건: Windows 11에서 멀티 모니터 영상 배경화면 + 클릭 통과

### M5 🔮 씬 엔진 & 생태계

- Unity 기반 씬 배경화면 (셰이더/파티클 실시간 생성)
- 배경화면 공유 포맷 패키징 + 브라우징 (GitHub 기반 레지스트리부터)

## 원칙

1. **엔진-UI 분리**: UI는 `active.json`만 쓰고, 엔진은 `active.json`만 읽는다.
   플랫폼별 엔진이 달라도 UI는 하나.
2. **리소스 상한 의식**: 영상 엔진은 CPU < 5%, RAM < 100MB를 유지한다. 회귀 시 측정 문서 갱신.
3. **독립 포맷**: Steam Workshop 콘텐츠를 긁어오지 않는다. 같은 경험을 자체 오픈 포맷으로.
4. **문서 갱신**: 마일스톤 완료 시 이 파일의 체크박스와 MEASUREMENTS.md를 함께 갱신.
