#!/usr/bin/env bash
set -euo pipefail

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook="$plugin_root/hooks/blocking_exec.py"
log_dir=$(mktemp -d "${TMPDIR:-/tmp}/blocking-exec-test.XXXXXX")

cleanup() {
  rm -rf "$log_dir"
}
trap cleanup EXIT

python3 -m py_compile "$hook"

BLOCKING_EXEC_LOG_DIR="$log_dir" python3 - "$hook" "$plugin_root" <<'PY'
import json
import os
import subprocess
import sys

hook = sys.argv[1]
plugin_root = sys.argv[2]

payload = {
    "session_id": "dev-check-session",
    "turn_id": "dev-check-turn",
    "cwd": plugin_root,
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_use_id": "dev-check-tool",
    "tool_input": {"command": "printf blocking-exec; exit 7"},
    "model": "dev-check",
}

hook_run = subprocess.run(
    [sys.executable, hook],
    input=json.dumps(payload),
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    cwd=plugin_root,
    env=os.environ.copy(),
    check=False,
)
if hook_run.returncode != 0:
    raise SystemExit(hook_run.stderr)

result = json.loads(hook_run.stdout)
specific = result["hookSpecificOutput"]
if specific["permissionDecision"] != "allow":
    raise SystemExit(f"unexpected hook decision: {specific!r}")

replacement = specific["updatedInput"]["command"]
final = subprocess.run(
    ["bash", "-lc", replacement],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    cwd=plugin_root,
    check=False,
)
if final.returncode != 7 or final.stdout != "blocking-exec" or final.stderr:
    raise SystemExit(
        "bad replay: "
        f"rc={final.returncode} stdout={final.stdout!r} stderr={final.stderr!r}"
    )

print("blocking-exec dev check: ok")
PY
