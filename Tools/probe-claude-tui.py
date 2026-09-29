#!/usr/bin/env python3
"""Classify Claude's initial terminal state without logging terminal output."""

import os
import pty
import select
import signal
import sys
import time

launcher = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "agent-launcher.sh")
pid, fd = pty.fork()
if pid == 0:
    os.chdir(os.path.expanduser("~"))
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLORTERM"] = "truecolor"
    os.execv("/bin/bash", ["/bin/bash", launcher, "claude", "run", "--ax-screen-reader"])

captured = bytearray()
deadline = time.monotonic() + 12
try:
    while time.monotonic() < deadline and len(captured) < 65536:
        if not select.select([fd], [], [], 0.5)[0]:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        captured.extend(chunk)
        if b"Opening browser to sign in" in captured:
            break
finally:
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    for _ in range(10):
        try:
            finished, _ = os.waitpid(pid, os.WNOHANG)
            if finished:
                break
        except ChildProcessError:
            break
        time.sleep(0.1)
    else:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    os.close(fd)

text = captured.decode("utf-8", "replace")
flags = {
    "browser_sign_in": "Opening browser to sign in" in text,
    "onboarding": "onboarding" in text.lower() or "choose a theme" in text.lower(),
    "trust_prompt": "trust" in text.lower() and ("folder" in text.lower() or "directory" in text.lower()),
    "claude_header": "Claude Code" in text,
}
print({"bytes_captured": len(captured), **flags})
