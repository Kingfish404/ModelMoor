#!/usr/bin/env python3
"""Exercise modelmoor-tui in a PTY and verify graceful terminal restoration."""

from __future__ import annotations

import fcntl
import os
import pathlib
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


ENTER_ALTERNATE_SCREEN = b"\x1b[?1049h"
LEAVE_ALTERNATE_SCREEN = b"\x1b[?1049l"
SHOW_CURSOR = b"\x1b[?25h"
ANSI_CSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")


def set_size(descriptor: int, columns: int, rows: int) -> None:
    fcntl.ioctl(descriptor, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


def read_until(
    master: int,
    process: subprocess.Popen[bytes],
    marker: bytes,
    timeout: float,
    *,
    visible: bool = False,
) -> bytes:
    output = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master], [], [], 0.05)
        if readable:
            try:
                output.extend(os.read(master, 65_536))
            except OSError:
                break
            haystack = ANSI_CSI.sub(b"", output) if visible else output
            if marker in haystack:
                return bytes(output)
        if process.poll() is not None:
            break
    raise RuntimeError(
        f"TUI did not emit {marker!r} before exit/timeout; exit={process.poll()}; "
        f"tail={bytes(output[-500:])!r}"
    )


def drain(master: int, process: subprocess.Popen[bytes], timeout: float) -> bytes:
    output = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master], [], [], 0.05)
        if readable:
            try:
                output.extend(os.read(master, 65_536))
            except OSError:
                pass
        if process.poll() is not None:
            while True:
                readable, _, _ = select.select([master], [], [], 0)
                if not readable:
                    return bytes(output)
                try:
                    output.extend(os.read(master, 65_536))
                except OSError:
                    return bytes(output)
        time.sleep(0.01)
    raise RuntimeError("TUI did not exit within the terminal restoration timeout")


def run_case(
    binary: pathlib.Path,
    action: str,
    initial_size: tuple[int, int] = (80, 24),
    resize_to: tuple[tuple[int, int], ...] = (),
    ascii_mode: bool = False,
    shell_smoke: bool = False,
    subscription_shell_smoke: bool = False,
) -> None:
    master, slave = pty.openpty()
    process: subprocess.Popen[bytes] | None = None
    try:
        set_size(slave, *initial_size)
        original_settings = termios.tcgetattr(slave)
        with tempfile.TemporaryDirectory(prefix="modelmoor-tui-terminal-") as directory:
            environment = os.environ.copy()
            environment.update(
                {
                    "TERM": "xterm-256color",
                    "MODELMOOR_CONFIG": os.path.join(directory, "config.json"),
                    "MODELMOOR_USAGE": os.path.join(directory, "usage.jsonl"),
                }
            )
            if ascii_mode:
                environment["MODELMOOR_TUI_ASCII"] = "1"
            process = subprocess.Popen(
                [str(binary)],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                env=environment,
                start_new_session=True,
                close_fds=True,
            )
            output = bytearray(read_until(master, process, ENTER_ALTERNATE_SCREEN, 5))

            if shell_smoke:
                # Tab leaves the initially focused shell, then ':' must bring
                # it back. The visible feedback line proves command entry and
                # submission work rather than merely rendering the prompt.
                os.write(master, b"\t:status\r")
                output.extend(
                    read_until(master, process, b"OK: SSH 0 | API 0", 5, visible=True)
                )
                # Help is a normal, persistent tab. Confirm the command-specific
                # feedback rather than matching the page text, which may already
                # be buffered in the initial frame on UnixDriver.
                os.write(master, b"help\r")
                output.extend(
                    read_until(master, process, b"OK: Help pane selected", 5, visible=True)
                )

            if subscription_shell_smoke:
                # Exercise the subscription command path without requiring an
                # external proxy service or real provider credentials. It
                # opens the persistent Subscriptions tab rather than a dialog.
                os.write(master, b"subs accounts\r")
                output.extend(
                    read_until(master, process, b"OK: Subscriptions pane selected", 5, visible=True)
                )
                # UnixDriver focuses the selected read-only pane when the tab
                # changes. Return focus to the shell before the final Control-C
                # so the termination assertion is independent of that policy.
                os.write(master, b":\r")
                time.sleep(0.2)

            for columns, rows in resize_to:
                set_size(slave, columns, rows)
                os.kill(process.pid, signal.SIGWINCH)
                time.sleep(0.05)

            if action == "control-c":
                os.write(master, b"\x03")
            elif action == "sigint":
                os.kill(process.pid, signal.SIGINT)
            elif action == "sigterm":
                os.kill(process.pid, signal.SIGTERM)
            else:
                raise ValueError(f"Unknown action: {action}")

            output.extend(drain(master, process, 5))
            return_code = process.wait(timeout=1)
            restored_settings = termios.tcgetattr(slave)

        if return_code != 0:
            raise RuntimeError(f"{action} exited with status {return_code}")
        if LEAVE_ALTERNATE_SCREEN not in output:
            raise RuntimeError(f"{action} did not leave the alternate screen")
        if SHOW_CURSOR not in output:
            raise RuntimeError(f"{action} did not restore the cursor")
        if restored_settings != original_settings:
            raise RuntimeError(f"{action} did not restore the original terminal mode")
        if any(byte >= 0x80 for byte in output):
            raise RuntimeError("TUI emitted non-ASCII bytes on the main terminal surface")
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=1)
        os.close(master)
        os.close(slave)


def run_non_tty_cases(binary: pathlib.Path) -> None:
    with tempfile.TemporaryDirectory(prefix="modelmoor-tui-pipe-") as directory:
        environment = os.environ.copy()
        environment.update(
            {
                "MODELMOOR_CONFIG": os.path.join(directory, "config.json"),
                "MODELMOOR_USAGE": os.path.join(directory, "usage.jsonl"),
            }
        )
        healthy = subprocess.run(
            [str(binary)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=10,
            check=False,
        )
        if healthy.returncode != 0:
            raise RuntimeError(
                f"non-TTY snapshot exited with {healthy.returncode}: {healthy.stderr!r}"
            )
        if b"ModelMoor snapshot\n" not in healthy.stdout:
            raise RuntimeError("non-TTY mode did not emit the stable snapshot header")
        if b"\x1b" in healthy.stdout or b"\x1b" in healthy.stderr:
            raise RuntimeError("non-TTY mode emitted terminal escape sequences")

        pathlib.Path(environment["MODELMOOR_CONFIG"]).write_text("{invalid", encoding="utf-8")
        broken = subprocess.run(
            [str(binary)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=10,
            check=False,
        )
        if broken.returncode == 0:
            raise RuntimeError("invalid non-TTY configuration incorrectly exited with status 0")
        if not broken.stderr.startswith(b"modelmoor-tui: "):
            raise RuntimeError("invalid non-TTY configuration did not emit a stable error prefix")
        if b"\x1b" in broken.stdout or b"\x1b" in broken.stderr:
            raise RuntimeError("non-TTY failure emitted terminal escape sequences")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: test-tui-terminal.py /path/to/modelmoor-tui", file=sys.stderr)
        return 2
    binary = pathlib.Path(sys.argv[1]).resolve()
    if not binary.is_file():
        print(f"TUI binary not found: {binary}", file=sys.stderr)
        return 2

    run_non_tty_cases(binary)
    for action, initial_size, resize_to, ascii_mode in [
        ("control-c", (80, 24), (), False),
        ("sigint", (80, 24), (), False),
        ("sigterm", (80, 24), ((40, 10), (120, 40)), False),
        ("control-c", (40, 10), (), True),
    ]:
        run_case(
            binary,
            action,
            initial_size=initial_size,
            resize_to=resize_to,
            ascii_mode=ascii_mode,
        )
    run_case(binary, "control-c", shell_smoke=True, subscription_shell_smoke=True)
    print(
        "TUI process contract passed: non-TTY success/failure, Control-C, "
        "SIGINT, SIGTERM, 80x24 -> 40x10 -> 120x40 resize, ASCII surface, shell input, Help pane, subscription shell"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
