// Seekable BGZF input. Buffers and the decompressor are reused per block.
namespace bgzf;
import std;
import io from "github.com/sstadick/goose-io@v0.3.0";
import deflate from "github.com/sstadick/goose-deflate@v0.1.0";

extern fn seek_raw(fd: i32, offset: i64) -> i64 = "goose_bgzf_seek";

// Ready means the requested bytes were read. End is a clean block boundary;
// Truncated is a partial header, block, or requested value. Errors are sticky.
//
// ```goose
// assert(bgzf::Status.End != bgzf::Status.Truncated);
// ```
enum Status { Ready, End, Truncated, Invalid, IoError, Closed }

// Owns its file and decompressor. Do not copy an open stream. close explicitly.
// Empty BGZF members are checked and skipped, including internal EOF markers.
// A missing final marker is accepted, like an EOF at any complete block boundary.
// Treat implementation fields as read-only. Storage is reused, bounded to
// three 64 KiB buffers plus the native decompressor; no per-block allocation.
//
// ```goose
// let reader = bgzf::Reader { .. }; defer reader.close();
// assert(reader.status == bgzf::Status.Closed);
// ```
struct Reader {
    decoder: deflate::Decompressor,
    status:  Status = Status.Closed,
    begin:   i64    = 0,
    end:     i64    = 0,
    // Compressed offsets, independent of read-ahead in input.
    next_block:   u64 = 0,
    block_offset: u64 = 0,
    compressed:   u8[65536],
    decoded:      u8[65536],
    // Own read-ahead so a compressed seek can invalidate it atomically.
    input:       io::FileHandle = io::FileHandle { fd: -1 },
    buffered:    u8[65536],
    input_begin: i64 = 0,
    input_end:   i64 = 0,
}

inline fn le16(bytes: const u8[:], at: i64) -> u32 {
    let word = bytes[at..at + 2];
    word[0] | ((word[1] as u32) << 8)
}

inline fn le32(bytes: const u8[:], at: i64) -> u32 {
    let word = bytes[at..at + 4];
    word[0] | ((word[1] as u32) << 8) | ((word[2] as u32) << 16) | ((word[3] as u32) << 24)
}

// Release native resources. Repeated close is safe.
//
// ```goose
// let reader = bgzf::Reader { .. };
// reader.close(); reader.close();
// assert(reader.status == bgzf::Status.Closed);
// ```
fn close(stream: Reader&) {
    io::close(stream.input);
    stream.decoder.close();
    stream.status = Status.Closed;
    stream.begin = 0;
    stream.end = 0;
    stream.input_begin = 0;
    stream.input_end = 0;
}

// Open a new stream, closing any previous input. Ready on success.
//
// ```goose
// let reader = bgzf::Reader { .. }; defer reader.close();
// assert(reader.open("") == bgzf::Status.IoError);
// ```
fn open(stream: Reader&, path: const u8[:]) -> Status {
    stream.close();
    let file, ok = io::open_read(path);
    if !ok { stream.status = Status.IoError; return stream.status; }
    stream.input = file;
    file.fd = -1;
    let decoder, allocated = deflate::decompressor();
    if !allocated {
        io::close(stream.input);
        stream.status = Status.IoError;
        return stream.status;
    }
    stream.decoder = decoder;
    stream.next_block = 0;
    stream.block_offset = 0;
    stream.status = Status.Ready;
    stream.status
}

fn input_exact(stream: Reader&, output: u8[:]) -> Status {
    var n: i64 = 0;
    while n < output.len {
        if stream.input_begin == stream.input_end {
            let count = io::read(stream.input, stream.buffered);
            if count < 0 { return Status.IoError; }
            if count == 0 { return if n == 0 { Status.End } else { Status.Truncated }; }
            stream.input_begin = 0;
            stream.input_end = count;
        }
        let count = min(output.len - n, stream.input_end - stream.input_begin);
        output[n..n + count].move_from(stream.buffered[stream.input_begin..stream.input_begin + count]);
        stream.input_begin += count;
        n += count;
    }
    Status.Ready
}

fn block_read(stream: Reader&) -> Status {
    while true {
        let first = stream.input_exact(stream.compressed[..12]);
        if first != Status.Ready { return first; }
        let bytes = stream.compressed[..];
        if bytes[0] != 31 || bytes[1] != 139 || bytes[2] != 8 || bytes[3] != 4 {
            return Status.Invalid;
        }
        let xlen = le16(bytes, 10) as i64;
        if xlen < 6 || xlen > 65510 { return Status.Invalid; }
        let extra = stream.input_exact(bytes[12..12 + xlen]);
        if extra != Status.Ready { return if extra == Status.End { Status.Truncated } else { extra }; }
        var size: i64 = 0;
        var at:   i64 = 12;
        while at < 12 + xlen {
            if at + 4 > 12 + xlen { return Status.Invalid; }
            let len = le16(bytes, at + 2) as i64;
            if at + 4 + len > 12 + xlen { return Status.Invalid; }
            if bytes[at] == 'B' && bytes[at + 1] == 'C' {
                if len != 2 || size != 0 { return Status.Invalid; }
                size = le16(bytes, at + 4) as i64 + 1;
            }
            at += 4 + len;
        }
        if size < 12 + xlen + 8 || size > 65536 { return Status.Invalid; }
        let rest = stream.input_exact(bytes[12 + xlen..size]);
        if rest != Status.Ready { return if rest == Status.End { Status.Truncated } else { rest }; }
        let expected = le32(bytes, size - 4) as i64;
        if expected > 65536 { return Status.Invalid; }
        let result = stream.decoder.decompress(deflate::Format.Gzip, bytes[..size], stream.decoded);
        if result.status != deflate::Status.Success || result.consumed != size || result.written != expected {
            return Status.Invalid;
        }
        stream.block_offset = stream.next_block;
        stream.next_block += size as u64;
        stream.begin = 0;
        stream.end = result.written;
        if stream.end > 0 { break; }
    }
    Status.Ready
}

// Read exactly output.len decompressed bytes across any number of BGZF blocks.
// On failure output may be partially written; discard it. End means zero bytes
// were available. A partially satisfied request returns Truncated, never End.
//
// ```goose
// let reader = bgzf::Reader { .. }; var bytes: u8[1] = [0];
// assert(reader.read(bytes) == bgzf::Status.Closed);
// ```
fn read(stream: Reader&, output: u8[:]) -> Status {
    if stream.status != Status.Ready { return stream.status; }
    var n: i64 = 0;
    while n < output.len {
        if stream.begin == stream.end {
            stream.status = stream.block_read();
            if stream.status == Status.End && n > 0 { stream.status = Status.Truncated; }
            if stream.status != Status.Ready { return stream.status; }
        }
        let count = min(output.len - n, stream.end - stream.begin);
        output[n..n + count].move_from(stream.decoded[stream.begin..stream.begin + count]);
        stream.begin += count;
        n += count;
    }
    Status.Ready
}

// Read up to one decoded block into caller storage. Returns count and status;
// only output[..count] is initialized. Positive count means Ready; zero means
// EOF/error, except an empty output returns (0, Ready) on an open ready reader.
// Unlike read(), a short final read is not Truncated. No input view is retained.
//
// ```goose
// let path = "bgzf-doc.gz"; defer delete_file(path);
// let writer = bgzf::Writer { .. }; defer writer.close();
// assert(writer.open(path) == bgzf::Status.Ready);
// assert(writer.write("hello") == bgzf::Status.Ready);
// assert(writer.close() == bgzf::Status.Ready);
// let reader = bgzf::Reader { .. }; defer reader.close();
// assert(reader.open(path) == bgzf::Status.Ready);
// var data: u8[16] = [0; 16];
// let n, status = reader.read_some(data);
// assert(n == 5 && status == bgzf::Status.Ready && data[..n] == "hello");
// let end, eof = reader.read_some(data);
// assert(end == 0 && eof == bgzf::Status.End);
// ```
fn read_some(stream: Reader&, output: u8[:]) -> i64, Status {
    if stream.status != Status.Ready || output.len == 0 { return 0, stream.status; }
    if stream.begin == stream.end { stream.status = stream.block_read(); }
    if stream.status != Status.Ready { return 0, stream.status; }
    let n = min(output.len, stream.end - stream.begin);
    output[..n].move_from(stream.decoded[stream.begin..stream.begin + n]); stream.begin += n;
    return n, Status.Ready;
}

// Position of the next decompressed byte, as a BAM virtual offset. At an
// exhausted block this is the next compressed block's start, not offset 65536.
// High 48 bits are a compressed file offset; low 16 bits are a block offset.
// Only meaningful on an open stream; virtual offsets are not byte distances.
//
// ```goose
// let reader = bgzf::Reader { .. };
// assert(reader.tell() == 0);
// ```
fn tell(stream: const Reader&) -> u64 {
    if stream.begin == stream.end { stream.next_block << 16 }
    else { (stream.block_offset << 16) | (stream.begin as u64) }
}

// Reset EOF/errors and seek to an indexed virtual offset. A nonzero in-block
// offset must lie in the addressed block, not in a subsequent nonempty block.
// Only seek to offsets returned by tell() or a trusted BGZF index.
//
// ```goose
// let reader = bgzf::Reader { .. };
// assert(reader.seek(0) == bgzf::Status.Closed);
// ```
fn seek(stream: Reader&, offset: u64) -> Status {
    if stream.input.fd < 0 { return Status.Closed; }
    let compressed_offset = offset >> 16;
    let within = (offset & 65535) as i64;
    if stream.status == Status.Ready && stream.end > 0 && compressed_offset == stream.block_offset {
        if within > stream.end { stream.status = Status.Invalid; return stream.status; }
        stream.begin = within;
        return Status.Ready;
    }
    stream.begin = 0;
    stream.end = 0;
    stream.input_begin = 0;
    stream.input_end = 0;
    // Keep CRT descriptors in the module that opened them on Windows.
    if io::seek(stream.input, compressed_offset as i64) < 0 {
        stream.status = Status.IoError;
        return stream.status;
    }
    stream.next_block = compressed_offset;
    stream.status = stream.block_read();
    if stream.status == Status.Ready {
        if within > stream.end || (within != 0 && stream.block_offset != compressed_offset) {
            stream.status = Status.Invalid;
        } else { stream.begin = within; }
    } else if stream.status == Status.End && within != 0 { stream.status = Status.Invalid; }
    stream.status
}

inline fn put16(bytes: u8[:], at: i64, value: u32) {
    bytes[at] = value as! u8;
    bytes[at + 1] = (value >> 8) as! u8;
}

inline fn put32(bytes: u8[:], at: i64, value: u32) {
    for i in 4 { bytes[at + i] = (value >> (i * 8)) as! u8; }
}

// Seqair's single-threaded BGZF sink: 0xff00-byte input blocks, one reusable
// compressor and one whole-block output buffer. Even level-0/random input
// fits the 65536-byte wire limit. close must be checked for final write errors.
// Owns its file and native compressor; do not copy an open writer. Treat
// implementation fields as read-only. Caller input is never retained.
//
// ```goose
// let writer = bgzf::Writer { .. };
// assert(writer.close() == bgzf::Status.Ready);
// ```
struct Writer {
    encoder: deflate::Compressor,
    output: io::FileHandle = io::FileHandle { fd: -1 },
    status: Status = Status.Closed,
    size: i64 = 0,
    offset: u64 = 0,
    data: u8[65280],
    compressed: u8[65536],
}

fn write_all(writer: Writer&, bytes: const u8[:]) -> Status {
    var at: i64 = 0;
    while at < bytes.len {
        let n = io::write(writer.output, bytes[at..]);
        if n <= 0 { writer.status = Status.IoError; return writer.status; }
        at += n;
    }
    writer.status
}

// Emit a pending block. Empty flush is a no-op. This does not call fsync.
// Failure poisons further writes; close still releases resources.
//
// ```goose
// let writer = bgzf::Writer { .. };
// assert(writer.flush() == bgzf::Status.Closed);
// ```
fn flush(writer: Writer&) -> Status {
    if writer.status != Status.Ready || writer.size == 0 { return writer.status; }
    let n = writer.encoder.compress(deflate::Format.Raw, writer.data[..writer.size], writer.compressed[18..65528]);
    if n <= 0 { writer.status = Status.Invalid; return writer.status; }
    let total = n + 26;
    writer.compressed[..18].move_from("\x1f\x8b\x08\x04\0\0\0\0\0\xff\x06\0BC\x02\0\0\0");
    put16(writer.compressed, 16, (total - 1) as u32);
    put32(writer.compressed, 18 + n, deflate::crc32(writer.data[..writer.size]));
    put32(writer.compressed, 22 + n, writer.size as u32);
    if writer.write_all(writer.compressed[..total]) != Status.Ready { return writer.status; }
    writer.offset += total as u64;
    writer.size = 0;
    writer.status
}

// Flush remaining bytes and append the canonical EOF member only on success.
// Always release resources. Repeated close is safe; a failed file is partial.
//
// ```goose
// let writer = bgzf::Writer { .. };
// assert(writer.close() == bgzf::Status.Ready);
// assert(writer.close() == bgzf::Status.Ready);
// ```
fn close(writer: Writer&) -> Status {
    var result = writer.status;
    if writer.output.fd >= 0 {
        if result == Status.Ready { result = writer.flush(); }
        if result == Status.Ready {
            result = writer.write_all("\x1f\x8b\x08\x04\0\0\0\0\0\xff\x06\0BC\x02\0\x1b\0\x03\0\0\0\0\0\0\0\0\0");
        }
        if !io::close(writer.output) && result == Status.Ready { result = Status.IoError; }
    }
    writer.encoder.close();
    writer.status = Status.Closed;
    writer.size = 0;
    return if result == Status.Closed { Status.Ready } else { result };
}

// Create/truncate output with libdeflate level 0..12 (default 6). Closing an
// earlier output must succeed before reopening. Failed opens are sticky until
// close; invalid levels do not touch the destination. No sorting or indexing.
//
// ```goose
// let writer = bgzf::Writer { .. };
// assert(writer.open("", 13) == bgzf::Status.Invalid);
// assert(writer.close() == bgzf::Status.Invalid);
// ```
fn open(writer: Writer&, path: const u8[:], level: i32 = 6) -> Status {
    let previous = writer.close();
    if previous != Status.Ready { return previous; }
    if level < 0 || level > 12 { writer.status = Status.Invalid; return writer.status; }
    let encoder, allocated = deflate::compressor(level);
    if !allocated { writer.status = Status.IoError; return writer.status; }
    let file, ok = io::open_write(path);
    if !ok { encoder.close(); writer.status = Status.IoError; return writer.status; }
    writer.encoder = encoder;
    writer.output = file;
    file.fd = -1;
    writer.offset = 0;
    writer.status = Status.Ready;
    writer.status
}

// Buffer arbitrary bytes, automatically emitting full blocks. A failure may
// leave a partial file; check close even when all writes succeeded.
//
// ```goose
// let writer = bgzf::Writer { .. };
// assert(writer.write("data") == bgzf::Status.Closed);
// ```
fn write(writer: Writer&, bytes: const u8[:]) -> Status {
    if writer.status != Status.Ready { return writer.status; }
    var at: i64 = 0;
    while at < bytes.len {
        let n = min(bytes.len - at, writer.data.len - writer.size);
        writer.data[writer.size..writer.size + n].move_from(bytes[at..at + n]);
        writer.size += n;
        at += n;
        if writer.size == writer.data.len && writer.flush() != Status.Ready { return writer.status; }
    }
    writer.status
}

// Keep ordinary records within one block; oversized records may span blocks.
// Flush if needed before the caller's next write. This does not reserve memory
// or write padding. Zero is a no-op; negative length poisons the writer.
//
// ```goose
// let writer = bgzf::Writer { .. };
// assert(writer.reserve_record(10) == bgzf::Status.Closed);
// ```
fn reserve_record(writer: Writer&, length: i64) -> Status {
    if writer.status != Status.Ready { return writer.status; }
    if length < 0 { writer.status = Status.Invalid; return writer.status; }
    if length > writer.data.len - writer.size { writer.flush() } else { writer.status }
}

// Virtual offset of the next output byte, including buffered data. Stable
// across flush/close for bytes already written. Not a decompressed byte count.
//
// ```goose
// let writer = bgzf::Writer { .. };
// assert(writer.tell() == 0);
// ```
fn tell(writer: const Writer&) -> u64 { (writer.offset << 16) | (writer.size as u64) }
