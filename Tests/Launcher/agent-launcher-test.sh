#!/bin/bash

# Exercises the real launcher with inert CLI executables. No login or network
# access is needed; the fake executable records each argument and profile path.
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
launcher="$project_root/Resources/agent-launcher.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/private-cli-launcher-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

test_home="$test_root/home"
profile_root="$test_root/private profiles"
capture="$test_root/capture.json"
calls="$test_root/calls.jsonl"
fake_cli="$test_root/fake-cli"
session_id=67af9c61-8ee9-4e90-8b28-29e427c554b0
prompt='--Fix café and åäö 🧪
Keep the literal $HOME and `whoami` text on this line.'

mkdir -p "$test_home/.claude" "$test_home/.codex"
printf 'Claude identity\n' > "$test_home/.claude/CLAUDE.md"
printf 'Codex identity\n' > "$test_home/.codex/AGENTS.md"

cat > "$fake_cli" <<'FAKE'
#!/bin/bash
exec python3 - "$@" <<'PY'
import json
import os
import sys

record = {
    "argv": sys.argv[1:],
    "claude_profile": os.environ.get("CLAUDE_CONFIG_DIR"),
    "codex_profile": os.environ.get("CODEX_HOME"),
    "anthropic_key": os.environ.get("ANTHROPIC_API_KEY"),
    "openai_key": os.environ.get("OPENAI_API_KEY"),
}
with open(os.environ["FAKE_CLI_CAPTURE"], "w", encoding="utf-8") as target:
    json.dump(record, target, ensure_ascii=False)
with open(os.environ["FAKE_CLI_CALLS"], "a", encoding="utf-8") as target:
    target.write(json.dumps(record["argv"], ensure_ascii=False) + "\n")
PY
FAKE
chmod 700 "$fake_cli"

launch_fake() {
    env \
        HOME="$test_home" \
        PRIVATE_CLI_HOST_DATA_DIR="$profile_root" \
        PRIVATE_CLI_HOST_CLAUDE_BIN="$fake_cli" \
        PRIVATE_CLI_HOST_CODEX_BIN="$fake_cli" \
        FAKE_CLI_CAPTURE="$capture" \
        FAKE_CLI_CALLS="$calls" \
        ANTHROPIC_API_KEY=should-be-cleared \
        OPENAI_API_KEY=should-be-cleared \
        CLAUDE_CONFIG_DIR=should-be-cleared \
        CODEX_HOME=should-be-cleared \
        "$launcher" "$@"
}

assert_capture() {
    local agent=$1
    local action=$2
    local with_prompt=$3
    python3 - "$capture" "$profile_root" "$agent" "$action" "$with_prompt" "$session_id" "$prompt" <<'PY'
import json
import os
import sys

capture, root, agent, action, with_prompt, session_id, prompt = sys.argv[1:]
with open(capture, encoding="utf-8") as source:
    record = json.load(source)

if agent == "claude":
    args = ["--settings", '{"preferredNotifChannel":"ghostty"}']
    args += (["--session-id", session_id] if action == "run" else ["--resume", session_id])
else:
    args = ["-c", 'cli_auth_credentials_store="file"', "-c", 'tui.terminal_title=["session-id"]',
            "-c", "tui.notifications=true", "-c", 'tui.notification_method="osc9"',
            "-c", 'tui.notification_condition="always"']
    if action == "resume":
        args += ["resume", session_id]
if with_prompt == "yes":
    args += ["--", prompt]

assert record["argv"] == args, (record["argv"], args)
assert record["claude_profile"] == (os.path.join(root, "claude") if agent == "claude" else None)
assert record["codex_profile"] == (os.path.join(root, "codex") if agent == "codex" else None)
assert record["anthropic_key"] is None
assert record["openai_key"] is None
PY
}

launch_fake claude run --session-id "$session_id" "$prompt"
assert_capture claude run yes

launch_fake codex run "$prompt"
assert_capture codex run yes

launch_fake claude resume "$session_id" "$prompt"
assert_capture claude resume yes

launch_fake codex resume "$session_id" "$prompt"
assert_capture codex resume yes

# The toolbar can still open a blank interactive conversation.
launch_fake claude run --session-id "$session_id"
assert_capture claude run no
launch_fake codex run
assert_capture codex run no

# A fresh authenticated Claude profile needs one bounded repair check. Once
# the marker exists, future launches must skip that extra CLI call.
printf '{}\n' > "$profile_root/claude/.claude.json"
rm -f "$calls"
launch_fake claude run --session-id "$session_id"
[[ $(wc -l < "$calls") -eq 2 ]]
python3 - "$profile_root/claude/.claude.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    assert json.load(source)["hasCompletedOnboarding"] is True
PY
rm -f "$calls"
launch_fake claude run --session-id "$session_id"
[[ $(wc -l < "$calls") -eq 1 ]]

[[ -L "$profile_root/claude/CLAUDE.md" ]]
[[ -L "$profile_root/codex/AGENTS.md" ]]
[[ $(readlink "$profile_root/claude/CLAUDE.md") == "$test_home/.claude/CLAUDE.md" ]]
[[ $(readlink "$profile_root/codex/AGENTS.md") == "$test_home/.codex/AGENTS.md" ]]

rm -f "$capture"
if launch_fake claude run --session-id not-a-uuid "$prompt" >/dev/null 2>&1; then
    printf 'Invalid Claude UUID was accepted\n' >&2
    exit 1
fi
[[ ! -e "$capture" ]]

# Simulate simultaneous account checks and terminal launches on fresh profiles.
for round in 1 2 3; do
    profile_root="$test_root/concurrent-$round"
    jobs=()
    for agent in claude codex; do
        for copy in 1 2 3 4; do
            launch_fake "$agent" status >"$test_root/$round-$agent-$copy.log" 2>&1 &
            jobs+=("$!")
        done
    done
    for job in "${jobs[@]}"; do wait "$job"; done
    [[ $(readlink "$profile_root/claude/CLAUDE.md") == "$test_home/.claude/CLAUDE.md" ]]
    [[ $(readlink "$profile_root/codex/AGENTS.md") == "$test_home/.codex/AGENTS.md" ]]
done

printf 'agent-launcher prompt and profile tests passed\n'
