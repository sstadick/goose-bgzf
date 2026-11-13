# goose-bgzf

Seekable BGZF reading and writing in [Goose](https://github.com/aardappel/goose),
extracted from [goose-seqair](https://github.com/sstadick/goose-seqair).
Framing, buffering and virtual offsets are Goose; reusable
[goose-deflate](https://github.com/sstadick/goose-deflate) handles compress and
validate each block with libdeflate. No htslib dependency.

```goose
import std;
import os;
import bgzf from "github.com/sstadick/goose-bgzf@v0.1.1";
import io from "github.com/sstadick/goose-io@v0.3.0";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";
import deflate from "github.com/sstadick/goose-deflate@v0.1.0";

fn main() {
    // Creates/truncates example.bgz; removes it when finished.
    let path = "example.bgz"; defer delete_file(path);
    let writer = bgzf::Writer { .. }; defer writer.close();
    assert(writer.open(path, 1) == bgzf::Status.Ready);
    assert(writer.write("ACGT\n") == bgzf::Status.Ready);
    let offset = writer.tell();
    assert(writer.write("second\n") == bgzf::Status.Ready);
    assert(writer.close() == bgzf::Status.Ready);

    let reader = bgzf::Reader { .. }; defer reader.close();
    assert(reader.open(path) == bgzf::Status.Ready);
    assert(reader.seek(offset) == bgzf::Status.Ready);
    var bytes: u8[32] = [0; 32];
    let n, status = reader.read_some(bytes);
    assert(status == bgzf::Status.Ready && bytes[..n] == "second\n");
    let count, end = reader.read_some(bytes);
    assert(count == 0 && end == bgzf::Status.End);
}
```

## Contract

- `Reader.read` fills the caller's slice exactly. A partial request is
  `Truncated`; discard its output. `read_some` returns the initialized prefix
  length, so a short final block is not an error.
- Reads verify BGZF framing, CRC32 and ISIZE, including empty members. Internal
  empty members are skipped. A complete last block without an EOF marker is
  accepted; partial blocks and trailing junk are errors. This is not an ordinary
  gzip reader.
- `tell`/`seek` use BAM virtual offsets: compressed block position in the high
  48 bits, decompressed position in the low 16. These are not byte distances.
  Seek requires a regular seekable file. Sequential reads do not seek.
- Writers accept libdeflate levels 0–12 (default 6), buffer 65,280 input bytes,
  and emit blocks no larger than 65,536 bytes, including incompressible input.
  `reserve_record` optionally starts a fresh block before a record; oversized
  records can still cross blocks. `close` flushes and appends the canonical EOF
  member. Check its result even when all writes succeeded.
- Each reader/writer owns its file and native codec. Do not copy an open one.
  Close explicitly, normally with `defer`. Errors are sticky until close/open
  (reader seek also resets errors). Failed output can contain partial data.
  `flush` does not call fsync. Buffers are reused; no per-block allocation.
- Single-threaded, path-based API. No `.gzi` creation/loading, automatic
  decompressed-offset lookup, parallel pipeline, append mode, or async I/O.

See the generated [API](API.md) and [benchmarks](bench/README.md).

## Build and verify

Requires Goose with package C sidecars, Clang, CMake 3.20+, Python 3.9+,
and Git. CI pins Goose `855f1037a5ceee837ef270382ac8d26df47a7139`
and goose-doc `bb399143866c0c42268f23c8dfda7a447173f93d`.
Root programs must declare the transitive imports shown above.

```sh
CC=clang CXX=clang++ GOOSE_CC=clang python3 tests/run.py
CC=clang CXX=clang++ GOOSE_CC=clang scripts/docs.sh --check
CC=clang CXX=clang++ GOOSE_CC=clang scripts/doctest.sh
```

Documentation scripts default to a sibling goose-doc checkout; override
`GOOSE_DOC=/path/to/goose-doc/main.goose`. Tests independently encode/decode
using Python zlib/gzip and exercise exact/partial reads, 64 KiB boundaries,
virtual offsets, corrupt/truncated members, empty files, failed writes and
resource reuse in debug and release builds. CI covers Linux x86-64/ARM64 and
macOS ARM64 and Windows x86-64. Seeks use goose-io's owning native module so
Windows CRT file descriptors do not cross DLL boundaries. Benchmarks compile native code **and libdeflate with Clang
`-O3 -march=native`**; Goose `-O2` selects frontend inlining only.

MIT; see [LICENSE](LICENSE). BGZF framing and block-size policy follow
[Seqair](https://github.com/Softleif/seqair).
