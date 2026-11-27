#!/usr/bin/env python3
"""Boot the ARM64 guest and exercise either its serial shell or real guest PTY."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import select
import shutil
import struct
import subprocess
import tempfile
import time


MAGIC = b"DSBP"
PROTOCOL_VERSION = 1
HEADER_BYTES = 16
MAX_FRAME_BYTES = 64 * 1024
FRAME_CREATE = 1
FRAME_INPUT = 2
FRAME_RESIZE = 3
FRAME_CLOSE = 4
FRAME_OUTPUT = 0x81
FRAME_EXIT = 0x82
FRAME_ERROR = 0x83
FRAME_READY = 0x84

SHELL_BOOT_MARKER = b"DS Bot ARM64 Linux guest (Alpine Linux, BusyBox ash)."
PTY_BOOT_MARKER = b"DS Bot ARM64 Linux guest PTY agent protocol v1."


class SerialLink:
    def __init__(self, connection) -> None:
        self.connection = connection
        self.raw = bytearray()
        self.buffer = bytearray()

    def _receive(self, deadline: float) -> None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("ARM64 guest serial interaction timed out")
        self.connection.settimeout(min(0.25, remaining))
        try:
            chunk = self.connection.recv(64 * 1024)
        except TimeoutError:
            return
        if not chunk:
            raise RuntimeError("QEMU closed the ARM64 guest serial channel")
        self.raw.extend(chunk)
        self.buffer.extend(chunk)

    def wait_for_text(self, marker: bytes, deadline: float) -> None:
        while marker not in self.raw:
            self._receive(deadline)

    def send_frame(self, frame_type: int, session_id: int, payload: bytes = b"") -> None:
        if len(payload) > MAX_FRAME_BYTES:
            raise RuntimeError("Refusing an oversized guest PTY protocol frame")
        self.connection.sendall(
            struct.pack(">4sHHII", MAGIC, PROTOCOL_VERSION, frame_type, session_id, len(payload)) + payload
        )

    def receive_frame(self, deadline: float) -> tuple[int, int, bytes]:
        while True:
            offset = self.buffer.find(MAGIC)
            if offset < 0:
                if len(self.buffer) > len(MAGIC) - 1:
                    del self.buffer[:-(len(MAGIC) - 1)]
            elif offset:
                del self.buffer[:offset]
            if len(self.buffer) >= HEADER_BYTES:
                magic, version, frame_type, session_id, length = struct.unpack_from(">4sHHII", self.buffer)
                if magic != MAGIC or version != PROTOCOL_VERSION or length > MAX_FRAME_BYTES:
                    del self.buffer[0]
                    continue
                total = HEADER_BYTES + length
                if len(self.buffer) >= total:
                    payload = bytes(self.buffer[HEADER_BYTES:total])
                    del self.buffer[:total]
                    return frame_type, session_id, payload
            self._receive(deadline)


class ProcessSerialConnection:
    """Expose QEMU's stdio serial port with the socket methods used by SerialLink."""

    def __init__(self, process: subprocess.Popen[bytes]) -> None:
        if process.stdin is None or process.stdout is None:
            raise RuntimeError("QEMU stdio serial pipes were not created")
        self.process = process
        self.timeout = 0.25
        self.closed = False

    def settimeout(self, seconds: float) -> None:
        self.timeout = seconds

    def recv(self, size: int) -> bytes:
        if self.closed:
            return b""
        assert self.process.stdout is not None
        readable, _, _ = select.select([self.process.stdout.fileno()], [], [], self.timeout)
        if not readable:
            raise TimeoutError
        return os.read(self.process.stdout.fileno(), size)

    def sendall(self, data: bytes) -> None:
        if self.closed:
            raise RuntimeError("QEMU stdio serial channel is closed")
        assert self.process.stdin is not None
        descriptor = self.process.stdin.fileno()
        offset = 0
        while offset < len(data):
            _, writable, _ = select.select([], [descriptor], [], self.timeout)
            if not writable:
                raise TimeoutError("QEMU stdio serial write timed out")
            offset += os.write(descriptor, data[offset:])

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        if self.process.stdin is not None:
            self.process.stdin.close()
        if self.process.stdout is not None:
            self.process.stdout.close()


def output_until_marker(link: SerialLink, session_id: int, marker: bytes, timeout: int) -> bytes:
    return output_until_markers(link, session_id, (marker,), timeout)


def output_until_markers(
    link: SerialLink, session_id: int, markers: tuple[bytes, ...], timeout: int
) -> bytes:
    deadline = time.monotonic() + timeout
    output = bytearray()
    while not any(marker in output for marker in markers):
        frame_type, frame_session, payload = link.receive_frame(deadline)
        if frame_type == FRAME_ERROR:
            raise RuntimeError(f"Guest PTY agent error: {payload.decode('utf-8', 'replace')}")
        if frame_session != session_id:
            continue
        if frame_type == FRAME_EXIT:
            labels = ", ".join(marker.decode("ascii") for marker in markers)
            raise RuntimeError(f"Guest shell exited before emitting {labels}")
        if frame_type == FRAME_OUTPUT:
            output.extend(payload)
    return bytes(output)


def wait_for_frame(link: SerialLink, frame_type_expected: int, session_id: int, timeout: int) -> bytes:
    deadline = time.monotonic() + timeout
    while True:
        frame_type, frame_session, payload = link.receive_frame(deadline)
        if frame_type == FRAME_ERROR:
            raise RuntimeError(f"Guest PTY agent error: {payload.decode('utf-8', 'replace')}")
        if frame_type == frame_type_expected and frame_session == session_id:
            return payload


def shell_marker(marker: bytes) -> bytes:
    text = marker.decode("ascii")
    split = len(text) // 2
    # PTY input is echoed. Adjacent quoted words make the shell print the
    # marker only after execution, while the echoed source contains a quote
    # between its halves and cannot satisfy the smoke check.
    return b"'" + text[:split].encode("ascii") + b"''" + text[split:].encode("ascii") + b"'"


def marker_command(marker: bytes) -> bytes:
    return b"printf '%s\\n' " + shell_marker(marker) + b"\n"


def smoke_serial_shell(link: SerialLink, timeout: int) -> None:
    link.wait_for_text(SHELL_BOOT_MARKER, time.monotonic() + timeout)
    serial_marker = b"DS_BOT_SERIAL_SHELL_INPUT_OK"
    link.connection.sendall(marker_command(serial_marker))
    deadline = time.monotonic() + timeout
    while serial_marker not in link.raw:
        link._receive(deadline)
    print("ARM64 guest reached its serial shell and accepted an interactive command.")


def smoke_guest_pty(link: SerialLink, timeout: int) -> None:
    link.wait_for_text(PTY_BOOT_MARKER, time.monotonic() + timeout)
    wait_for_frame(link, FRAME_READY, 0, timeout)
    session_id = 0xD5B07001
    link.send_frame(FRAME_CREATE, session_id, struct.pack(">HH", 24, 80))
    wait_for_frame(link, FRAME_READY, session_id, timeout)

    input_marker = b"DS_BOT_GUEST_PTY_INPUT_OK"
    link.send_frame(FRAME_INPUT, session_id, marker_command(input_marker))
    output_until_marker(link, session_id, input_marker, timeout)

    job_control_marker = b"DS_BOT_GUEST_PTY_JOB_CONTROL_OK"
    job_control_failure = b"DS_BOT_GUEST_PTY_JOB_CONTROL_FAIL"
    job_control_command = (
        b"if set -o | grep -Eq '^monitor[[:space:]]+on$'; then "
        b"printf '%s\\n' " + shell_marker(job_control_marker) + b"; else "
        b"printf '%s\\n' " + shell_marker(job_control_failure) + b"; fi\n"
    )
    link.send_frame(FRAME_INPUT, session_id, job_control_command)
    job_control_output = output_until_markers(
        link, session_id, (job_control_marker, job_control_failure), timeout
    )
    if job_control_marker not in job_control_output:
        raise RuntimeError("Guest shell did not enable PTY job control")

    link.send_frame(FRAME_RESIZE, session_id, struct.pack(">HH", 42, 100))
    resize_marker = b"DS_BOT_GUEST_PTY_RESIZE_OK"
    link.send_frame(FRAME_INPUT, session_id, b"stty size; " + marker_command(resize_marker))
    resize_output = output_until_marker(link, session_id, resize_marker, timeout)
    if b"42 100" not in resize_output:
        raise RuntimeError("Guest PTY did not apply the requested terminal size")

    link.send_frame(FRAME_INPUT, session_id, b"sleep 20\n")
    time.sleep(0.35)
    link.send_frame(FRAME_INPUT, session_id, b"\x03")
    cancel_marker = b"DS_BOT_GUEST_PTY_CANCEL_OK"
    link.send_frame(FRAME_INPUT, session_id, marker_command(cancel_marker))
    output_until_marker(link, session_id, cancel_marker, timeout)

    link.send_frame(FRAME_CLOSE, session_id)
    payload = wait_for_frame(link, FRAME_EXIT, session_id, timeout)
    if len(payload) != 4:
        raise RuntimeError("Guest PTY agent returned an invalid exit status frame")
    print("ARM64 guest PTY passed input/output, job control, resize, interrupt, and close checks.")


def smoke_guest_pty_isolation(link: SerialLink, timeout: int) -> None:
    first_session = 0xD5B07001
    second_session = 0xD5B07002
    for session_id in (first_session, second_session):
        link.send_frame(FRAME_CREATE, session_id, struct.pack(">HH", 24, 80))
        wait_for_frame(link, FRAME_READY, session_id, timeout)

    secret = b"DS_BOT_GUEST_PTY_PRIVATE_FILE_SECRET"
    first_directory = f"/home/dsbot/.sessions/{first_session:08x}".encode("ascii")
    created_marker = b"DS_BOT_GUEST_PTY_PRIVATE_FILE_CREATED"
    first_command = (
        b"printf '%s\\n' " + shell_marker(secret) + b" > private.txt; "
        + marker_command(created_marker)
    )
    link.send_frame(FRAME_INPUT, first_session, first_command)
    output_until_marker(link, first_session, created_marker, timeout)

    isolation_marker = b"DS_BOT_GUEST_PTY_ISOLATION_OK"
    isolation_failure = b"DS_BOT_GUEST_PTY_ISOLATION_FAIL"
    second_command = (
        b"if cat " + first_directory + b"/private.txt 2>/dev/null; then "
        b"printf '%s\\n' " + shell_marker(isolation_failure) + b"; else "
        b"printf '%s\\n' " + shell_marker(isolation_marker) + b"; fi\n"
    )
    link.send_frame(FRAME_INPUT, second_session, second_command)
    second_output = output_until_markers(
        link, second_session, (isolation_marker, isolation_failure), timeout
    )
    if secret in second_output or isolation_failure in second_output:
        raise RuntimeError("One guest PTY session could read another session's private workspace")
    if isolation_marker not in second_output:
        raise RuntimeError("Guest PTY workspace isolation check did not finish")

    quota_marker = b"DS_BOT_GUEST_PTY_WORKSPACE_QUOTA_OK"
    link.send_frame(FRAME_INPUT, second_session, b"df -k /home/dsbot/.sessions; " + marker_command(quota_marker))
    quota_output = output_until_marker(link, second_session, quota_marker, timeout)
    if b"131072" not in quota_output:
        raise RuntimeError("Guest PTY workspaces are missing the configured 128 MiB tmpfs quota")

    for session_id in (second_session, first_session):
        link.send_frame(FRAME_CLOSE, session_id)
        payload = wait_for_frame(link, FRAME_EXIT, session_id, timeout)
        if len(payload) != 4:
            raise RuntimeError("Guest PTY agent returned an invalid isolation-session exit status")
    print("ARM64 guest PTY isolated two concurrent shell workspaces.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--guest-dir", type=pathlib.Path, required=True)
    parser.add_argument("--kernel", type=pathlib.Path)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()

    guest_dir = args.guest_dir.resolve()
    kernel = args.kernel.resolve() if args.kernel else guest_dir / "vmlinuz-virt"
    qemu = shutil.which("qemu-system-aarch64")
    if not qemu:
        raise SystemExit("qemu-system-aarch64 is not installed")
    if not kernel.is_file():
        raise SystemExit(f"Guest kernel is missing: {kernel}")
    initrd = guest_dir / "rootfs.cpio.gz"
    if not initrd.is_file():
        raise SystemExit(f"Guest boot input is missing: {initrd}")
    manifest_path = guest_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.is_file() else {}
    has_pty_agent = isinstance(manifest.get("guestPTYAgent"), dict)
    marker = PTY_BOOT_MARKER if has_pty_agent else SHELL_BOOT_MARKER

    serial_log = guest_dir / "serial-smoke.log"
    serial_log.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="dsbot-uart-") as temporary:
        qemu_stderr_path = pathlib.Path(temporary) / "qemu-stderr.log"
        command = [
            qemu,
            "-machine", "virt,gic-version=2",
            "-cpu", "max",
            "-m", "512M",
            "-smp", "2",
            "-accel", "tcg,thread=single",
            "-kernel", str(kernel),
            "-initrd", str(initrd),
            "-append", "console=ttyAMA0,115200 rdinit=/init panic=10",
            "-display", "none",
            "-monitor", "none",
            "-serial", "stdio",
            "-no-reboot",
        ]
        qemu_stderr = qemu_stderr_path.open("wb")
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=qemu_stderr, bufsize=0)
        connection = ProcessSerialConnection(process)
        link: SerialLink | None = None
        deadline = time.monotonic() + max(1, args.timeout)
        try:
            link = SerialLink(connection)
            link.wait_for_text(marker, deadline)
            if has_pty_agent:
                smoke_guest_pty(link, args.timeout)
                smoke_guest_pty_isolation(link, args.timeout)
            else:
                smoke_serial_shell(link, args.timeout)
        except Exception:
            boot_text = link.raw.split(MAGIC, 1)[0] if link else b""
            print("Guest serial output before smoke failure:")
            print(boot_text[-8192:].decode("utf-8", "replace") if boot_text else "<no guest serial bytes>")
            qemu_status = process.poll()
            if qemu_status is None:
                print("QEMU was still running when the serial channel closed.")
            else:
                print(f"QEMU exited with status {qemu_status}.")
            qemu_stderr.flush()
            detail = qemu_stderr_path.read_text(encoding="utf-8", errors="replace")[-4096:]
            print("QEMU stderr:")
            print(detail if detail else "<empty>")
            raise
        finally:
            connection.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            qemu_stderr.close()
            serial_log.write_bytes(link.raw if link else b"")

    raw = serial_log.read_bytes()
    boot_text = raw.split(MAGIC, 1)[0] if has_pty_agent else raw
    print(boot_text[-8192:].decode("utf-8", "replace"), end="")
    if marker not in raw:
        raise SystemExit(f"ARM64 guest did not reach its boot marker within {args.timeout}s")


if __name__ == "__main__":
    main()
