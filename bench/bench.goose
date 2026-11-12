import std;
import os;
import bgzf from "..";
import io from "github.com/sstadick/goose-io@v0.2.2";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";
import deflate from "github.com/sstadick/goose-deflate@v0.1.0";

fn main() {
    let args = args();
    let level, ok = parse_int(args[3]); assert(ok);
    var data: u8[>..] = []; assert(read_file(args[1], data));
    var decoded: u8[>..] = []; decoded.resize(data.len, 0);
    let writer = bgzf::Writer { .. }; defer writer.close();
    let reader = bgzf::Reader { .. }; defer reader.close();
    var write_ns: i64 = 0; var read_ns: i64 = 0;
    for iteration in 4 {
        let start = clock_ns();
        assert(writer.open(args[2], level as i32) == bgzf::Status.Ready);
        assert(writer.write(data) == bgzf::Status.Ready);
        assert(writer.close() == bgzf::Status.Ready);
        let written = clock_ns();
        assert(reader.open(args[2]) == bgzf::Status.Ready);
        assert(reader.read(decoded) == bgzf::Status.Ready);
        var tail: u8[1] = [0]; assert(reader.read(tail) == bgzf::Status.End);
        reader.close();
        let end = clock_ns();
        assert(decoded == data);
        if iteration > 0 { write_ns += written - start; read_ns += end - written; }
    }
    print(write_ns / 3, " ", read_ns / 3);
}
