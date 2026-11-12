"""BGZF wire, lifecycle, virtual offset and independent zlib interoperability tests."""
import gzip
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
EOF = bytes.fromhex("1f8b08040000000000ff0600424302001b0003000000000000000000")


def block(data, extra=b""):
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    payload = c.compress(data) + c.flush()
    size = 26 + len(extra) + len(payload)
    assert size <= 65536
    return (b"\x1f\x8b\x08\x04" + bytes(5) + b"\xff" + struct.pack("<H", 6 + len(extra))
            + extra + b"BC\x02\x00" + struct.pack("<H", size - 1) + payload
            + struct.pack("<II", zlib.crc32(data), len(data)))


def suite(command, directory):
    source, output, decoded = [directory / n for n in ("input", "output", "decoded")]
    def run(mode, *args):
        return subprocess.check_output([*map(str, command), mode, *map(str, args)], cwd=ROOT, text=True).strip()
    rng = random.Random(901)
    for data in (b"", b"x", b"acgt\0\xff" * 50000, rng.randbytes(200000)):
        source.write_bytes(data)
        for level, chunk in ((0, 1), (1, 65279), (6, 65536), (12, 1000000)):
            assert run("write", source, output, level, chunk) == "Ready"
            wire = output.read_bytes(); assert wire.endswith(EOF)
            assert gzip.decompress(wire) == data
            at = 0
            while at < len(wire):
                size = struct.unpack_from("<H", wire, at + 16)[0] + 1
                assert 28 <= size <= 65536
                assert len(gzip.decompress(wire[at:at + size])) <= 65280
                at += size
            assert at == len(wire)
            assert run("read", output, decoded) == "End" and decoded.read_bytes() == data
    # Independently encode full 65536-byte decoded blocks and arbitrary block
    # splits, extra fields and internal empty blocks. EOF marker is optional.
    a, b = b"A" * 65536, b"second\0block" * 13
    first = block(a, b"XY\x03\0abc"); empty = block(b""); last = block(b)
    wire = first + empty + last
    for suffix in (b"", EOF):
        source.write_bytes(wire + suffix)
        assert run("read", source, decoded) == "End" and decoded.read_bytes() == a + b
        assert run("exact", source, decoded, len(a + b)) == "Ready" and decoded.read_bytes() == a + b
        assert run("exact", source, decoded, len(a + b) + 1) == "Truncated"
        for offset, expected in ((65535, a[-1:] + b[:6]), ((len(first) + len(empty)) << 16 | 3, b[3:10]), (0, a[:7])):
            assert run("seek", source, decoded, offset, 7) == "Ready" and decoded.read_bytes() == expected
        assert run("seek", source, decoded, (len(first) << 16) | 1, 1) == "Invalid"
    source.write_bytes(EOF)
    assert run("exact", source, decoded, 1) == "End"
    source.write_bytes(b"")
    assert run("read", source, decoded) == "End"
    # Truncation at framing/payload/trailer boundaries, bad CRC/ISIZE, duplicate
    # BC, ordinary gzip and trailing junk must not become a successful EOF.
    wire = block(b"asymmetric data" * 50)
    for cut in (1, 3, 11, 12, 17, 18, len(wire) - 8, len(wire) - 1):
        source.write_bytes(wire[:cut]); assert run("read", source, decoded) == "Truncated", cut
    for at in (0, 2, 3, 12, 14, 16, len(wire) - 8, len(wire) - 4):
        bad = bytearray(wire); bad[at] ^= 255; source.write_bytes(bad)
        assert run("read", source, decoded) in ("Invalid", "Truncated"), at
    for bad in (gzip.compress(b"not bgzf"), block(b"x", b"BC\x02\0\x1b\0"), wire + b"junk"):
        source.write_bytes(bad); assert run("read", source, decoded) in ("Invalid", "Truncated")
    assert run("contract", output) == "Ready"
    assert output.read_bytes() == EOF
    assert run("read", directory / "missing", decoded) == "IoError"
    source.write_bytes(b"nonempty")
    assert run("write", source, directory / "missing/file", 6, 100) == "IoError"
    if Path("/dev/full").exists(): assert run("write", source, "/dev/full", 6, 100) == "IoError"
    print("PASS", command, "BGZF bytes, boundaries, seeks, errors and lifecycle", flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix="goose-bgzf-tests-") as t:
        path = Path(t)
        for debug in (True, False):
            exe = path / "probe"
            subprocess.run([os.environ.get("GOOSE", "goose"), "build", "tests/probe.goose", "--cc", "clang", "-O2",
                            *(["--debug"] if debug else []), "-o", str(exe)], cwd=ROOT, check=True)
            suite([exe], path)


if __name__ == "__main__": main()
