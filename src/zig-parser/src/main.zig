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

pub fn main() !void {
    // 1. GeneralPurposeAllocator (Baseline Stufe 1)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2. ArenaAllocator initialisieren (Gegenstück zu Go's sync.Pool)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 3. CLI-Argumente in Zig 0.14.0 (Stabil & Sauber)
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Fehler: Bitte gib den Pfad zur Log-Datei an.\n", .{});
        std.debug.print("Nutzung: ./zig-parser-artefact <pfad-zur-logdatei>\n", .{});
        std.process.exit(1);
    }

    const file_path = args[1];

    std.debug.print("Starte Zig-Parser (Stufe 2: Speicheroptimierung)...\n", .{});
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

    // 5. Map für Statuscodes initialisieren
    var status_counts = [_]u64{0} ** 1000;
    var line_count: u64 = 0;
    var parse_error_count: u64 = 0;

    // 6. Hauptschleife: Zeilenweise lesen
    var i: usize = 0;
    while (i < ptr.len) {
        const line_start = i;
        while (i < ptr.len and ptr[i] != '\n') {
            i += 1;
        }

        const line = ptr[line_start..i];
        i += 1; // \n überspringen

        if (line.len == 0) continue;
        line_count += 1;

        // Zero-Copy Parsing
        if (parseLine(line)) |entry| {
            if (entry.status_code < 1000) {
                status_counts[entry.status_code] += 1;
            }
        } else |_| {
            parse_error_count += 1;
        }

        // Arena-Speicher zurücksetzen (behält reservierte Kapazität bei)
        // Dies entspricht funktional dem Zurücklegen/Resetten des Objekts im sync.Pool
        _ = arena.reset(.retain_capacity);
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
