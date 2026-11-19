"""First Finder attach over a cold, bandwidth-limited WebDAV mount (macOS GUI session)."""
import ctypes
import filecmp
import os
from pathlib import Path
import select
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid


class GuestConnection(socketserver.BaseRequestHandler):
    def handle(self):
        with socket.socket(socket.AF_UNIX) as host:
            host.connect(str(self.server.endpoint))
            try:
                while True:
                    ready, _, _ = select.select([self.request, host], [], [], 240)
                    if not ready:
                        return
                    for source in ready:
                        data = source.recv(65536)
                        if not data:
                            return
                        if source is host:
                            # Keep the guest cache cold until the native mounter asks for the trailer.
                            time.sleep(len(data) / (8 * 1024 * 1024))
                            self.request.sendall(data)
                        else:
                            host.sendall(data)
            except (BrokenPipeError, ConnectionResetError):
                pass  # webdavfs can close its GET and resume it on another connection


def test_first_mount(lib, tmp):
    source, shared, mount = (tmp / name for name in ("source", "shared", "dav"))
    for folder in (source, shared, mount):
        folder.mkdir()
    volume = Path("/Volumes") / ("HengeTest-" + uuid.uuid4().hex[:12])
    with (source / "payload").open("wb") as payload:
        for _ in range(64):
            payload.write(os.urandom(1024 * 1024))
    subprocess.run(["hdiutil", "create", "-volname", volume.name, "-fs", "HFS+", "-format", "UDZO",
                    "-srcfolder", source, shared / "Installer.dmg"], check=True, timeout=120)

    endpoint = tmp / "share.sock"
    lib.hv_share_start.argtypes = [ctypes.c_char_p] * 3
    assert lib.hv_share_start(bytes(shared), bytes(endpoint), None) == 0
    with socketserver.ThreadingTCPServer(("127.0.0.1", 0), GuestConnection) as server:
        server.endpoint = endpoint
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{server.server_address[1]}/"
            subprocess.run(["/sbin/mount_webdav", "-S", url, mount], check=True, timeout=30)
            # LaunchServices uses DiskImageMounter and its separate IO daemon, as Finder does.
            subprocess.run(["open", "-g", mount / "Installer.dmg"], check=True, timeout=30)
            deadline = time.monotonic() + 240
            while not (volume / "payload").is_file():
                if time.monotonic() >= deadline:
                    raise AssertionError("The first Finder open did not mount the shared disk image")
                time.sleep(0.5)
            assert filecmp.cmp(source / "payload", volume / "payload", shallow=False)
        finally:
            try:
                if volume.is_mount():
                    subprocess.run(["hdiutil", "detach", volume], check=True, timeout=30)
            finally:
                if mount.is_mount():
                    subprocess.run(["diskutil", "unmount", "force", mount], check=True, timeout=30)
                server.shutdown()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
        test_first_mount(ctypes.CDLL(str(Path(sys.argv[1]).resolve())), Path(tmp))
    print("First Finder open mounted the shared disk image and verified its contents")
