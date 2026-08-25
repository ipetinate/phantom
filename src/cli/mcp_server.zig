const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const global = @import("../global.zig");

pub const Options = struct {
    // The socket to connect to. Normally discovered from the environment;
    // this exists for an install where that is not set, and for testing
    // against a specific build.
    socket: ?[]const u8 = null,

    // What to call ourselves in the permission prompt the reader sees.
    // Untrusted by the app: it names the caller and decides nothing.
    client: ?[]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    // Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `mcp-server` command speaks MCP on stdin and stdout, and relays it to
/// the running Phantom.
///
/// This is the whole of the client half, and it is a pipe on purpose. The app
/// is where every question is actually answered — it owns the terminals, the
/// windows and the reader's attention — so putting anything but the handshake
/// here would be a second copy of the truth to keep in step across an update.
///
/// A **stdio** server rather than an HTTP one, and a Unix socket underneath
/// rather than a port. Three reasons, in the order they mattered: stdio is
/// the only transport every MCP client supports; a socket's access control is
/// the filesystem's, where a port's is a token in a config file that agents
/// print in their own logs; and the connection's peer credentials let the app
/// *verify* which terminal is calling instead of believing what it claims.
///
/// Flags:
///
///   * `--socket=<path>`: connect to a specific socket instead of the one in
///     `PHANTOM_MCP_SOCKET`.
///
///   * `--client=<name>`: what to call this client in the permission prompt.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    if (comptime !builtin.target.os.tag.isDarwin()) {
        try writeAll(std.posix.STDERR_FILENO, "The MCP server is macOS only.\n");
        return 1;
    }

    const path = opts.socket orelse environment("PHANTOM_MCP_SOCKET") orelse {
        try writeAll(std.posix.STDERR_FILENO,
            \\Phantom's MCP socket was not found.
            \\
            \\PHANTOM_MCP_SOCKET is exported into every terminal Phantom opens, so
            \\this usually means the command is running somewhere else. Start the
            \\agent from a Phantom terminal, or pass --socket=<path>.
            \\
        );
        return 1;
    };

    const server = std.posix.system.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
    );
    if (server < 0) {
        try writeAll(std.posix.STDERR_FILENO, "Could not create a socket.\n");
        return 1;
    }
    defer _ = std.posix.system.close(server);

    // Built by hand rather than through a helper: `sun_path` is a fixed
    // array and the path either fits in it or the address is invalid, which
    // is a case worth saying out loud rather than truncating into.
    var address: std.posix.sockaddr.un = .{ .path = undefined };
    @memset(&address.path, 0);

    if (path.len >= address.path.len) {
        try writeAll(std.posix.STDERR_FILENO, "That socket path is too long.\n");
        return 1;
    }
    @memcpy(address.path[0..path.len], path);

    const address_size: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
    const connected = std.posix.system.connect(
        server,
        @ptrCast(&address),
        address_size,
    );

    if (connected != 0) {
        try writeAll(std.posix.STDERR_FILENO,
            \\Phantom is not listening on its MCP socket.
            \\
            \\The socket is created when Phantom starts and removed when it quits,
            \\so this usually means the app is not running.
            \\
        );
        return 1;
    }

    if (!try greet(server, opts.client)) return 1;

    try relay(server);
    return 0;
}

/// Says who we are, and reads the app's answer.
///
/// The tab is claimed by handing over the path in `GHOSTTY_TAB_STATE_FILE`,
/// whose last component is the surface's id. The app does not take that on
/// trust — it checks the connection's peer credentials against the pid below
/// — but sending it is what lets the app tell "a tab of mine" from "some
/// other terminal", which is what every permission is measured against.
fn greet(server: std.posix.socket_t, client: ?[]const u8) !bool {
    const tab = environment("GHOSTTY_TAB_STATE_FILE");

    // A fixed buffer rather than an allocator: this message is one line with
    // four fields, and the only variable-length parts are a path and a name
    // that a filesystem already bounds.
    var buffer: [8192]u8 = undefined;
    var used: usize = 0;

    used += append(&buffer, used, "{\"version\":1,\"pid\":");

    var digits: [24]u8 = undefined;
    const pid = std.fmt.bufPrint(&digits, "{d}", .{std.posix.system.getpid()}) catch return false;
    used += append(&buffer, used, pid);

    if (tab) |value| {
        used += append(&buffer, used, ",\"tabStateFile\":\"");
        used += appendEscaped(&buffer, used, value);
        used += append(&buffer, used, "\"");
    }

    used += append(&buffer, used, ",\"client\":\"");
    used += appendEscaped(&buffer, used, client orelse "mcp client");
    used += append(&buffer, used, "\"}\n");

    try writeAll(server, buffer[0..used]);

    // The answer is one line, and small: a refusal carries a sentence meant
    // for a person, and nothing here is streamed.
    var answer: [4096]u8 = undefined;
    const count = std.posix.system.read(server, &answer, answer.len);
    if (count <= 0) {
        try writeAll(std.posix.STDERR_FILENO, "Phantom closed the connection.\n");
        return false;
    }

    // Looked for rather than parsed. This is the one message where a parser
    // would be a second implementation of a contract that only ever says one
    // of two things, and where being wrong means failing to show the reader
    // why they were refused.
    const line = answer[0..@intCast(count)];
    if (std.mem.indexOf(u8, line, "\"ok\":true") != null) return true;

    try writeAll(std.posix.STDERR_FILENO, "Phantom refused the connection: ");
    try writeAll(std.posix.STDERR_FILENO, line);
    try writeAll(std.posix.STDERR_FILENO, "\n");
    return false;
}

/// Copies into the buffer at an offset, answering how much it wrote. A
/// message that would not fit is truncated rather than written past the end
/// — the app refuses a hello it cannot read, which is the safe outcome.
fn append(buffer: []u8, at: usize, bytes: []const u8) usize {
    if (at >= buffer.len) return 0;
    const room = @min(bytes.len, buffer.len - at);
    @memcpy(buffer[at..][0..room], bytes[0..room]);
    return room;
}

/// The same, with the two characters that would end a JSON string early.
/// A path can hold either, and a client name is whatever the agent called
/// itself.
fn appendEscaped(buffer: []u8, at: usize, bytes: []const u8) usize {
    var used: usize = 0;
    for (bytes) |byte| {
        switch (byte) {
            '"', '\\' => {
                used += append(buffer, at + used, &[_]u8{'\\'});
                used += append(buffer, at + used, &[_]u8{byte});
            },
            // Control characters are not legal unescaped in JSON and have no
            // business in a path this app wrote.
            0...0x1f => {},
            else => used += append(buffer, at + used, &[_]u8{byte}),
        }
    }
    return used;
}

/// Copies bytes both ways until either end closes.
///
/// No framing and no buffering of whole messages: MCP over stdio is one JSON
/// object per line and the app speaks the same, so anything this touched
/// would be a chance to corrupt a message that was already correct.
fn relay(server: std.posix.socket_t) !void {
    var fds = [_]std.posix.pollfd{
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = server, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var buffer: [64 * 1024]u8 = undefined;

    while (true) {
        if (std.posix.system.poll(&fds, fds.len, -1) < 0) return;

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const count = std.posix.system.read(std.posix.STDIN_FILENO, &buffer, buffer.len);
            if (count <= 0) return;
            try writeAll(server, buffer[0..@intCast(count)]);
        }

        if (fds[1].revents & std.posix.POLL.IN != 0) {
            const count = std.posix.system.read(server, &buffer, buffer.len);
            if (count <= 0) return;
            try writeAll(std.posix.STDOUT_FILENO, buffer[0..@intCast(count)]);
        }

        // A hangup on either side ends the session. Without this the loop
        // spins on a closed descriptor that polls ready forever.
        if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return;
        if (fds[1].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return;
    }
}

/// One environment variable, as a slice.
///
/// `std.posix.system.getenv` answers a null-terminated pointer, and every
/// caller here wants a slice — the length is measured once rather than at
/// each use.
fn environment(name: [*:0]const u8) ?[]const u8 {
    const value = std.posix.system.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}

/// A short write is not an error and not the whole message, so every write
/// here loops until the bytes are gone.
fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const count = std.posix.system.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (count <= 0) return;
        sent += @intCast(count);
    }
}
