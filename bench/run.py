"""Warm-cache BGZF throughput; Clang -O3 -march=native for all timed code."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=7)
    args = parser.parse_args()
    assert args.rounds > 0
    flags = ["-O3", "-march=native"]
    report = {"platform": platform.platform(), "compiler": subprocess.check_output(["clang", "--version"], text=True),
              "native_flags": flags, "codec_flags": flags + ["-DNDEBUG"], "goose_inlining": "-O2",
              "rounds": args.rounds, "results": []}
    with tempfile.TemporaryDirectory(prefix="goose-bgzf-bench-") as t:
        directory = Path(t); source = directory / "bench.c"
        subprocess.run([os.environ.get("GOOSE", "goose"), "--standalone", "-O2", "-o", str(source), "bench/bench.goose"], cwd=ROOT, check=True)
        headers = [(directory / p).resolve() for p in re.findall(r'^#include "([^"]+)"', source.read_text(), re.M)]
        codec, = [p.parent.parent for p in headers if p.name == "deflate.h"]
        io, = [p.parent.parent for p in headers if p.name == "goosio.h"]
        build = directory / "codec"
        subprocess.run(["cmake", "-S", str(codec / "vendor/libdeflate"), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
                        f"-DCMAKE_C_COMPILER={shutil.which('clang')}", "-DCMAKE_C_FLAGS_RELEASE=-O3 -march=native -DNDEBUG",
                        "-DLIBDEFLATE_BUILD_SHARED_LIB=OFF", "-DLIBDEFLATE_BUILD_GZIP=OFF", "-DLIBDEFLATE_BUILD_TESTS=OFF"], check=True)
        subprocess.run(["cmake", "--build", str(build), "--parallel", "2", "--target", "libdeflate_static"], check=True)
        archive, = build.rglob("libdeflate.a")
        exe = directory / "bench"
        command = ["clang", *flags, str(source), str(ROOT / "src/seek.c"), str(io / "src/goosio.c"), str(archive),
                   "-o", str(exe), "-lm", "-pthread", *(["-ldl"] if platform.system() == "Linux" else [])]
        subprocess.run(command, check=True); report["build_command"] = command
        rng = random.Random(901)
        dna = bytes(rng.choices(b"ACGTN", weights=[24, 24, 24, 24, 4], k=4 * 1024 * 1024))
        for name, data in (("dna", dna), ("random", rng.randbytes(len(dna)))):
            input_path = directory / "input"; output = directory / "output.bgz"; input_path.write_bytes(data)
            for level in (0, 1, 6, 12):
                samples = []
                for _ in range(args.rounds):
                    samples.append(list(map(int, subprocess.check_output([str(exe), str(input_path), str(output), str(level)], text=True).split())))
                    assert gzip.decompress(output.read_bytes()) == data
                medians = [statistics.median(s[i] for s in samples) for i in range(2)]
                row = {"input": name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "level": level,
                       "compressed_bytes": output.stat().st_size, "samples_ns": samples,
                       "write_mib_s": len(data) / medians[0] * 1e9 / 2**20, "read_mib_s": len(data) / medians[1] * 1e9 / 2**20}
                report["results"].append(row)
                print(f"{name} level {level}: write {row['write_mib_s']:.1f}, read {row['read_mib_s']:.1f} MiB/s", flush=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__": main()
