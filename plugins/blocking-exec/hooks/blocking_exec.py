#!/usr/bin/env python3
"""PreToolUse hook for blocking all Bash commands until completion.

The hook runs the Bash command synchronously, records combined output to /tmp,
and rewrites the original Bash tool call to replay that output with the
command's exit code.
"""

from __future__ import annotations

import json
import os
import secrets
import shlex
import subprocess
import sys
from pathlib import Path


LOG_DIR = Path("/tmp/bx")
REPLAY_COMMAND = "bx"
SHELL_DISPLAY_ESCAPES = set("\\'\"`$;&|()<>*?[]{}!#~")


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


def replay_script_path() -> Path:
    plugin_root = os.environ.get("PLUGIN_ROOT")
    if plugin_root:
        return Path(plugin_root) / "scripts" / REPLAY_COMMAND
    return Path(__file__).resolve().parents[1] / "scripts" / REPLAY_COMMAND


def replay_command() -> str:
    source = replay_script_path()
    for raw_dir in os.environ.get("PATH", "").split(os.pathsep):
        if not raw_dir:
            continue
        directory = Path(raw_dir)
        candidate = directory / REPLAY_COMMAND
        try:
            if candidate.exists() or candidate.is_symlink():
                if candidate.resolve() == source.resolve():
                    return REPLAY_COMMAND
                return str(source)
            if directory.is_dir() and os.access(directory, os.W_OK | os.X_OK):
                candidate.symlink_to(source)
                return REPLAY_COMMAND
        except OSError:
            continue
    return str(source)


def display_command(command: str) -> str:
    result: list[str] = []
    for char in command:
        if char == "\n":
            result.append("\\n")
        elif char == "\r":
            result.append("\\r")
        elif char == "\t":
            result.append(" ")
        elif char in SHELL_DISPLAY_ESCAPES:
            result.append(f"\\{char}")
        else:
            result.append(char)
    return "".join(result)


def replacement_command(original_command: str, log_id: str, rc: int) -> str:
    return " ".join(
        [
            shlex.quote(replay_command()),
            str(int(rc)),
            shlex.quote(log_id),
            "--",
            display_command(original_command),
        ]
    )


def new_log_id() -> str:
    for _ in range(16):
        log_id = secrets.token_hex(4)
        if not (LOG_DIR / log_id).exists():
            return log_id
    return secrets.token_hex(8)


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
    log_id = new_log_id()
    log_path = LOG_DIR / log_id
    rc = run_blocking(command, command_cwd(payload), log_path)

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "updatedInput": {
                        "command": replacement_command(command, log_id, rc)
                    },
                }
            },
            ensure_ascii=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
