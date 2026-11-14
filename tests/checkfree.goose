import std;
import bgzf from "..";
import io from "github.com/sstadick/goose-io@v0.3.0";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";
import deflate from "github.com/sstadick/goose-deflate@v0.1.0";

// Unannotated metadata helpers are usable from checkfree callers.
checkfree fn positions(reader: const bgzf::Reader&, writer: const bgzf::Writer&) -> u64, u64 {
    return reader.tell(), writer.tell();
}
fn main() {
    // Synthetic stream state: no file or codec is opened in this test.
    let reader = bgzf::Reader { begin: 7, end: 9, block_offset: 100, .. };
    let writer = bgzf::Writer { size: 11, offset: 4096, .. };
    let r, w = positions(reader, writer);
    assert(r == (100 << 16 | 7) && w == (4096 << 16 | 11));
    let exhausted = bgzf::Reader { begin: 65536, end: 65536, next_block: 8192, .. };
    let next, same = positions(exhausted, writer);
    assert(next == 8192 << 16 && same == w);
}
