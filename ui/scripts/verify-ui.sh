#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

printf '%s\n' 'UI automated verification (jsdom; Tauri APIs mocked):'
bun run test
bun run build
printf '%s\n' 'PASS: component rendering, empty library, keyboard navigation/selection, download progress/success/failure, and listener cleanup covered by tests.'
printf '%s\n' 'SKIP: native GUI/VoiceOver and real Tauri invoke/event/network download were not exercised by jsdom tests.'
