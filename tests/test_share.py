"""Exercise the WebDAV endpoint Finder uses, including host edits between guest requests."""
import ctypes
from concurrent.futures import ThreadPoolExecutor
import http.client
import os
from pathlib import Path
import socket
import sys
import tempfile
import xml.etree.ElementTree as ET


def request(endpoint, method, body=b"", path="/sample", **headers):
    conn = http.client.HTTPConnection("localhost", timeout=5)
    try:
        conn.sock = socket.socket(socket.AF_UNIX)
        conn.sock.settimeout(conn.timeout)
        conn.sock.connect(str(endpoint))
        conn.request(method, path, body, headers)
        response = conn.getresponse()
        return response.status, response.headers, response.read()
    finally:
        conn.close()

def test_battery(lib, endpoint):
    lib.hv_share_set_battery.argtypes = [ctypes.c_int] * 3
    lib.hv_share_set_clipboard.argtypes = [ctypes.c_char_p]

    def poll(clipboard, revision=None):
        path = f"/.henge/clipboard?since={clipboard}"
        if revision is not None:
            path += f"&battery={revision}"
        status, headers, body = request(endpoint, "GET", path=path)
        battery = list(map(int, headers["X-Henge-Battery"].split()))
        return status, int(headers["X-Henge-Seq"]), battery, body

    status, seq, initial, body = poll(2**63 - 1, 0)
    assert (status, body, initial[1:]) == (204, b"", [-1, 0, 0])
    with ThreadPoolExecutor(max_workers=1) as worker:
        pending = worker.submit(poll, seq, initial[0])
        lib.hv_share_set_battery(74, 1, 1)
        status, clip_seq, current, body = pending.result(timeout=6)
        assert (status, clip_seq, current[1:], body) == (204, seq, [74, 1, 1], b"")
        assert current[0] != initial[0]
        lib.hv_share_set_battery(74, 1, 1)
        assert poll(seq, 0)[2] == current

        legacy = worker.submit(poll, seq)
        lib.hv_share_set_battery(74, 2, 0)  # plugging in at the same percentage
        lib.hv_share_set_clipboard(b"guest paste")
        status, seq, charging, body = legacy.result(timeout=6)
        assert (status, charging[1:], body) == (200, [74, 2, 0], b"guest paste")
        assert poll(seq - 1, current[0]) == (200, seq, charging, b"guest paste")
        lib.hv_share_set_battery(100, 3, 0)
        assert poll(seq, charging[0])[2][1:] == [100, 3, 0]
        lib.hv_share_set_battery(-1, 0, 0)
        assert poll(seq, 0)[2][1:] == [-1, 0, 0]


def test_share(root, endpoint):
    sample = root / "sample"
    sample.write_bytes(b"one")
    second = 1_700_000_000 * 10**9
    os.utime(sample, ns=(second, second + 100_000_000))
    status, headers, data = request(endpoint, "GET")
    assert (status, data, headers["Cache-Control"]) == (200, b"one", "no-cache")
    first = headers["ETag"]
    assert request(endpoint, "GET", **{"If-Modified-Since": headers["Last-Modified"]})[0] == 304
    assert request(endpoint, "HEAD", **{"If-None-Match": "W/" + first})[0] == 304

    sample.write_bytes(b"two")
    os.utime(sample, ns=(second, second + 900_000_000))
    status, headers, data = request(endpoint, "GET", **{"If-None-Match": first,
                                                       "If-Modified-Since": headers["Last-Modified"]})
    assert (status, data) == (200, b"two")
    current = headers["ETag"]
    assert current != first
    for stale in [first, "W/" + current]:
        assert request(endpoint, "PUT", b"old", **{"If-Match": stale})[0] == 412
        assert sample.read_bytes() == b"two"
    assert request(endpoint, "PUT", b"new", **{"If-Match": first + ", " + current})[0] == 204
    current = request(endpoint, "HEAD")[1]["ETag"]

    # A second writer updates the file while the first PUT is still uploading.
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(5)
        sock.connect(str(endpoint))
        sock.sendall(f"PUT /sample HTTP/1.1\r\nHost: localhost\r\nIf-Match: {current}\r\n"
                     "Expect: 100-continue\r\nContent-Length: 3\r\n\r\n".encode())
        with sock.makefile("rb") as stream:
            assert stream.readline() == b"HTTP/1.1 100 Continue\r\n"
            assert stream.readline() == b"\r\n"
            assert request(endpoint, "PUT", b"winner", **{"If-Match": current})[0] == 204
            sock.sendall(b"old")
            assert stream.readline().startswith(b"HTTP/1.1 412 ")
    assert sample.read_bytes() == b"winner"

    value = "shared property " * 128
    body = (f'<D:propertyupdate xmlns:D="DAV:" xmlns:T="urn:henge:test"><D:set><D:prop>'
            f'<T:note>{value}</T:note></D:prop></D:set></D:propertyupdate>').encode()
    status, _, xml = request(endpoint, "PROPPATCH", body)
    assert status == 207 and "200 OK" in ET.fromstring(xml).findtext(".//{DAV:}status")
    status, headers, xml = request(endpoint, "PROPFIND", Depth="0")
    assert (status, headers["Cache-Control"]) == (207, "no-cache")
    properties = ET.fromstring(xml)
    assert properties.findtext(".//{urn:henge:test}note") == value
    assert properties.findtext(".//{DAV:}getetag") == request(endpoint, "HEAD")[1]["ETag"]


def test_image_cold_read(root, endpoint):
    data = bytes(range(256)) * 64
    path = "/Installer.DMG"
    (root / path[1:]).write_bytes(data)
    apple = {"User-Agent": "WebDAVFS/4.0 Darwin"}
    start = len(data) - 12  # DiskImageMounter's cold probe on a UDIF image
    trailer = f"bytes={start}-{len(data) - 1}"
    status, headers, body = request(endpoint, "GET", path=path, Range=trailer, **apple)
    assert (status, headers["Cache-Control"], body) == (503, "no-store", b"")

    # The parallel transfer and its resume can still populate the entire cache.
    status, headers, body = request(endpoint, "GET", path=path, **apple)
    assert (status, body) == (200, data)
    status, _, tail = request(endpoint, "GET", path=path, Range=f"bytes={start}-",
                              **{"If-Range": headers["Last-Modified"]}, **apple)
    assert (status, tail) == (206, data[start:])
    assert request(endpoint, "GET", path=path, Range="bytes=256-511", **apple)[2] == data[256:512]
    assert request(endpoint, "GET", path=path, Range="bytes=-12", **apple)[2] == data[start:]
    assert request(endpoint, "HEAD", path=path, Range=trailer, **apple)[0] == 206
    assert request(endpoint, "GET", path=path, Range=trailer)[2] == data[start:]
    for name in ("Installer.zip", "._Installer.DMG"):
        (root / name).write_bytes(data)
        assert request(endpoint, "GET", path="/" + name, Range=trailer, **apple)[2] == data[start:]


if __name__ == "__main__":
    lib = ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
    lib.hv_share_start.argtypes = [ctypes.c_char_p] * 3
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "folder"
        root.mkdir()
        endpoint = root.parent / "share.sock"
        assert lib.hv_share_start(bytes(root), bytes(endpoint), None) == 0
        test_battery(lib, endpoint)
        test_share(root, endpoint)
        test_image_cold_read(root, endpoint)
    print("Battery long poll: initial, charge transitions, unavailable and legacy clipboard passed")
    print("WebDAV: cache revalidation, conditional writes and property round-trip passed")
    print("WebDAV: cold disk image trailer probes and normal range reads passed")
