const std = @import("std");
const mem = std.mem;
const time = std.time;

// https://www.youtube.com/watch?v=oacaq_1TkMU
const BUFFER_SIZE = 1024 * 16;

// chunk names
const RIFF = mem.nativeToBig(u32, @bitCast(u32, [4]u8{'R', 'I', 'F', 'F'}));
const WAVE = mem.nativeToBig(u32, @bitCast(u32, [4]u8{'W', 'A', 'V', 'E'}));
const FMT_ = mem.nativeToBig(u32, @bitCast(u32, [4]u8{'f', 'm', 't', ' '}));
const LIST = mem.nativeToBig(u32, @bitCast(u32, [4]u8{'L', 'I', 'S', 'T'}));
const DATA = mem.nativeToBig(u32, @bitCast(u32, [4]u8{'d', 'a', 't', 'a'}));

// TODO: add support for IEEE float32
pub const Format = enum(u16) {
    pcm = 1,
    _
};

pub fn Wav(comptime Reader: type, comptime SeekableStream: type) type {
    return struct {
        const Self = @This();

        reader: Reader,
        seekable: SeekableStream,
        start_position: u32,
        duration_in_seconds: u32,
        format: Format,
        num_of_channels: u16,
        sample_rate: u32,
        sample_count: u32,
        bits_per_sample: u16,

        pub fn getMinutes(self: Self) u32 {
            return (self.duration_in_seconds % time.s_per_hour) / time.s_per_min;
        }

        pub fn getResidueSeconds(self: Self) u32 {
            return (self.duration_in_seconds % time.s_per_hour) % time.s_per_min;
        }

        /// writes out all the PCM content to the desired `Writer`.
        /// `writer` supplied to this function must satisfy the requirements of `std.io.Writer`.
        pub fn writeAllPcm(self: Self, writer: anytype) !void {
            try self.seek(0);

            var buf: [BUFFER_SIZE]u8 = undefined;
            var i: u32 = 0;
            var len: usize = 0;
            const num_of_chunks = (self.sample_count / buf.len) * self.num_of_channels * (self.bits_per_sample / 8);

            while (i < num_of_chunks) : (i += 1) {
                len = try self.reader.readAll(&buf);
                if (len < buf.len) return error.EndOfStream;
                try writer.writeAll(&buf);
            }

            const remainder = self.sample_count % buf.len;
            if (remainder != 0) {
                len = try self.reader.readAll(&buf);
                if (len < remainder) return error.EndOfStream;
                try writer.writeAll(&buf);
            }
        }

        pub fn seek(self: Self, seconds: u32) !void {
            if (seconds > self.duration_in_seconds)
                return error.Unseekable;

            const single_sample_size = self.sample_rate * 2 * (self.bits_per_sample / 8);
            try self.seekable.seekTo(seconds * single_sample_size + self.start_position);
        }

        /// writes out the PCM content starting from `start` to `start` + `length`.
        /// `writer` supplied to this function must satisfy the requirements of `std.io.Writer`.
        pub fn writeSegment(self: Self, writer: anytype, start: u32, length: u32) !void {
            if (start + length > self.duration_in_seconds)
                return error.Unseekable;

            const single_sample_size = self.sample_rate * 2 * (self.bits_per_sample / 8);
            try self.seek(start);

            var buf: [BUFFER_SIZE]u8 = undefined;
            var i: u32 = 0;
            var len: usize = 0;
            const num_of_chunks = (length * single_sample_size) / buf.len;

            while (i < num_of_chunks) : (i += 1) {
                len = try self.reader.readAll(&buf);
                if (len < buf.len) return error.EndOfStream;
                try writer.writeAll(&buf);
            }

            const remainder = (length * single_sample_size) % buf.len;
            if (remainder != 0) {
                len = try self.reader.readAll(&buf);
                if (len < remainder) return error.EndOfStream;
                try writer.writeAll(&buf);
            }
        }

        /// returns the next sample as `f32`.
        pub fn getAsFloat32(self: Self) !f32 {
            if (self.format != .pcm)
                return error.OnlyPcmSupported;
            if (self.bits_per_sample != 16)
                return error.OnlySigned16BitSupported;

            return @intToFloat(f32, try self.reader.readIntLittle(i16)) / 32768;
        }
    };
}

pub const ParseError = error{
    MissingChunk,
    MissingWaveChunk,
    MissingSubChunk,
    UnknownSubChunk,
    UnsupportedFormat,
};

/// load a wav file from given `Reader`. the `seekable` (`SeekableStream`) provided to this function allows
/// audio seeking. returns a `Wav` where you can inspect and parse audio data.
pub fn load(
    reader: anytype,
    seekable: anytype,
) (ParseError || anyerror)!Wav(@TypeOf(reader), @TypeOf(seekable)) {
    if (try reader.readIntBig(u32) != RIFF)
        return error.MissingChunk;

    const overall_size = try reader.readIntLittle(u32);

    if (try reader.readIntBig(u32) != WAVE)
        return error.MissingWaveChunk;

    if (try reader.readIntBig(u32) != FMT_)
        return error.MissingSubChunk;
    // skip the chunk size of this, it must be 16
    try reader.skipBytes(4, .{});

    // type of format, only PCM is supported atm
    const format = switch (try reader.readIntLittle(u16)) {
        1 => Format.pcm,
        else => return error.UnsupportedFormat,
    };
    const num_of_channels = try reader.readIntLittle(u16);
    const sample_rate = try reader.readIntLittle(u32);
    const byte_rate = try reader.readIntLittle(u32);
    const block_align = try reader.readIntLittle(u16);
    const bits_per_sample = try reader.readIntLittle(u16);

    // TODO:
    _ = block_align;

    // loop until we get to data sub-chunk
    while (true) {
        const sub_chunk = try reader.readIntBig(u32);
        switch (sub_chunk) {
            // FIXME: LIST info might be desired in some situations
            LIST =>  try reader.skipBytes(try reader.readIntLittle(u32), .{}),
            DATA => break,

            else => return error.UnknownSubChunk,
        }
    }

    // get the size of data chunk
    const data_chunk_size = try reader.readIntLittle(u32);
    const sample_count = data_chunk_size / num_of_channels / (bits_per_sample / 8);
    const duration_in_seconds = overall_size / byte_rate;

    return .{
        .reader = reader,
        .seekable = seekable,
        .start_position = @intCast(u32, try seekable.getPos()),
        .duration_in_seconds = duration_in_seconds,
        .format = format,
        .num_of_channels = num_of_channels,
        .sample_rate = sample_rate,
        .sample_count = sample_count,
        .bits_per_sample = bits_per_sample,
    };
}
