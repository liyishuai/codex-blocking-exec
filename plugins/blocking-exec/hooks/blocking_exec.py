#!/usr/bin/env python3
"""PreToolUse hook for blocking all Bash commands until completion.

The hook runs the Bash command synchronously, records combined output to /tmp,
and rewrites the original Bash tool call to replay that output with the
command's exit code.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path


LOG_DIR = Path(os.environ.get("BLOCKING_EXEC_LOG_DIR", "/tmp/blocking-exec"))


def run_blocking(command: str, cwd: str | None, log_path: Path) -> int:
    with log_path.open("wb") as log:
        try:
            proc = subprocess.Popen(
                ["bash", "-lc", command],
                cwd=cwd or None,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        except OSError as exc:
            log.write(f"\nfailed_to_start: {exc}\n".encode())
            return 127

        return proc.wait()


def replacement_command(log_path: Path, rc: int) -> str:
    return f"cat {shlex.quote(str(log_path))}; exit {int(rc)}"


def command_cwd(payload: dict) -> str | None:
    tool_input = payload.get("tool_input", {})
    if isinstance(tool_input, dict):
        for key in ("workdir", "cwd"):
            value = tool_input.get(key)
            if isinstance(value, str) and value:
                return value

    value = payload.get("cwd")
    if isinstance(value, str) and value:
        return value
    return None


def main() -> int:
    payload = json.load(sys.stdin)
    if payload.get("hook_event_name") != "PreToolUse":
        return 0
    if payload.get("tool_name") != "Bash":
        return 0

    command = payload.get("tool_input", {}).get("command")
    if not isinstance(command, str):
        return 0

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    job_id = f"{int(time.time())}-{os.getpid()}"
    log_path = LOG_DIR / f"{job_id}.log"
    rc = run_blocking(command, command_cwd(payload), log_path)

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "updatedInput": {"command": replacement_command(log_path, rc)},
                }
            },
            ensure_ascii=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
