#!/bin/bash
# Uses the installed private accounts, but isolates UI preferences and QA notes.
# The prompts request short verification words and never authorize file edits.
set -euo pipefail
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/Packaging/version.env"
app=${1:-"$root/outputs/m4ix.CLI $APP_VERSION.app"}
[[ -x "$app/Contents/MacOS/PrivateCLIHost" ]] || { printf 'Missing packaged app: %s\n' "$app" >&2; exit 1; }
codesign --verify --strict "$app"
qa_suite="m4ix.cli.qa.$(uuidgen)"
qa_output=$(mktemp -d "$root/outputs/packaged-runtime.XXXXXXXX")
trap 'defaults delete "$qa_suite" >/dev/null 2>&1 || true' EXIT
cd "$root"
PRIVATE_CLI_HOST_PREFERENCES_SUITE="$qa_suite" \
M4IX_PACKAGED_SMOKE_REPORT="$qa_output/report.json" \
"$app/Contents/MacOS/PrivateCLIHost" > "$qa_output/app.log" 2>&1
python3 -I - "$qa_output/report.json" <<'PY'
import json
import sys
from pathlib import Path
report = Path(sys.argv[1])
if not report.exists():
    raise SystemExit('Packaged app exited without a verification report')
result = json.loads(report.read_text())
print(json.dumps(result, indent=2, sort_keys=True))
print('Report:', report)
if not result.get('passed'):
    raise SystemExit(1)
PY
