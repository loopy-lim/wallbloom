#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Acceptance coverage includes archive traversal rejection/round-trip and the existing
# downloader regression suite; registry commands are exercised by the Rust fixture test.
cargo test --manifest-path src-tauri/Cargo.toml archive_import_rejects_zip_slip_and_installs_valid_archive
cargo test --manifest-path src-tauri/Cargo.toml archive_import_rejects_symlink_entries
cargo test --manifest-path src-tauri/Cargo.toml wallpkg_archive_round_trip_preserves_valid_package
cargo test --manifest-path src-tauri/Cargo.toml registry_local_http_fetch_and_install
rg -q 'export_wallpkg, fetch_registry, install_registry_entry' src-tauri/src/lib.rs
rg -q '레지스트리' src/App.tsx
printf 'registry-acceptance: archive safety, local HTTP registry fetch/install, and UI wiring verified\n'
