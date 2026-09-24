# OpenUI + rustra integration receipt

## Scope and source verification

This implements the latest explicit renderer-only request, superseding the older
“do not install OpenUI” decision in `../docs/UI_DESIGN.md`. No AI backend, API key,
Codex OAuth, or model calls are part of the application. Local metadata is never
represented as a model response. Only `ui/` source/configuration was changed.

Verified npm registry versions and installed exports:
- `@openuidev/react-lang`, `@openuidev/lang-core`, `@openuidev/cli`: 0.3.0
- `@rustra/tauri`: 0.9.3; `@rustra/types`: 0.12.0; `@rustra/cli`: 0.11.3
- Rust `rustra`: exact 0.11.0, `schemars`: 0.8 (rustra's schema trait version)
- rustra requires Tauri 2.11.5; Cargo resolved 2.11.6 → 2.11.5. Native verification below includes this version.

Primary sources: https://github.com/loopy-lim/rustra (README and tauri_support),
installed rustra crate source, installed `@rustra/tauri/dist` and generated files;
https://github.com/thesysdev/openui and installed OpenUI `.d.mts` exports.
The OpenUI README's direct component-props example differs from the installed
renderer type: this integration uses the verified `component: ({ props }) => …` API.
No claim of verification against the previously unavailable docs.openui.com host.

## Installation and generation

Executed from `ui/`:

```sh
bun add --exact @openuidev/react-lang@0.3.0 zod@4.6.5 @rustra/tauri@0.9.3 @rustra/types@0.12.0
bun add -d --exact @rustra/cli@0.11.3 @openuidev/cli@0.3.0
(cd src-tauri && cargo add rustra@=0.11.0 --features tauri && cargo add schemars@0.8)
bun run generate:bridge
bun run generate:openui
bun run check:bridge
```

`rustra.json` runs `src-tauri/src/bin/generate-contract.rs` to publish the schema
from `bridge::package()`, then the official CLI creates `src/generated/*.ts`.
These files are not handwritten. `generate:openui` serializes the actual library
export using the official CLI, without telemetry. Bun blocks lang-core's optional
telemetry postinstall; it is not required for rendering or generation.

## Runtime paths

- `src/App.tsx` → `src/lib/bridge.ts` → generated `scanLibrary({})` → official
  Tauri adapter → `rustra_dispatch` → `src-tauri/src/bridge.rs` → original scanner.
- Empty input is an explicit Rust struct because the Tauri JSON adapter sends
  `{}` while rustra's unit input expects null. The Rust dispatch regression test
  caught that mismatch before native verification.
- Download progress uses Rust `DownloadProgress`, generated event payloads and
  `onRustraEvent`, and the official `subscribeEvent` with the existing Tauri
  `listen` transport. Emits `rustra://download-progress`; the legacy channel is
  retained for existing native consumers. Emit errors propagate and trigger
  staging cleanup. UI unsubscribes on completion/failure.
- Select and download commands intentionally remain on their existing Tauri
  commands. No duplicated frontend scan or progress subscription path.
- `src/components/LibraryInfoPanel.tsx` runs the real OpenUI parser + `Renderer`
  with `src/lib/library-info.tsx`. It shows preview coverage, missing-preview
  guidance and the last successfully selected package's storage path. The label
  says “로컬 파일 정보 · OpenUI 렌더러 · AI 생성 아님”. JSON-escaped strings and a
  single read-only allowed component prevent local titles from becoming code.
  Parser errors produce an explicit alert. No Query, Mutation, URL or HTML tool.

Other changed files: `package.json`, `bun.lock`, `src-tauri/Cargo.toml`,
`src-tauri/Cargo.lock`, `src-tauri/src/lib.rs`, `src-tauri/src/native_tests.rs`,
`src/App.test.tsx`, `src/components/LibraryInfoPanel.test.tsx`, and
`scripts/gui-harness.js` (adds real-WebView OpenUI assertion).

## Verification (2026-09-24)

- Initial regression: new generated-transport UI test failed against the original
  raw `scan_library` invocation; five existing tests passed.
- `bun install && bun run test && bun run build`: PASS. 2 files, **8 tests passed**;
  TypeScript and Vite production build passed.
- `cargo test && cargo check`: PASS. **7 Rust tests passed**, including real HTTP
  bytes/progress/cleanup and registered rustra dispatch / event wire contracts.
- `bun run check:bridge`: PASS, generated-output drift check.
- `bun run generate:openui`: PASS; real parser escaping/render/update tests pass.
- Required package/runtime import checks: PASS.
- `bash ui/scripts/verify-native.sh`: PASS. Real Wry WebView invokes generated
  scan, renders OpenUI selection metadata, handles trusted OS Enter, download
  progress/completion, re-scan, and HTTP 503. Byte equality and staging cleanup
  passed. Existing installed process PID 68589 and user's active state unchanged.
  Evidence: `/var/folders/z8/h16kj6d16t53dj0lfvlkxf0h0000gn/T/wallbloom-native-evidence-prt9A8`
  (`gui-acceptance.json`, `gui-complete.json`, HTTP and build logs/screenshots).
- `bash ui/scripts/verify-hotswap.sh`: PASS. Captured A→B **1002.6 ms**, B→A
  **927.4 ms**, both ≤3 seconds; original user state unchanged.
  Evidence: `/var/folders/z8/h16kj6d16t53dj0lfvlkxf0h0000gn/T/wallbloom-hotswap-evidence-65tyx70y`.
  This is atomic-file selection→visible capture, not GUI-click→frame timing.
- React Doctor full scan: **94/100**, no errors, two component-export warnings
  (new panel helper and existing button export). Vite reports two upstream Zod
  PURE-comment warnings. These are not test/build failures.

Model provenance: worker environment reports `PI_PROVIDER=openai-codex`,
`PI_MODEL=gpt-6-astra`. No other worker/model was launched. This is environment
identification, not independent routing attestation. No model credentials are
read by application code.
