#!/usr/bin/env python3
"""Verify that `modelmoor run` handles SIGTERM and shuts down cleanly."""

from __future__ import annotations

import os
import pathlib
import pty
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time


READY_MARKER = b"ModelMoor is running. Press Ctrl-C to stop."


def unused_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def verify_help_output(binary: pathlib.Path) -> None:
    short = subprocess.run(
        [str(binary), "-h"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    long = subprocess.run(
        [str(binary), "--help"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    if short.returncode != 0 or long.returncode != 0:
        raise RuntimeError(
            f"help exited unexpectedly: -h={short.returncode}, --help={long.returncode}"
        )
    if short.stderr or long.stderr:
        raise RuntimeError("help unexpectedly wrote to stderr")
    if short.stdout != long.stdout:
        raise RuntimeError("-h and --help emitted different help text")
    if not short.stdout.endswith(b"\n") or b"\r" in short.stdout:
        raise RuntimeError("help did not use a final LF-terminated output document")
    if b"USAGE: modelmoor <subcommand>\n" not in short.stdout:
        raise RuntimeError("help did not preserve the expected usage line break")


def read_until(master: int, process: subprocess.Popen[bytes], timeout: float) -> bytes:
    output = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master], [], [], 0.05)
        if readable:
            try:
                output.extend(os.read(master, 65_536))
            except OSError:
                break
            if READY_MARKER in output:
                return bytes(output)
        if process.poll() is not None:
            break
    raise RuntimeError(
        f"CLI did not become ready; exit={process.poll()}, output={bytes(output)!r}"
    )


def process_snapshot() -> str:
    rows: list[str] = []
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            status = (entry / "status").read_text(encoding="utf-8", errors="replace")
            fields = {
                line.split(":", 1)[0]: line.split(":", 1)[1].strip()
                for line in status.splitlines()
                if ":" in line
            }
            command = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(
                "utf-8", errors="replace"
            )
            rows.append(
                f"pid={entry.name} ppid={fields.get('PPid', '?')} "
                f"state={fields.get('State', '?')} "
                f"sigign={fields.get('SigIgn', '?')} sigcgt={fields.get('SigCgt', '?')} "
                f"command={command}"
            )
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
    return "\n".join(sorted(rows))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: test-cli-signal.py /path/to/modelmoor", file=sys.stderr)
        return 2
    binary = pathlib.Path(sys.argv[1]).resolve()
    if not binary.is_file():
        print(f"CLI binary not found: {binary}", file=sys.stderr)
        return 2

    verify_help_output(binary)

    with tempfile.TemporaryDirectory(prefix="modelmoor-cli-signal-") as directory:
        environment = os.environ.copy()
        environment.update(
            {
                "MODELMOOR_CONFIG": os.path.join(directory, "config.json"),
                "MODELMOOR_USAGE": os.path.join(directory, "usage.jsonl"),
                "MODELMOOR_SECRET_BACKEND": "file",
                "MODELMOOR_SECRETS_FILE": os.path.join(directory, "secrets.json"),
                "XDG_RUNTIME_DIR": os.path.join(directory, "runtime"),
            }
        )
        initialized = subprocess.run(
            [
                str(binary),
                "init",
                "127.0.0.1",
                "--listen-port",
                str(unused_loopback_port()),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=10,
            check=False,
        )
        if initialized.returncode != 0:
            raise RuntimeError(
                f"CLI fixture initialization failed: {initialized.stderr!r}"
            )

        master, slave = pty.openpty()
        process: subprocess.Popen[bytes] | None = None
        try:
            process = subprocess.Popen(
                [str(binary), "run"],
                stdin=subprocess.DEVNULL,
                stdout=slave,
                stderr=slave,
                env=environment,
                start_new_session=True,
                close_fds=True,
            )
            output = read_until(master, process, timeout=10)
            os.kill(process.pid, signal.SIGTERM)
            try:
                return_code = process.wait(timeout=10)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(
                    "CLI received SIGTERM but did not exit; "
                    f"output={output!r}\nprocesses:\n{process_snapshot()}"
                ) from error
            if return_code != 0:
                raise RuntimeError(f"SIGTERM exited with status {return_code}")
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=1)
            os.close(master)
            os.close(slave)

    print("CLI contract passed: help formatting and foreground SIGTERM cleanup")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
