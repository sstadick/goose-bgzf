import std;
import bgzf from "..";
import io from "github.com/sstadick/goose-io@v0.3.0";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";
import deflate from "github.com/sstadick/goose-deflate@v0.1.0";

// Compile-fail fixture: buffered reads retain bounds checks. The diagnostic
// must reach the checked operation through the unannotated BGZF helpers.
checkfree fn read_checked(reader: bgzf::Reader&, output: u8[:]) -> i64, bgzf::Status {
    return reader.read_some(output);
}
fn main() {
    let reader = bgzf::Reader { .. };
    var bytes: u8[16] = [0; 16];
    let n, status = read_checked(reader, bytes);
    assert(n == 0 && status == bgzf::Status.Closed);
}
