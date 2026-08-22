const std = @import("std");

pub const LogEntry = struct {
    remote_host: []const u8,
    identity: []const u8,
    user: []const u8,
    timestamp: []const u8,
    request: []const u8,
    status_code: u16,
    bytes_sent: u64,
};

// Allokationsfreies Integer-Parsing für Byte-Slices
inline fn fastParseInt(b: []const u8) u16 {
    var n: u16 = 0;
    for (b) |ch| {
        if (ch >= '0' and ch <= '9') {
            n = n * 10 + @as(u16, ch - '0');
        }
    }
    return n;
}

fn parseLine(line: []const u8) !LogEntry {
    const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse return error.InvalidFormat;
    const last_quote = std.mem.lastIndexOfScalar(u8, line, '"') orelse return error.InvalidFormat;

    if (first_quote >= last_quote) return error.InvalidFormat;

    const prefix = line[0..first_quote];
    const request = line[first_quote + 1 .. last_quote];
    const suffix = line[last_quote + 1 ..];

    // 1. Prefix zerlegen (Host, Identity, User, Timestamp)
    var idx: usize = 0;

    // RemoteHost
    var start = idx;
    while (idx < prefix.len and prefix[idx] != ' ') : (idx += 1) {}
    if (idx >= prefix.len) return error.InvalidFormat;
    const remote_host = prefix[start..idx];
    idx += 1;

    // Identity
    start = idx;
    while (idx < prefix.len and prefix[idx] != ' ') : (idx += 1) {}
    if (idx >= prefix.len) return error.InvalidFormat;
    const identity = prefix[start..idx];
    idx += 1;

    // User
    start = idx;
    while (idx < prefix.len and prefix[idx] != ' ') : (idx += 1) {}
    if (idx >= prefix.len) return error.InvalidFormat;
    const user = prefix[start..idx];
    idx += 1;

    // Timestamp
    const timestamp = std.mem.trim(u8, prefix[idx..], " ");

    // 2. Suffix zerlegen (Statuscode & BytesSent)
    idx = 0;
    while (idx < suffix.len and suffix[idx] == ' ') : (idx += 1) {}
    start = idx;
    while (idx < suffix.len and suffix[idx] != ' ') : (idx += 1) {}
    if (start == idx) return error.InvalidFormat;

    const status_code = fastParseInt(suffix[start..idx]);

    // BytesSent
    var bytes_sent: u64 = 0;
    while (idx < suffix.len and suffix[idx] == ' ') : (idx += 1) {}
    if (idx < suffix.len and suffix[idx] != '-') {
        bytes_sent = fastParseInt(suffix[idx..]);
    }

    return LogEntry{
        .remote_host = remote_host,
        .identity = identity,
        .user = user,
        .timestamp = timestamp,
        .request = request,
        .status_code = status_code,
        .bytes_sent = bytes_sent,
    };
}

const ThreadResult = struct {
    counts: [1000]u64 = [_]u64{0} ** 1000,
    line_count: u64 = 0,
    parse_error_count: u64 = 0,
};

fn processChunk(data: []const u8, start_pos: usize, end_pos: usize, result: *ThreadResult) void {
    var start = start_pos;
    var end = end_pos;

    if (start > 0) {
        while (start < data.len and data[start - 1] != '\n') {
            start += 1;
        }
    }

    if (end < data.len) {
        while (end < data.len and data[end - 1] != '\n') {
            end += 1;
        }
    }

    var i = start;
    while (i < end) {
        const line_start = i;
        while (i < end and data[i] != '\n') {
            i += 1;
        }

        const line = data[line_start..i];
        i += 1;

        if (line.len == 0) continue;

        if (parseLine(line)) |entry| {
            if (entry.status_code < 1000) {
                result.counts[entry.status_code] += 1;
                result.line_count += 1;
            }
        } else |_| {
            result.parse_error_count += 1;
        }
    }
}

pub fn main() !void {
    // 1. GeneralPurposeAllocator (Baseline Stufe 1)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2. ArenaAllocator initialisieren (Gegenstück zu Go's sync.Pool)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    // 3. CLI-Argumente in Zig 0.14.0 (Stabil & Sauber)
    const args = try std.process.argsAlloc(arena_allocator);

    if (args.len < 2) {
        std.debug.print("Fehler: Bitte gib den Pfad zur Log-Datei an.\n", .{});
        std.debug.print("Nutzung: ./zig-parser-artefact <pfad-zur-logdatei>\n", .{});
        std.process.exit(1);
    }

    const file_path = args[1];

    const cpu_count = std.Thread.getCpuCount() catch 1;
    std.debug.print("Starte Zig-Parser (Stufe 3: Multi-Threading mit {d} Cores - Full Struct)...\n", .{cpu_count});
    const start_time = std.time.nanoTimestamp();

    // 4. Datei öffnen
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    if (file_size == 0) return;

    const ptr = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
    defer std.posix.munmap(ptr);

    const threads = try arena_allocator.alloc(std.Thread, cpu_count);

    const results = try arena_allocator.alloc(ThreadResult, cpu_count);

    for (results) |*res| {
        res.* = ThreadResult{};
    }

    const chunk_size = file_size / cpu_count;

    for (0..cpu_count) |w| {
        const start = w * chunk_size;
        var end = start + chunk_size;
        if (w == cpu_count - 1) {
            end = file_size;
        }

        threads[w] = try std.Thread.spawn(.{}, processChunk, .{ ptr, start, end, &results[w] });
    }

    for (threads) |thread| {
        thread.join();
    }

    var total_status_counts = [_]u64{0} ** 1000;
    var total_line_count: u64 = 0;
    var total_error_count: u64 = 0;

    for (results) |res| {
        total_line_count += res.line_count;
        total_error_count += res.parse_error_count;
        for (res.counts, 0..) |count, code| {
            total_status_counts[code] += count;
        }
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ms = @divTrunc(end_time - start_time, std.time.ns_per_ms);

    // 6. Ergebnisse ausgeben
    std.debug.print("\n--- Parsing abgeschlossen ---\n", .{});
    std.debug.print("Verarbeitete Zeilen: {d} (Fehlerhaft: {d})\n", .{ total_line_count, total_error_count });
    std.debug.print("Benötigte Zeit:      {d} ms\n", .{elapsed_ms});
    std.debug.print("Statuscode-Statistik:\n", .{});

    for (total_status_counts, 0..) |count, code| {
        if (count > 0) {
            std.debug.print("   HTTP {d}: {d}\n", .{ code, count });
        }
    }
}
