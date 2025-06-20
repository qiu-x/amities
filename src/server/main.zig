const std = @import("std");
const net = std.net;
const posix = std.posix;
const opus = @cImport({
    @cInclude("opus/opus.h");
});

const common = @import("common/common.zig");

const SAMPLE_RATE = 16000;
const CHANNELS = 1;
const FRAME_SIZE = 320;
const MAX_PACKET_SIZE = 1500;

var mixer: Mixer = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    mixer = Mixer.init(allocator);

    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{.allocator = allocator, .n_jobs = 64});

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    std.debug.print("Listening...\n", .{});

    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };

        const client = Client{ .socket = socket, .address = client_address };
        try pool.spawn(Client.handle, .{client});
    }
}

const Client = struct {
    // TODO: Add reader & writer interfaces
    socket: posix.socket_t,
    address: std.net.Address,

    fn handle(self: Client) void {
        defer {
            posix.close(self.socket);
            mixer.remove(self.socket);
        }
        self._handle() catch |err| switch (err) {
            error.Closed => {},
            error.WouldBlock => {}, // TODO: timeout
            else => std.debug.print("[{any}] client handle error: {}\n", .{self.address, err}),
        };
    }

    fn _handle(self: Client) !void {
        const socket = self.socket;
        std.debug.print("[{}] connected\n", .{self.address});

        const timeout = posix.timeval{ .tv_sec = 2, .tv_usec = 500_000 };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

        var buf: [2048]u8 = undefined;
        var reader = common.Reader{ .pos = 0, .buf = &buf, .socket = socket };

        var decoded_pcm: [FRAME_SIZE]i16 = undefined;
        var mixed_pcm: [FRAME_SIZE]i16 = undefined;
        var encoded_buf: [512]u8 = undefined;

        var err: c_int = 0;
        const decoder = opus.opus_decoder_create(SAMPLE_RATE, CHANNELS, &err);
        if (decoder == null or err != 0) return error.OpusDecoderInit;

        defer _ = opus.opus_decoder_destroy(decoder);

        const encoder = opus.opus_encoder_create(SAMPLE_RATE, CHANNELS, opus.OPUS_APPLICATION_AUDIO, &err);
        if (encoder == null or err != 0) return error.OpusEncoderInit;

        defer _ = opus.opus_encoder_destroy(encoder);

        while (true) {
            const msg = try reader.readMessage(); // Probably should be in separate thread

            const decoded_samples = opus.opus_decode(
                decoder,
                msg.ptr,
                @intCast(msg.len),
                &decoded_pcm,
                FRAME_SIZE,
                0,
            );
            if (decoded_samples < 0) {
                std.debug.print("[{}] opus decode error {}\n", .{self.address, decoded_samples});
                continue;
            }

            try mixer.submit(socket, &decoded_pcm);
            mixer.mix(socket, FRAME_SIZE, &mixed_pcm);

            const encoded_len = opus.opus_encode(
                encoder,
                &mixed_pcm,
                FRAME_SIZE,
                &encoded_buf,
                encoded_buf.len,
            );
            if (encoded_len < 0) {
                std.debug.print("[{}] opus encode error {}\n", .{self.address, encoded_len});
                continue;
            }

            var len_prefix: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_prefix, @intCast(encoded_len), .little);

            var vec = [2]posix.iovec_const{
                .{ .base = &len_prefix, .len = 4 },
                .{ .base = &encoded_buf, .len = @intCast(encoded_len) },
            };
            try common.writeAllVectored(socket, &vec);
        }
    }
};

const Mixer = struct {
    map: std.AutoHashMap(posix.socket_t, []i16),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Mixer {
        return Mixer{
            .map = std.AutoHashMap(posix.socket_t, []i16).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn submit(self: *Mixer, socket: posix.socket_t, pcm: []i16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(socket, try std.heap.c_allocator.dupe(i16, pcm));
    }

    pub fn mix(self: *Mixer, exclude_socket: posix.socket_t, samples_per_input: usize, output: []i16) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var num_inputs: i32 = 0;
        var it= self.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == exclude_socket) continue;
            if (entry.value_ptr.*.len != samples_per_input) continue;
            num_inputs += 1;
        }

        if (num_inputs == 0) {
            for (output) |*out_sample| { out_sample.* = 0; }
            return;
        }

        for (output, 0..) |*out_sample, i| {
            var acc: i32 = 0;
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                if (entry.key_ptr.* == exclude_socket) continue;
                if (entry.value_ptr.*.len != samples_per_input) continue;
                acc += entry.value_ptr.*[i];
            }
            acc = @divTrunc(acc, num_inputs);
            out_sample.* = @intCast(std.math.clamp(acc, -32768, 32767));
        }
    }

    pub fn remove(self: *Mixer, socket: posix.socket_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.fetchRemove(socket)) |entry| {
            std.heap.c_allocator.free(entry.value);
        }
    }
};
