#!/bin/bash

# Launch the user's private CLI accounts without borrowing the Codex app's or
# another terminal's authentication, configuration, or active session.
# Hermes keeps its own home instead of a private profile: its memory, skills,
# and provider login are shared with its other surfaces.
set -euo pipefail
umask 077

fail() {
    printf 'Private CLI Host: %s\n' "$*" >&2
    exit 1
}

if [[ $# -lt 2 ]]; then
    fail 'usage: agent-launcher.sh claude|codex|hermes run|login|status|resume [--session-id UUID] [session ID] [prompt]'
fi

agent=$1
action=$2
shift 2

case "$agent" in
    claude|codex|hermes) ;;
    *) fail "unknown CLI: $agent (use claude, codex, or hermes)" ;;
esac

case "$action" in
    run|login|status|resume|version|discuss) ;;
    *) fail "unknown action: $action (use run, login, status, resume, version, or discuss)" ;;
esac

valid_uuid() {
    [[ "$1" =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]
}

# Hermes names sessions by their start time, as in 20261011_235540_a37dd0.
valid_hermes_session() {
    [[ "$1" =~ ^[0-9]{8}_[0-9]{6}_[0-9a-f]{4,32}$ ]]
}

# A prompt is one positional argument, even when it contains spaces, Unicode,
# newlines, or text that looks like a CLI option. Swift passes it as one argv
# item; the launcher never reconstructs it through a shell command string.
session_id=''
case "$agent:$action" in
    claude:discuss|codex:discuss)
        [[ $# -le 1 ]] || fail 'discuss accepts only an optional session UUID; send the message on stdin'
        if [[ $# -eq 1 ]]; then
            session_id=$1
            valid_uuid "$session_id" || fail 'discuss requires a valid session UUID'
            shift
        fi
        ;;
    claude:run)
        if [[ $# -gt 0 ]]; then
            [[ "$1" == --session-id ]] ||
                fail 'Claude run arguments must be --session-id UUID [prompt]'
            shift
            [[ $# -ge 1 && $# -le 2 ]] ||
                fail 'Claude run requires one session UUID and at most one prompt'
            session_id=$1
            valid_uuid "$session_id" || fail 'Claude run requires a valid session UUID'
            shift
        fi
        ;;
    codex:run)
        [[ $# -le 1 ]] || fail 'Codex run accepts at most one prompt'
        ;;
    claude:resume|codex:resume)
        [[ $# -ge 1 && $# -le 2 ]] ||
            fail 'resume requires one session UUID and at most one prompt'
        session_id=$1
        valid_uuid "$session_id" || fail 'resume requires a valid session UUID'
        shift
        ;;
    hermes:discuss)
        fail 'Shared chat is for Claude and Codex'
        ;;
    hermes:resume)
        # Hermes takes its first message through the terminal input only.
        [[ $# -eq 1 ]] || fail 'Hermes resume requires one session ID'
        session_id=$1
        valid_hermes_session "$session_id" || fail 'resume requires a valid Hermes session ID'
        shift
        ;;
    *)
        [[ $# -eq 0 ]] || fail "the $action action does not take CLI arguments"
        ;;
esac

[[ -n ${HOME:-} ]] || fail 'HOME is not set'

# GUI apps normally receive a short PATH. Keep the inherited PATH too, so
# custom installations remain available without shell startup files.
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"
export PATH

if [[ "$agent" == hermes ]]; then
    # The host passes the home it reads History from. Without one, Hermes
    # resolves its own default and active profile.
    [[ -z ${HERMES_HOME:-} || "$HERMES_HOME" == /* ]] || fail 'HERMES_HOME must be an absolute path'
else
    data_root=${PRIVATE_CLI_HOST_DATA_DIR:-"$HOME/Library/Application Support/Private CLI Host"}
    case "$data_root" in
        /*) ;;
        *) fail 'PRIVATE_CLI_HOST_DATA_DIR must be an absolute path' ;;
    esac

    [[ ! -L "$data_root" ]] || fail "data directory is a symbolic link: $data_root"
    mkdir -p -m 700 "$data_root" || fail "cannot create data directory: $data_root"

    profile_dir="$data_root/$agent"
    [[ ! -L "$profile_dir" ]] || fail "profile directory is a symbolic link: $profile_dir"
    mkdir -p -m 700 "$profile_dir" || fail "cannot create profile directory: $profile_dir"
    chmod 700 "$profile_dir" || fail "cannot secure profile directory: $profile_dir"

    # Identity instructions have one canonical home. Link only those files, never
    # credential stores, settings, session data, or whole profile directories.
    if [[ "$agent" == claude ]]; then
        identity_source="$HOME/.claude/CLAUDE.md"
        identity_link="$profile_dir/CLAUDE.md"
    else
        identity_source="$HOME/.codex/AGENTS.md"
        identity_link="$profile_dir/AGENTS.md"
    fi
    if [[ -f "$identity_source" && ! -e "$identity_link" && ! -L "$identity_link" ]]; then
        # Account checks and terminal launches may initialize a fresh profile together.
        # Accept a concurrent creation only when it points to the same canonical file.
        if ! ln -s "$identity_source" "$identity_link" 2>/dev/null; then
            [[ -L "$identity_link" && $(readlink "$identity_link") == "$identity_source" ]] ||
                fail 'cannot link identity instructions'
        fi
    fi
fi

# A desktop app, terminal, or prior CLI session may inject API credentials,
# alternate endpoints, cloud-provider switches, or Codex's own session paths.
# Clear all of them before invoking any CLI. This keeps subscription logins
# in the private profiles selected below, and Hermes on the credentials in
# its own home.
while IFS= read -r variable; do
    case "$variable" in
        ANTHROPIC_*|CLAUDE_*|CLAUDECODE|OPENAI_*|CODEX_*|AZURE_OPENAI_*)
            unset "$variable" || fail "cannot clear inherited variable: $variable"
            ;;
    esac
done < <(compgen -e)

case "$agent" in
    claude)
        export CLAUDE_CONFIG_DIR="$profile_dir"
        override_name=PRIVATE_CLI_HOST_CLAUDE_BIN
        executable_name=claude
        ;;
    codex)
        export CODEX_HOME="$profile_dir"
        override_name=PRIVATE_CLI_HOST_CODEX_BIN
        executable_name=codex
        ;;
    hermes)
        override_name=PRIVATE_CLI_HOST_HERMES_BIN
        executable_name=hermes
        ;;
esac

override=${!override_name:-}
if [[ -n "$override" ]]; then
    [[ "$override" == /* && -x "$override" && ! -d "$override" ]] ||
        fail "$override_name must point to an executable absolute path"
    cli=$override
else
    cli=$(type -P "$executable_name") ||
        fail "$executable_name CLI not found. Install it, then reopen Private CLI Host."
fi

# Claude's standalone login command can leave a fresh config directory with a
# valid OAuth login but without the first-run marker. In that state, `auth
# status` succeeds while the interactive CLI starts the browser-login screen
# again. Only repair that missing marker after this same profile's auth status
# succeeds. Leave all other onboarding, trust, and permission state alone.
repair_claude_onboarding() {
    local config_file="$profile_dir/.claude.json"
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 0

    type -P python3 >/dev/null || fail 'Python 3 is required to finish Claude profile setup'
    if ! python3 -I - "$config_file" "$cli" <<'PY'
import json
import os
import stat
import subprocess
import sys
import tempfile

path = sys.argv[1]
cli = sys.argv[2]
original_stat = os.lstat(path)
if not stat.S_ISREG(original_stat.st_mode):
    sys.exit(1)

with open(path, "rb") as source:
    settings = json.load(source)
if not isinstance(settings, dict):
    sys.exit(1)
if "hasCompletedOnboarding" in settings:
    sys.exit(0)

# Only a profile missing its marker needs this check. Bound the external CLI
# call so a stuck auth helper cannot hold the interactive terminal indefinitely.
try:
    status = subprocess.run(
        [cli, "auth", "status", "--text"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=8,
        check=False,
    )
except subprocess.TimeoutExpired:
    sys.exit(0)
if status.returncode != 0:
    sys.exit(0)

settings["hasCompletedOnboarding"] = True
rendered = (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
parent = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".claude.json.host-", dir=parent)
try:
    os.fchmod(fd, stat.S_IMODE(original_stat.st_mode))
    with os.fdopen(fd, "wb") as destination:
        destination.write(rendered)
        destination.flush()
        os.fsync(destination.fileno())

    current_stat = os.lstat(path)
    if (current_stat.st_ino != original_stat.st_ino
            or current_stat.st_mtime_ns != original_stat.st_mtime_ns
            or current_stat.st_size != original_stat.st_size):
        sys.exit(1)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
    then
        fail 'could not safely finish Claude profile setup; private settings were left intact'
    fi
}

# The host marks sessions that need attention from terminal notifications.
# Claude only sends them to terminals it recognises, so name a channel it
# will use here: OSC 777, as for Ghostty. Codex sends OSC 9 for approvals
# and finished turns; the host decides which ones to surface.
claude_flags=(--settings '{"preferredNotifChannel":"ghostty"}')
codex_flags=(
    -c 'cli_auth_credentials_store="file"'
    -c 'tui.terminal_title=["session-id"]'
    -c 'tui.notifications=true'
    -c 'tui.notification_method="osc9"'
    -c 'tui.notification_condition="always"'
)
# The composer reads Hermes's classic interface, whatever its default is.
hermes_flags=(chat --cli)

# The toolbar's model and effort apply to this session alone. Claude's own
# /model and /effort commands would save them as the profile's default.
model=${PRIVATE_CLI_HOST_MODEL:-}
effort=${PRIVATE_CLI_HOST_EFFORT:-}
unset PRIVATE_CLI_HOST_MODEL PRIVATE_CLI_HOST_EFFORT
model_pattern='^[A-Za-z0-9][][A-Za-z0-9._:-]{0,79}$'
effort_pattern='^[a-z]{1,16}$'
if [[ "$action" == run || "$action" == resume || "$action" == discuss ]]; then
    if [[ -n "$model" ]]; then
        [[ "$model" =~ $model_pattern ]] || fail 'the selected model name is not valid'
        claude_flags+=(--model "$model")
        codex_flags+=(-c "model=\"$model\"")
        hermes_flags+=(--model "$model")
    fi
    if [[ -n "$effort" ]]; then
        [[ "$effort" =~ $effort_pattern ]] || fail 'the selected effort level is not valid'
        claude_flags+=(--effort "$effort")
        codex_flags+=(-c "model_reasoning_effort=\"$effort\"")
        hermes_flags+=(--reasoning "$effort")
    fi
fi

case "$agent:$action" in
    claude:discuss)
        # Shared discussions can inspect the project, but have no write or
        # command tools. Prompts travel on stdin, never in process arguments.
        discuss_flags=(--print --output-format stream-json --verbose --include-partial-messages
            --permission-mode plan --permission-prompts none --tools 'Read,Glob,Grep'
            --strict-mcp-config --mcp-config '{"mcpServers":{}}')
        if [[ -n "$session_id" ]]; then discuss_flags+=(--resume "$session_id"); fi
        exec "$cli" "${claude_flags[@]}" "${discuss_flags[@]}"
        ;;
    codex:discuss)
        # Set the discussion policy explicitly, including when resuming.
        codex_flags+=(-c 'sandbox_mode="read-only"' -c 'approval_policy="never"')
        if [[ -n "$session_id" ]]; then
            exec "$cli" "${codex_flags[@]}" exec resume --json --skip-git-repo-check "$session_id" -
        fi
        exec "$cli" "${codex_flags[@]}" exec --json --skip-git-repo-check -
        ;;
    claude:version|codex:version|hermes:version)
        exec "$cli" --version
        ;;
    hermes:run)
        exec "$cli" "${hermes_flags[@]}"
        ;;
    hermes:resume)
        # Hermes follows a compressed conversation to its latest part.
        exec "$cli" "${hermes_flags[@]}" --resume "$session_id"
        ;;
    hermes:login)
        # The provider picker, with Nous Portal sign-in first. `hermes login`
        # is deprecated in its favour.
        exec "$cli" model
        ;;
    hermes:status)
        provider=$("$cli" config get model.provider 2>/dev/null | head -n 1) || provider=''
        [[ "$provider" =~ ^[A-Za-z0-9._:-]{1,64}$ ]] ||
            { printf 'No inference provider is set. Choose Log in to pick one.\n'; exit 1; }
        status=$("$cli" auth status "$provider" 2>&1 | head -n 3) || status=''
        printf '%s\n' "${status:-$provider}"
        [[ "$status" != *"logged out"* ]]
        ;;
    claude:run)
        repair_claude_onboarding
        if [[ -n "$session_id" ]]; then
            if [[ $# -eq 1 ]]; then
                exec "$cli" "${claude_flags[@]}" --session-id "$session_id" -- "$1"
            fi
            exec "$cli" "${claude_flags[@]}" --session-id "$session_id"
        fi
        exec "$cli" "${claude_flags[@]}"
        ;;
    claude:login)
        exec "$cli" auth login --claudeai
        ;;
    claude:resume)
        repair_claude_onboarding
        if [[ $# -eq 1 ]]; then
            exec "$cli" "${claude_flags[@]}" --resume "$session_id" -- "$1"
        fi
        exec "$cli" "${claude_flags[@]}" --resume "$session_id"
        ;;
    claude:status)
        exec "$cli" auth status --text
        ;;
    codex:run)
        if [[ $# -eq 1 ]]; then
            exec "$cli" "${codex_flags[@]}" -- "$1"
        fi
        exec "$cli" "${codex_flags[@]}"
        ;;
    codex:login)
        exec "$cli" login -c 'cli_auth_credentials_store="file"'
        ;;
    codex:resume)
        if [[ $# -eq 1 ]]; then
            exec "$cli" "${codex_flags[@]}" resume "$session_id" -- "$1"
        fi
        exec "$cli" "${codex_flags[@]}" resume "$session_id"
        ;;
    codex:status)
        exec "$cli" login status -c 'cli_auth_credentials_store="file"'
        ;;
esac
