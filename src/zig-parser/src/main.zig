const std = @import("std");

inline fn fastParseInt(b: []const u8) u16 {
    var n: u16 = 0;

    for (b) |ch| {
        if (ch >= '0' and ch <= '9') {
            n = n * 10 + @as(u16, ch - '0');
        }
    }

    return n;
}

pub fn main() !void {
    // 1. GeneralPurposeAllocator (Baseline Stufe 1)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2. CLI-Argumente in Zig 0.14.0 (Stabil & Sauber)
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Fehler: Bitte gib den Pfad zur Log-Datei an.\n", .{});
        std.debug.print("Nutzung: ./zig-parser-artefact <pfad-zur-logdatei>\n", .{});
        std.process.exit(1);
    }

    const file_path = args[1];

    std.debug.print("Starte Zig-Parser (Stufe 2: Zero-Copy & mmap)...\n", .{});
    const start_time = std.time.nanoTimestamp();

    // 3. Datei öffnen
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    if (file_size == 0) return;

    // Memmory Mapping (mmap)

    const ptr = try std.posix.mmap(null, file_size, std.posix.PROT.READ, .{ .TYPE = .SHARED }, file.handle, 0);
    defer std.posix.munmap(ptr);

    // Stack-basiertes Lookup-Array
    var status_counts = [_]u64{0} ** 1000;
    var line_count: u64 = 0;

    // Zeilen-Iterator über den mmap-Speicher (Stufe 2a)
    var line_iter = std.mem.splitScalar(u8, ptr, '\n');

    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;

        // --- Dein Vorwärts-Parsing für das 9. Token (Stufe 2a) ---
        var space_count: u8 = 0;
        var token_start: usize = 0;
        var found_status = false;

        var j: usize = 0;
        while (j < line.len) : (j += 1) {
            if (line[j] == ' ') {
                if (space_count == 8) {
                    const code = fastParseInt(line[token_start..j]);
                    if (code < 1000) {
                        status_counts[code] += 1;
                    }
                    found_status = true;
                    break;
                }
                space_count += 1;
                token_start = j + 1;
            }
        }

        if (!found_status and space_count == 8) {
            const code = fastParseInt(line[token_start..]);
            if (code < 1000) {
                status_counts[code] += 1;
            }
        }
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ms = @divTrunc(end_time - start_time, std.time.ns_per_ms);

    // 6. Ergebnisse ausgeben
    std.debug.print("\n--- Parsing abgeschlossen ---\n", .{});
    std.debug.print("Verarbeitete Zeilen: {d}\n", .{line_count});
    std.debug.print("Benötigte Zeit:      {d} ms\n", .{elapsed_ms});
    std.debug.print("Statuscode-Statistik:\n", .{});

    for (status_counts, 0..) |count, code| {
        if (count > 0) {
            std.debug.print("    HTTP {d}: {d}\n", .{ code, count });
        }
    }
}
