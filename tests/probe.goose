import std;
import os;
import bgzf from "..";
import io from "github.com/sstadick/goose-io@v0.3.0";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";
import deflate from "github.com/sstadick/goose-deflate@v0.1.0";

fn name(s: bgzf::Status) -> const u8[:] {
    match s { Ready => "Ready", End => "End", Truncated => "Truncated", Invalid => "Invalid", IoError => "IoError", Closed => "Closed" }
}
fn integer(s: const u8[:]) -> i64 { let n, ok = parse_int(s); assert(ok); n }
fn main() {
    let args = args();
    if args[1] == "contract" { contract(args[2]); return; }
    if args[1] == "write" {
        var data: u8[>..] = []; assert(read_file(args[2], data));
        let writer = bgzf::Writer { .. }; defer writer.close();
        var status = writer.open(args[3], integer(args[4]) as i32);
        let chunk = integer(args[5]); assert(chunk > 0);
        var at = 0;
        while at < data.len && status == bgzf::Status.Ready {
            let end = min(data.len, at + chunk); status = writer.write(data[at..end]); at = end;
        }
        if status != bgzf::Status.Ready { assert(writer.write("x") == status); }
        let closed = writer.close();
        print(name(if status == bgzf::Status.Ready { closed } else { status })); return;
    }
    let reader = bgzf::Reader { .. }; defer reader.close();
    var status = reader.open(args[2]);
    var output: u8[>..] = [];
    if status == bgzf::Status.Ready {
        if args[1] == "read" {
            var buffer: u8[8191] = [0; 8191];
            while true {
                let n, s = reader.read_some(buffer); output.append(buffer[..n]);
                if s != bgzf::Status.Ready { status = s; break; }
            }
        } else {
            if args[1] == "seek" { status = reader.seek(integer(args[4]) as u64); }
            output.resize(integer(args[if args[1] == "seek" { 5 } else { 4 }]), 0);
            if status == bgzf::Status.Ready { status = reader.read(output); }
            if status != bgzf::Status.Ready { output.clear(); }
        }
    }
    assert(write_file(args[3], output)); print(name(status));
}

fn contract(path: const u8[:]) {
    let writer = bgzf::Writer { .. };
    assert(writer.open(path, -1) == bgzf::Status.Invalid);
    assert(writer.write("x") == bgzf::Status.Invalid);
    assert(writer.close() == bgzf::Status.Invalid && writer.close() == bgzf::Status.Ready);
    assert(writer.open(path) == bgzf::Status.Ready);
    var prefix: u8[65270] = [42; 65270];
    assert(writer.write(prefix) == bgzf::Status.Ready);
    let middle = writer.tell(); assert(middle == 65270);
    assert(writer.reserve_record(20) == bgzf::Status.Ready);
    let offset = writer.tell(); assert(offset > 65535 && (offset & 65535) == 0);
    assert(writer.write("0123456789abcdefghij") == bgzf::Status.Ready);
    assert(writer.flush() == bgzf::Status.Ready && writer.flush() == bgzf::Status.Ready);
    assert(writer.close() == bgzf::Status.Ready && writer.close() == bgzf::Status.Ready);
    let reader = bgzf::Reader { .. }; defer reader.close();
    assert(reader.open(path) == bgzf::Status.Ready);
    var small: u8[7] = [0; 7];
    assert(reader.seek(offset + 3) == bgzf::Status.Ready);
    assert(reader.read(small) == bgzf::Status.Ready && small == "3456789");
    assert(reader.tell() == offset + 10);
    assert(reader.seek(middle) == bgzf::Status.Ready);
    assert(reader.read(small) == bgzf::Status.Ready && small == "0123456");
    assert(reader.seek(offset + 65535) == bgzf::Status.Invalid);
    assert(reader.read(small) == bgzf::Status.Invalid);
    assert(reader.seek(0) == bgzf::Status.Ready);
    assert(reader.read(small) == bgzf::Status.Ready && small[0] == 42);
    assert(writer.open(path) == bgzf::Status.Ready);
    assert(writer.reserve_record(-1) == bgzf::Status.Invalid);
    assert(writer.close() == bgzf::Status.Invalid);
    assert(writer.open(path) == bgzf::Status.Ready);
    assert(writer.close() == bgzf::Status.Ready);
    assert(reader.open(path) == bgzf::Status.Ready);
    let n, s = reader.read_some(small); assert(n == 0 && s == bgzf::Status.End);
    assert(reader.seek(0) == bgzf::Status.End);
    reader.close(); reader.close(); assert(reader.read(small) == bgzf::Status.Closed);
    print("Ready");
}
