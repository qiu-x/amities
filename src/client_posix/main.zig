const std = @import("std");
const posix = std.posix;
const sdl = @cImport({
    @cInclude("SDL3/SDL.h");
});
const opus = @cImport({
    @cInclude("opus/opus.h");
});

const common = @import("common/common.zig");

const SAMPLE_RATE = 16000;
const CHANNELS = 1;
const FRAME_SIZE = 320;
const MAX_PACKET_SIZE = 1500;

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    const socket = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(socket);
    try posix.connect(socket, &address.any, address.getOsSockLen());

    if (!sdl.SDL_Init(sdl.SDL_INIT_AUDIO)) return error.SDLInitFail;

    defer sdl.SDL_Quit();

    var spec: sdl.SDL_AudioSpec = .{
        .freq = SAMPLE_RATE,
        .format = sdl.SDL_AUDIO_S16,
        .channels = CHANNELS,
    };

    const stream = sdl.SDL_OpenAudioDeviceStream(
        sdl.SDL_AUDIO_DEVICE_DEFAULT_RECORDING,
        &spec,
        null,
        null
    );
    if (stream == null) return error.StreamOpenFailed;

    const resumed = sdl.SDL_ResumeAudioStreamDevice(stream);
    if (!resumed) return error.StreamResumeFailed;

    var error_code: c_int = 0;
    const encoder = opus.opus_encoder_create(SAMPLE_RATE, CHANNELS, opus.OPUS_APPLICATION_AUDIO, &error_code);
    if (encoder == null or error_code != opus.OPUS_OK) return error.OpusInitFail;
    defer opus.opus_encoder_destroy(encoder);

    var raw_buffer: [FRAME_SIZE]i16 = undefined;
    var encoded_buffer: [MAX_PACKET_SIZE]u8 = undefined;

    while (true) {
        const frame_bytes = FRAME_SIZE * @sizeOf(i16);
        const received = sdl.SDL_GetAudioStreamData(stream, &raw_buffer, frame_bytes);
        if (received <= 0) continue;

        const encoded_len = opus.opus_encode(encoder, &raw_buffer, FRAME_SIZE, &encoded_buffer, MAX_PACKET_SIZE);

        if (encoded_len < 0) continue;

        std.debug.print("Sending audio bytes: {}\n", .{encoded_len});

        try common.writeMessage(socket, encoded_buffer[0..@intCast(encoded_len)]);
    }
}
