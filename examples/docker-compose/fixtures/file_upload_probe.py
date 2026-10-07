"""Check upload destinations across the single-shot/streaming boundary in a live VM."""

import argparse
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime")
    parser.add_argument("machine")
    parser.add_argument("state_directory", type=Path)
    parser.add_argument("--image", required=True, help="Image to use for an additional prepared overlay")
    parser.add_argument("--guest-directory", action="append")
    args = parser.parse_args()
    directories = args.guest_directory or ["/tmp", "/workspace", "/opt"]
    token = uuid.uuid4().hex

    def run(*arguments):
        result = subprocess.run(
            [args.runtime, "machine", *arguments],
            check=True,
            capture_output=True,
            text=True,
            timeout=90,
        )
        return result.stdout.strip()

    agent_socket = Path(run("data-dir", "--name", args.machine)) / "agent.sock"

    def overlay_request(method):
        message = {"method": method, "workload_id": f"persistent-upload-probe-{token}"}
        if method == "prepare_overlay":
            message["image"] = args.image
        encoded = json.dumps(message).encode()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(90)
            connection.connect(str(agent_socket))
            connection.sendall(struct.pack(">I", len(encoded)) + encoded)

            def read_exact(size):
                data = bytearray()
                while len(data) < size:
                    chunk = connection.recv(size - len(data))
                    if not chunk:
                        raise RuntimeError("agent closed an incomplete response")
                    data.extend(chunk)
                return data

            reply_size = struct.unpack(">I", read_exact(4))[0]
            reply = json.loads(read_exact(reply_size))
            if reply["status"] != "ok":
                raise RuntimeError(f"{method} failed: {reply}")

    # Keep a separate overlay prepared so resolving a guest destination yields
    # an internal storage path distinct from the running workload's root. This
    # catches the false-success regression that a simple round trip can miss.
    overlay_request("prepare_overlay")
    try:
        verify_uploads(args, directories, token, run)
    finally:
        overlay_request("cleanup_overlay")


def verify_uploads(args, directories, token, run):
    args.state_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="verify-uploads-", dir=args.state_directory) as tmp:
        source = Path(tmp) / "source.bin"
        downloaded = Path(tmp) / "downloaded.bin"
        for size in [1 << 20, (1 << 20) + 1, (2 << 20) + 37]:
            payload = (bytes(range(256)) * ((size + 255) // 256))[:size]
            source.write_bytes(payload)
            expected = hashlib.sha256(payload).hexdigest()
            for directory in directories:
                guest_path = f"{directory}/smolvm-upload-probe-{token}.bin"
                try:
                    run("cp", "--mode", "600", "--uid", "65534", "--gid", "65534",
                        str(source), f"{args.machine}:{guest_path}")
                    # Inspect from the running workload, independently of the
                    # file API: an upload/download pair can agree on a wrong path.
                    digest = run("exec", "--name", args.machine, "--", "sha256sum", guest_path)
                    if digest.split()[0] != expected:
                        raise AssertionError(f"wrong contents at {guest_path}")
                    metadata = run("exec", "--name", args.machine, "--",
                                   "stat", "-c", "%a %u %g", guest_path)
                    if metadata != "600 65534 65534":
                        raise AssertionError(f"wrong permissions/ownership at {guest_path}: {metadata}")
                    run("cp", f"{args.machine}:{guest_path}", str(downloaded))
                    if downloaded.read_bytes() != payload:
                        raise AssertionError(f"download differs from uploaded bytes at {guest_path}")
                    print(f"  ok: {size}-byte upload visible at {directory}, metadata and download", flush=True)
                finally:
                    # Only this probe's unique file; never traverse directories.
                    run("exec", "--name", args.machine, "--", "rm", "-f", "--", guest_path)


if __name__ == "__main__":
    main()
