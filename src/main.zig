const std = @import("std");
const time = std.time;
const wave = @import("wave.zig");
const saudio = @import("sokol").audio;

fn streamFn(buf: [*c]f32, num_frames: i32, _: i32, ptr: ?*anyopaque) callconv(.C) void {
    const audio = @ptrCast(*wave.Wav(std.fs.File.Reader, std.fs.File.SeekableStream), @alignCast(4, ptr.?));

    var i: usize = 0;
    while (i < @intCast(usize, num_frames * 2)) : (i += 1) {
        buf[i] = audio.getAsFloat32() catch break;
    }
}

test "play WAV through sokol audio" {
    var file = try std.fs.cwd().openFile("think_about_things.wav", .{ .mode = .read_only });
    defer file.close();

    var audio = try wave.load(file.reader(), file.seekableStream());

    saudio.setup(.{
        .stream_userdata_cb = streamFn,
        .user_data = &audio,
        .num_channels = audio.num_of_channels,
        .buffer_frames = 4096,
        .sample_rate = @intCast(i32, audio.sample_rate),
    });
    defer saudio.shutdown();

    while (true) {}
}
