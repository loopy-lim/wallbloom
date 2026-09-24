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

## 최종 직렬 acceptance 재실행 (2026-09-25 00:08–00:11 KST)

명령: `make -B && (cd ui && bun run check:bridge && bun run test && bun run build && cd src-tauri && cargo test && cargo check) && bash ui/scripts/verify-scene.sh && bash ui/scripts/verify-registry.sh && bash ui/scripts/verify-hotswap.sh && bash ui/scripts/verify-web.sh && bash ui/scripts/verify-web-perf.sh && bash ui/scripts/verify-integrated.sh && git diff --check`. 전체 종료 코드 **0**. 단계는 직렬 실행이다.

| 검사 | 종료 코드 | 결과 / 근거 |
|---|---:|---|
| `make -B` | 0 | Swift `swiftc -O` clean build 및 번들 서명. 작업 트리 `Wallbloom.app` 산출물 재생성. |
| `bun run check:bridge` | 0 | rustra contract drift 없음. |
| `bun run test` | 0 | UI **9/9** 통과. |
| `bun run build` | 0 | TypeScript/Vite build 성공; zod 의존성 주석 경고만 있음. |
| `cargo test` | 0 | Rust **16/16** 통과. |
| `cargo check` | 0 | 성공; `copy_package_safely` dead-code warning. |
| `verify-scene.sh` | 0 | 캡처 3456×2234, fixture-like pixel 8,036; 자식 실행·전환 종료·회수 PASS. 순간 CPU 2.6%는 지속 측정 아님. |
| `verify-registry.sh` | 0 | archive 안전성, local HTTP fetch/install 및 UI wiring PASS; 외부 live registry는 미검증. |
| `verify-hotswap.sh` | 0 | A→B/B→A 가시 픽셀 핫스왑 PASS, 3초 이내. 증거 경로는 실행 로그 참조. |
| `verify-web.sh` | 0 | WebGL/보안/video 왕복 PASS, runtime_failures=0. OS-posted 입력 확인. |
| `verify-web-perf.sh` | 0 | Web acceptance 통과; 무거운 reactive shader 13 samples, CPU 평균/최대 **13.946% / 92.500%**, RSS 평균/최대 **140.12 / 259.31 MiB**. CPU <10% 목표 **FAIL**. |
| `verify-integrated.sh` | 0 | 통합 fixture PASS; Enter→A 1657ms, OS click→B 1717ms, Enter→A 1600ms. 엔진 CPU 평균 0.42%, RSS 평균 53.98 MiB/최대 54.73 MiB (15 samples). 자동 OS 입력이며 물리 마우스 증거 아님. |
| `git diff --check` | 0 | whitespace 검사 통과. |

웹 모드 비교: 직전 동일 harness의 경량 기본 WebGL 모드 실측은 13 samples, CPU 평균/최대 **13.531% / 93.300%**, RSS 평균/최대 **138.90 / 259.33 MiB**로 역시 목표 미달이다. 무거운 reactive shader 최신 수치와 함께 두 모드 모두 CPU 목표 FAIL로 판정한다. Heavy 증거 `/var/folders/z8/h16kj6d16t53dj0lfvlkxf0h0000gn/T/wallbloom-web-perf-BSfiEt`, light 증거 `/var/folders/z8/h16kj6d16t53dj0lfvlkxf0h0000gn/T/wallbloom-web-perf-kISxAX`.

미완료/HITL: 물리 마우스는 integrated 자동 runner에서 이전 시도 exit 2 (키보드 evidence timeout); 실제 물리 입력은 미수행이다. 저전력 HITL은 sudo 필요로 미측정. 단일 Space 환경이라 다중 Space 미검증. Unity/Unreal 설치물 및 standalone player가 없어 M5 실측 불가(호환 실패가 아닌 미검증). 이 항목들은 완료로 승격하지 않는다. Unity/Unreal 확인 및 실행 경로는 `docs/ROADMAP.md`에 기록했다. 사용자 설치 앱과 `active.json`은 검증 runner 기록상 전후 동일.

모델 식별자: `openai-codex/gpt-6-luna` (환경 보고값이며 라우팅 증명은 아님).
