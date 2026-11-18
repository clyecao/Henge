"""Exercise the WebDAV endpoint Finder uses, including host edits between guest requests."""
import ctypes
import http.client
import os
from pathlib import Path
import socket
import sys
import tempfile
import xml.etree.ElementTree as ET


def request(endpoint, method, body=b"", **headers):
    conn = http.client.HTTPConnection("localhost", timeout=5)
    try:
        conn.sock = socket.socket(socket.AF_UNIX)
        conn.sock.settimeout(conn.timeout)
        conn.sock.connect(str(endpoint))
        conn.request(method, "/sample", body, headers)
        response = conn.getresponse()
        return response.status, response.headers, response.read()
    finally:
        conn.close()


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


if __name__ == "__main__":
    lib = ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
    lib.hv_share_start.argtypes = [ctypes.c_char_p] * 3
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "folder"
        root.mkdir()
        endpoint = root.parent / "share.sock"
        assert lib.hv_share_start(bytes(root), bytes(endpoint), None) == 0
        test_share(root, endpoint)
    print("WebDAV: cache revalidation, conditional writes and property round-trip passed")
