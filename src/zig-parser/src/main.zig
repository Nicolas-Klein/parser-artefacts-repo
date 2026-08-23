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

fn parseLine(line: []const u8, allocator: std.mem.Allocator) !LogEntry {
    const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse return error.InvalidFormat;
    const last_quote = std.mem.lastIndexOfScalar(u8, line, '"') orelse return error.InvalidFormat;

    if (first_quote >= last_quote) return error.InvalidFormat;

    const prefix = line[0..first_quote];
    const request_slice = line[first_quote + 1 .. last_quote];
    const suffix = line[last_quote + 1 ..];

    var prefix_iter = std.mem.tokenizeScalar(u8, prefix, ' ');
    const host_slice = prefix_iter.next() orelse return error.InvalidFormat;
    const id_slice = prefix_iter.next() orelse return error.InvalidFormat;
    const user_slice = prefix_iter.next() orelse return error.InvalidFormat;
    const ts_slice = std.mem.trim(u8, prefix_iter.rest(), " ");

    var suffix_iter = std.mem.tokenizeScalar(u8, suffix, ' ');
    const status_str = suffix_iter.next() orelse return error.InvalidFormat;
    const status_code = try std.fmt.parseInt(u16, status_str, 10);

    var bytes_sent: u64 = 0;
    if (suffix_iter.next()) |bytes_str| {
        if (!std.mem.eql(u8, bytes_str, "-")) {
            bytes_sent = std.fmt.parseInt(u64, bytes_str, 10) catch 0;
        }
    }

    return LogEntry{
        .remote_host = try allocator.dupe(u8, host_slice),
        .identity = try allocator.dupe(u8, id_slice),
        .user = try allocator.dupe(u8, user_slice),
        .timestamp = try allocator.dupe(u8, ts_slice),
        .request = try allocator.dupe(u8, request_slice),
        .status_code = status_code,
        .bytes_sent = bytes_sent,
    };
}

pub fn main() !void {
    // 1. GeneralPurposeAllocator (Baseline Stufe 1)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var line_arena = std.heap.ArenaAllocator.init(allocator);
    defer line_arena.deinit();
    const arena_allocator = line_arena.allocator();

    // 2. CLI-Argumente in Zig 0.14.0 (Stabil & Sauber)
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Fehler: Bitte gib den Pfad zur Log-Datei an.\n", .{});
        std.debug.print("Nutzung: ./zig-parser-artefact <pfad-zur-logdatei>\n", .{});
        std.process.exit(1);
    }

    const file_path = args[1];

    std.debug.print("Starte Zig-Parser (Stufe 1: Baseline)...\n", .{});
    const start_time = std.time.nanoTimestamp();

    // 3. Datei öffnen
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // 4. Map für Statuscodes initialisieren
    var status_counts = [_]u64{0} ** 1000;
    var line_count: u64 = 0;
    var parse_error_count: u64 = 0;

    var line_buf: [4096]u8 = undefined;
    var buf_reader = std.io.bufferedReader(file.reader());
    var reader = buf_reader.reader();

    // 5. Hauptschleife: Zeilenweise lesen
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        line_count += 1;

        if (parseLine(line, arena_allocator)) |entry| {
            if (entry.status_code < 1000) {
                status_counts[entry.status_code] += 1;
            }
        } else |_| {
            parse_error_count += 1;
        }

        _ = line_arena.reset(.retain_capacity);
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ms = @divTrunc(end_time - start_time, std.time.ns_per_ms);

    // 6. Ergebnisse ausgeben
    std.debug.print("\n--- Parsing abgeschlossen ---\n", .{});
    std.debug.print("Verarbeitete Zeilen: {d} (Fehlerhaft: {d})\n", .{ line_count, parse_error_count });
    std.debug.print("Benötigte Zeit:      {d} ms\n", .{elapsed_ms});
    std.debug.print("Statuscode-Statistik:\n", .{});

    for (status_counts, 0..) |count, code| {
        if (count > 0) {
            std.debug.print("   HTTP {d}: {d}\n", .{ code, count });
        }
    }
}
