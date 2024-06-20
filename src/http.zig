const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const EventLoop = @import("EventLoop.zig");

pub const ContentType = enum {
    @"application/json",
    @"text/html",
    @"text/javascript",
    @"application/wasm",

    fn name(self: ContentType) []const u8 {
        inline for (std.meta.fields(ContentType)) |field| {
            if (@intFromEnum(self) == field.value) {
                return field.name;
            }
        }

        unreachable;
    }
};

pub const Header = struct {
    const Field = struct {
        key: []const u8,
        value: []const u8,
    };

    status: std.http.Status,
    content_type: ContentType,
    content_length: usize,
    extra: []const Field = &.{},

    pub fn format(self: *const Header, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;

        try writer.print(
            "HTTP/1.1 {d} {s}\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Connection: close\r\n" ++
                "Content-Length: {d}\r\n",
            .{
                @intFromEnum(self.status),
                self.status.phrase() orelse "",
                self.content_type.name(),
                self.content_length,
            },
        );

        for (self.extra) |field| {
            try writer.print("{s}: {s}\r\n", .{ field.key, field.value });
        }

        try writer.writeAll("\r\n");
    }
};
pub const Reader = struct {
    const State = enum {
        read_header,
        read_body,
        finished,
        deinit,
    };

    state: State = .read_header,
    hp: std.http.HeadParser = .{},

    // General buffer used in any read state, at .finished will be the body
    buf: std.ArrayListUnmanaged(u8) = .{},

    // Valid after .read_header
    header_size: usize = 0,
    header_buf: []const u8 = &.{},
    target: []const u8 = &.{},
    transfer_encoding: std.http.TransferEncoding = undefined,
    content_length: ?u64 = null,

    pub fn deinit(self: *Reader, alloc: Allocator) void {
        self.buf.deinit(alloc);
        alloc.free(self.header_buf);
    }

    pub fn poll(self: *Reader, alloc: Allocator, tcp: std.net.Stream) !void {
        while (true) {
            switch (self.state) {
                .read_header => try self.readHeader(alloc, tcp),
                .read_body => try self.readBody(alloc, tcp),
                .deinit, .finished => {
                    return;
                },
            }
        }
    }

    fn readHeader(self: *Reader, alloc: Allocator, tcp: std.net.Stream) !void {
        while (self.hp.state != .finished) {
            var buf: [1024]u8 = undefined;
            const buf_len = try tcp.read(&buf);
            if (buf_len == 0) {
                self.state = .deinit;
                return;
            }

            try self.buf.appendSlice(alloc, buf[0..buf_len]);
            self.header_size += self.hp.feed(buf[0..buf_len]);
        }

        var new_buf = std.ArrayListUnmanaged(u8){};
        errdefer new_buf.deinit(alloc);

        try new_buf.appendSlice(alloc, self.buf.items[self.header_size..]);

        var old_buf = self.buf;
        old_buf.items.len = self.header_size;

        self.header_buf = try old_buf.toOwnedSlice(alloc);
        const header = try std.http.Server.Request.Head.parse(self.header_buf);
        self.target = header.target;
        self.transfer_encoding = header.transfer_encoding;
        self.content_length = header.content_length;

        self.buf = new_buf;
        self.state = .read_body;
    }

    fn readBody(self: *Reader, alloc: Allocator, tcp: std.net.Stream) !void {
        if (self.transfer_encoding == .chunked) {
            return error.Unsupported;
        }

        // FIXME: Set reasonable max len
        if (self.content_length == null) {
            self.state = .finished;
            return;
        }

        const cl = self.content_length.?;
        const expected_end_size = cl + self.header_size;
        while (self.buf.items.len < expected_end_size) {
            var buf: [1024]u8 = undefined;
            const buf_len = try tcp.read(&buf);
            if (buf_len == 0) {
                self.state = .deinit;
                return;
            }

            try self.buf.appendSlice(alloc, buf[0..buf_len]);

            if (self.buf.items.len > expected_end_size) {
                return error.InvalidData;
            } else if (self.buf.items.len == expected_end_size) {
                self.state = .finished;
                return;
            }
        }
    }
};

pub const Writer = struct {
    state: State = .write_header,
    header_writer: WriteState = .{},
    deinit_body: bool = false,
    body_writer: WriteState = .{},

    const State = enum {
        write_header,
        write_body,
        finished,
        deinit,
    };

    pub fn init(alloc: Allocator, header: Header, body: []const u8, deinit_body: bool) !Writer {
        const header_buf = try std.fmt.allocPrint(alloc, "{any}", .{header});
        errdefer alloc.free(header_buf);

        return .{
            .header_writer = .{
                .to_write = header_buf,
            },
            .deinit_body = deinit_body,
            .body_writer = .{
                .to_write = body,
            },
        };
    }

    pub fn deinit(self: *Writer, alloc: Allocator) void {
        alloc.free(self.header_writer.to_write);
        if (self.deinit_body) {
            alloc.free(self.body_writer.to_write);
        }
    }

    pub fn poll(self: *Writer, tcp: std.net.Stream) !void {
        while (true) {
            switch (self.state) {
                .write_header => try self.writeHeader(tcp),
                .write_body => try self.writeBody(tcp),
                .deinit, .finished => {
                    return;
                },
            }
        }
    }

    fn writeHeader(self: *Writer, tcp: std.net.Stream) !void {
        if (try self.header_writer.write(tcp)) {
            self.state = .deinit;
            return;
        }
        self.state = .write_body;
    }

    fn writeBody(self: *Writer, tcp: std.net.Stream) !void {
        if (try self.body_writer.write(tcp)) {
            self.state = .deinit;
            return;
        }
        self.state = .finished;
    }
};

const WriteState = struct {
    to_write: []const u8 = &.{},
    amount_written: usize = 0,

    fn write(self: *WriteState, tcp: std.net.Stream) !bool {
        while (true) {
            if (self.amount_written >= self.to_write.len) {
                return false;
            }

            const written = try tcp.write(self.to_write[self.amount_written..]);
            if (written == 0) {
                return true;
            }
            self.amount_written += written;
        }
    }
};

pub const HttpConnection = struct {
    const State = enum {
        read,
        write,
        wait,
        finished,
        deinit,
    };

    pub const Action = enum {
        none,
        feed,
        deinit,
    };

    alloc: Allocator,
    tcp: std.net.Stream,
    state: State = .read,

    reader: Reader = .{},
    writer: Writer = .{},

    pub fn init(alloc: Allocator, tcp: std.net.Stream) !HttpConnection {
        return .{
            .alloc = alloc,
            .tcp = tcp,
        };
    }

    pub fn deinit(self: *HttpConnection) void {
        self.reset();
        self.tcp.close();
    }

    pub fn setResponse(self: *HttpConnection, writer: Writer) void {
        std.debug.assert(self.state == .wait);

        self.writer = writer;
        self.state = .write;
    }

    fn reset(self: *HttpConnection) void {
        self.reader.deinit(self.alloc);
        self.writer.deinit(self.alloc);

        self.state = .read;
        self.reader = .{};
        self.writer = .{};
    }

    fn read(self: *HttpConnection) !void {
        try self.reader.poll(self.alloc, self.tcp);

        if (self.reader.state == .deinit) {
            self.state = .deinit;
            return;
        }

        if (self.reader.state == .finished) {
            self.state = .wait;
            return;
        }
    }

    fn write(self: *HttpConnection) !void {
        try self.writer.poll(self.tcp);

        if (self.writer.state == .deinit) {
            self.state = .deinit;
            return;
        }

        if (self.writer.state == .finished) {
            self.state = .finished;
            return;
        }
    }

    pub fn poll(self: *HttpConnection) Action {
        return self.pollError() catch |e| {
            if (e == error.WouldBlock) {
                return .none;
            }

            std.log.err("Error {any}", .{e});

            return .deinit;
        };
    }

    fn pollError(self: *HttpConnection) !Action {
        while (true) {
            switch (self.state) {
                .read => try self.read(),
                .write => try self.write(),
                .wait => {
                    return .feed;
                },
                .deinit => return .deinit,
                .finished => {
                    // For the time being it seems that connection re-use
                    // actually reduces the amount of requests a browser will
                    // make per second, making the simulation look choppy
                    return .deinit;
                },
            }
        }
    }
};

pub const QueryParamsIt = struct {
    target: []const u8,

    const Param = struct {
        key: []const u8,
        val: []const u8,
    };

    pub fn init(target: []const u8) QueryParamsIt {
        const idx = std.mem.indexOfScalar(u8, target, '?') orelse {
            return .{
                .target = &.{},
            };
        };

        return .{ .target = target[idx..] };
    }

    pub fn next(self: *QueryParamsIt) ?Param {
        if (self.target.len < 2) {
            return null;
        }

        const key_start = 1;
        const key_end = std.mem.indexOfScalar(u8, self.target, '=') orelse {
            return null;
        };

        const value_start = key_end + 1;
        if (value_start >= self.target.len) {
            return null;
        }
        var value_end = std.mem.indexOfScalar(u8, self.target[1..], '&') orelse self.target.len - 1;
        value_end += 1;

        defer {
            if (value_end >= self.target.len) {
                self.target = &.{};
            } else {
                self.target = self.target[value_end..];
            }
        }

        return .{
            .key = self.target[key_start..key_end],
            .val = self.target[value_start..value_end],
        };
    }
};

pub const CookieIt = struct {
    const Cookie = struct {
        key: []const u8,
        val: []const u8,
    };

    line: []const u8,

    pub fn init(header_buf: []const u8) CookieIt {
        var it = std.mem.splitSequence(u8, header_buf, "\r\n");
        while (it.next()) |line| {
            const cookie_key = "cookie: ";
            if (std.ascii.startsWithIgnoreCase(line, cookie_key)) {
                return .{
                    // - 1 to avoid having to length check, space is included
                    // in key so it's essentially nothing
                    .line = line[cookie_key.len - 1 ..],
                };
            }
        }

        return .{
            .line = &.{},
        };
    }

    pub fn next(self: *CookieIt) ?Cookie {
        if (self.line.len == 0) {
            return null;
        }

        const key_end = std.mem.indexOfScalar(u8, self.line, '=') orelse {
            self.line = &.{};
            return null;
        };

        const val_start = key_end + 1;
        if (val_start >= self.line.len) {
            self.line = &.{};
            return null;
        }

        const val_end = if (std.mem.indexOfScalar(u8, self.line[val_start..], ';')) |idx| idx + val_start else self.line.len;

        const key_trimmed = std.mem.trim(u8, self.line[0..key_end], &std.ascii.whitespace);
        const val_trimmed = std.mem.trim(u8, self.line[val_start..val_end], &std.ascii.whitespace);

        defer {
            const new_start = val_end + 1;
            if (new_start >= self.line.len) {
                self.line = &.{};
            } else {
                self.line = self.line[new_start..];
            }
        }

        return .{
            .key = key_trimmed,
            .val = val_trimmed,
        };
    }
};
