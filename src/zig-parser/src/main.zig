const std = @import("std");

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

    std.debug.print("Starte Zig-Parser (Stufe 1: Baseline)...\n", .{});
    const start_time = std.time.nanoTimestamp();

    // 3. Datei öffnen
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // 4. Map für Statuscodes initialisieren
    var status_counts = std.AutoHashMap(u16, u64).init(allocator);
    defer status_counts.deinit();

    var line_count: u64 = 0;
    var line_buf: [4096]u8 = undefined;

    var buf_reader = std.io.bufferedReader(file.reader());
    var reader = buf_reader.reader();

    // 5. Hauptschleife: Zeilenweise lesen
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        line_count += 1;

        var it = std.mem.splitScalar(u8, line, ' ');
        var token_index: usize = 0;

        while (it.next()) |token| {
            if (token_index == 8) {
                if (std.fmt.parseInt(u16, token, 10)) |code| {
                    const entry = try status_counts.getOrPut(code);
                    if (entry.found_existing) {
                        entry.value_ptr.* += 1;
                    } else {
                        entry.value_ptr.* = 1;
                    }
                } else |_| {}
                break;
            }
            token_index += 1;
        }
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ms = @divTrunc(end_time - start_time, std.time.ns_per_ms);

    // 6. Ergebnisse ausgeben
    std.debug.print("\n--- Parsing abgeschlossen ---\n", .{});
    std.debug.print("Verarbeitete Zeilen: {d}\n", .{line_count});
    std.debug.print("Benötigte Zeit:      {d} ms\n", .{elapsed_ms});
    std.debug.print("Statuscode-Statistik:\n", .{});

    var map_it = status_counts.iterator();
    while (map_it.next()) |entry| {
        std.debug.print("    HTTP {d}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}
