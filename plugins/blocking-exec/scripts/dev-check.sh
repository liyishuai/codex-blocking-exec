#!/usr/bin/env bash
set -euo pipefail

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook="$plugin_root/hooks/blocking_exec.py"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/blocking-exec-test.XXXXXX")

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

python3 -m py_compile "$hook"

python3 - "$hook" "$plugin_root" "$tmp_dir" <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

hook = sys.argv[1]
plugin_root = sys.argv[2]
tmp_dir = sys.argv[3]
path_dir = os.path.join(tmp_dir, "path")
os.makedirs(path_dir, exist_ok=True)
test_env = os.environ.copy()
test_env["PATH"] = f"{path_dir}:{test_env.get('PATH', '')}"
created_logs = []

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
    env=test_env,
    check=False,
)
if hook_run.returncode != 0:
    raise SystemExit(hook_run.stderr)

result = json.loads(hook_run.stdout)
specific = result["hookSpecificOutput"]
if specific["permissionDecision"] != "allow":
    raise SystemExit(f"unexpected hook decision: {specific!r}")

replacement = specific["updatedInput"]["command"]
replacement_args = shlex.split(replacement)
if len(replacement_args) != 8:
    raise SystemExit(f"replacement has wrong arity: {replacement!r}")
if replacement_args[:2] != ["bx", "7"]:
    raise SystemExit(f"replacement is not a replay command: {replacement!r}")
if "/" in replacement_args[2]:
    raise SystemExit(f"replacement includes a path instead of file id: {replacement!r}")
if replacement_args[3:] != ["--", "printf", "blocking-exec;", "exit", "7"]:
    raise SystemExit(f"replacement does not include display command: {replacement!r}")
created_logs.append(Path("/tmp/bx") / replacement_args[2])
if "'printf blocking-exec; exit 7'" in replacement or "/tmp/bx/" in replacement:
    raise SystemExit(f"replacement regressed to polluted replay: {replacement!r}")
if not os.path.islink(os.path.join(path_dir, "bx")):
    raise SystemExit("hook did not expose bx on PATH")
final = subprocess.run(
    ["bash", "-lc", replacement],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    cwd=plugin_root,
    env=test_env,
    check=False,
)
if final.returncode != 7 or final.stdout != "blocking-exec" or final.stderr:
    raise SystemExit(
        "bad replay: "
        f"rc={final.returncode} stdout={final.stdout!r} stderr={final.stderr!r}"
    )

print("blocking-exec dev check: ok")

cwd_payload = {
    "session_id": "dev-check-session",
    "turn_id": "dev-check-turn",
    "cwd": "/",
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_use_id": "dev-check-cwd",
    "tool_input": {"command": "pwd", "workdir": plugin_root},
    "model": "dev-check",
}
hook_run = subprocess.run(
    [sys.executable, hook],
    input=json.dumps(cwd_payload),
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    cwd="/",
    env=test_env,
    check=False,
)
if hook_run.returncode != 0:
    raise SystemExit(hook_run.stderr)

result = json.loads(hook_run.stdout)
replacement = result["hookSpecificOutput"]["updatedInput"]["command"]
replacement_args = shlex.split(replacement)
if len(replacement_args) != 5:
    raise SystemExit(f"cwd replacement has wrong arity: {replacement!r}")
if replacement_args[:2] != ["bx", "0"]:
    raise SystemExit(f"cwd replacement lost replay/original command: {replacement!r}")
if "/" in replacement_args[2] or replacement_args[3:] != ["--", "pwd"]:
    raise SystemExit(f"cwd replacement has bad replay args: {replacement!r}")
created_logs.append(Path("/tmp/bx") / replacement_args[2])
final = subprocess.run(
    ["bash", "-lc", replacement],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    cwd="/",
    env=test_env,
    check=False,
)
if final.returncode != 0 or final.stdout.strip() != plugin_root or final.stderr:
    raise SystemExit(
        "bad cwd replay: "
        f"rc={final.returncode} stdout={final.stdout!r} stderr={final.stderr!r}"
    )

print("blocking-exec cwd check: ok")

for log_path in created_logs:
    try:
        log_path.unlink()
    except FileNotFoundError:
        pass
PY
