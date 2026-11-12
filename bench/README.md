# BGZF throughput baseline

```sh
CC=clang CXX=clang++ GOOSE_CC=clang python3 bench/run.py --output results.json
```

All timed native code, including the separately rebuilt libdeflate, uses
**Clang `-O3 -march=native`**. Goose's `-O2` selects frontend inlining,
not native compiler optimization. The JSON records flags, compiler, input
hashes, sizes and every sample. Python independently decompresses every output.

Baseline on 2026-11-12: Linux x86-64, AMD Ryzen 9 3950X, Clang 18.1.3,
Goose `74c641c5ac6d762e57e3177678fe9dea414d042a`, libdeflate from
goose-deflate v0.1.0. Two deterministic 4 MiB inputs: independently sampled
ACGTN bases (24/24/24/24/4 percent), and uniform random bytes. Seven samples
per case; each process warms once then averages three iterations. Table values
are sample medians, measured in **uncompressed MiB/s**.

| Input | Level | Write MiB/s | Read MiB/s | Compressed bytes |
| --- | ---: | ---: | ---: | ---: |
| DNA | 0 | 807.5 | 4,330.5 | 4,196,347 |
| DNA | 1 | 247.3 | 772.0 | 1,426,616 |
| DNA | 6 | 16.8 | 560.8 | 1,206,117 |
| DNA | 12 | 5.4 | 550.6 | 1,203,522 |
| Random | 0 | 804.2 | 4,198.8 | 4,196,347 |
| Random | 1 | 141.8 | 4,093.4 | 4,196,347 |
| Random | 6 | 104.0 | 3,939.8 | 4,196,347 |
| Random | 12 | 48.1 | 3,810.7 | 4,196,347 |

Timing includes opening/closing files, codec allocation, all block work, copies
and EOF handling. Input loading and full output comparison are outside timing.
The reader still validates each block CRC inside timing. This is a single-threaded,
warm-page-cache benchmark, not durable disk throughput (`fsync` is not called).
Synthetic input is not representative of every BAM payload. These are standalone
baselines, not an htslib or upstream Seqair parity claim. Higher compression
levels need not benefit small blocks or incompressible data.
