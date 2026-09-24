#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/wallbloom-native-evidence-XXXXXX")"
printf 'Evidence directory: %s\n' "$evidence"
printf 'provider=%s model=%s worker_pid=%s\n' "${PI_PROVIDER:-unset}" "${PI_MODEL:-unset}" "$$" | tee "$evidence/environment.log"
cd "$root/ui/src-tauri"
start=$SECONDS
set +e
cargo test native_http_download_progress_publication_and_failure_cleanup -- --nocapture 2>&1 | tee "$evidence/http-test.log"
code=${PIPESTATUS[0]}
set -e
printf 'native_http_exit=%s elapsed_seconds=%s\n' "$code" "$((SECONDS-start))" | tee "$evidence/result.log"
if [[ "$code" != 0 ]]; then exit "$code"; fi
printf '%s\n' 'PASS: real localhost HTTP / production Rust downloader / progress callback / exact video bytes / publication / HTTP error, truncated transfer and duplicate staging cleanup.' | tee -a "$evidence/result.log"
cargo build --features native-acceptance --bin wallbloom-native-acceptance 2>&1 | tee "$evidence/tauri-build.log"
python3 "$root/ui/scripts/native-download.py" "$root" "$evidence"
printf '%s\n' 'PASS: production Rust commands with live Tauri AppHandle progress delivery, scan/select, exact video bytes and failure cleanup; see app-handle.json and live-download.json.' | tee -a "$evidence/result.log"
(cd "$root/ui" && bun run build) 2>&1 | tee "$evidence/frontend-build.log"
# Clear devUrl to embed the production frontend instead of requiring Vite.
TAURI_CONFIG='{"build":{"devUrl":null}}' cargo build --features native-acceptance --bin wallbloom-ui 2>&1 | tee "$evidence/gui-build.log"
python3 "$root/ui/scripts/native-gui.py" "$root" "$evidence"
printf '%s\n' 'PASS: real Tauri WebView UI, JavaScript IPC, progress/error rendering and trusted macOS keyboard.' | tee -a "$evidence/result.log"
