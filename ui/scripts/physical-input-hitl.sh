#!/usr/bin/env bash
set -u
root="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/wallbloom-physical-hitl-XXXXXX")"
model="${PI_MODEL:-unset}"; provider="${PI_PROVIDER:-unset}"
# First run the integrated synthetic route strictly as a control; it is never physical evidence.
set +e
bash "$root/ui/scripts/verify-integrated.sh" >"$evidence/synthetic-control.log" 2>&1
control=$?
set -e
cat > "$evidence/result.json" <<EOF
{"status":"HITL","physical_evidence":false,"synthetic_control_exit":$control,"synthetic_control":"$evidence/synthetic-control.log","evidence":"$evidence","model":"$model","provider":"$provider","instructions":"Run this script in the logged-in GUI session, then physically click the displayed test card when prompted; save the requested click-to-visible capture/report in this directory."}
EOF
printf 'HITL: synthetic control exit=%s (not physical evidence). Evidence: %s\n' "$control" "$evidence"
printf 'User action: execute bash %q in the logged-in desktop session and physically click the test card when prompted.\n' "$0"
printf 'No physical click was fabricated; JSON status remains HITL.\n'
