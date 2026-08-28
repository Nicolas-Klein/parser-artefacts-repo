const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Win32 C-API BINDINGS
// ============================================================================
const WINAPI = std.os.windows.WINAPI;
const HANDLE = std.os.windows.HANDLE;
const LPVOID = std.os.windows.LPVOID;
const DWORD = std.os.windows.DWORD;
const BOOL = std.os.windows.BOOL;
const SIZE_T = usize;

extern "kernel32" fn CreateFileMappingA(
    hFile: HANDLE,
    lpFileMappingAttributes: ?*anyopaque,
    flProtect: DWORD,
    dwMaximumSizeHigh: DWORD,
    dwMaximumSizeLow: DWORD,
    lpName: ?[*:0]const u8,
) callconv(WINAPI) ?HANDLE;

extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: HANDLE,
    dwDesiredAccess: DWORD,
    dwFileOffsetHigh: DWORD,
    dwFileOffsetLow: DWORD,
    dwNumberOfBytesToMap: SIZE_T,
) callconv(WINAPI) ?LPVOID;

extern "kernel32" fn UnmapViewOfFile(
    lpBaseAddress: LPVOID,
) callconv(WINAPI) BOOL;

extern "kernel32" fn CloseHandle(
    hObject: HANDLE,
) callconv(WINAPI) BOOL;

inline fn fastParseInt(b: []const u8) u16 {
    var n: u16 = 0;

    for (b) |ch| {
        if (ch >= '0' and ch <= '9') {
            n = n * 10 + @as(u16, ch - '0');
        }
    }

    return n;
}

const ThreadResult = struct {
    counts: [1000]u64 = [_]u64{0} ** 1000,
    line_count: u64 = 0,
};

fn processChunk(data: []const u8, start_pos: usize, end_pos: usize, result: *ThreadResult) void {
    var start = start_pos;
    var end = end_pos;

    if (start > 0) {
        while (start < end and data[start - 1] != '\n') {
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

        if (line.len < 10) continue;
        result.line_count += 1;

        if (std.mem.lastIndexOfScalar(u8, line, '"')) |quote_pos| {
            const rest = line[quote_pos + 1 ..];
            var idx: usize = 0;

            while (idx < rest.len and rest[idx] == ' ') : (idx += 1) {}

            if (idx + 3 <= rest.len) {
                const code = fastParseInt(rest[idx .. idx + 3]);

                if (code < 1000) {
                    result.counts[code] += 1;
                }
            }
        }
    }
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

    const start_time = std.time.nanoTimestamp();

    const cpu_count = std.Thread.getCpuCount() catch 1;
    std.debug.print("Starte Zig-Parser (Stufe 3: Multi-Threading mit {d} Cores)...\n", .{cpu_count});

    // 3. Datei öffnen
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    if (file_size == 0) return;

    // Memmory Mapping (mmap)

    var ptr: []const u8 = undefined;

    if (builtin.os.tag == .windows) {
        const PAGE_READONLY: DWORD = 0x02;
        const FILE_MAP_READ: DWORD = 0x04;

        const handle = CreateFileMappingA(
            file.handle,
            null,
            PAGE_READONLY,
            0,
            0,
            null,
        ) orelse return error.CreateFileMappingFailed;
        defer _ = CloseHandle(handle);

        const mapped_ptr = MapViewOfFile(
            handle,
            FILE_MAP_READ,
            0,
            0,
            file_size,
        ) orelse return error.MapViewOfFileFailed;

        const bytes_ptr: [*]const u8 = @ptrCast(mapped_ptr);
        ptr = bytes_ptr[0..file_size];
    } else {
        ptr = try std.posix.mmap(
            null,
            file_size,
            std.posix.PROT.READ,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
    }

    defer {
        if (builtin.os.tag == .windows) {
            _ = UnmapViewOfFile(@constCast(@ptrCast(ptr.ptr)));
        } else {
            std.posix.munmap(ptr);
        }
    }

    const threads = try allocator.alloc(std.Thread, cpu_count);
    defer allocator.free(threads);

    const results = try allocator.alloc(ThreadResult, cpu_count);
    defer allocator.free(results);

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

    for (results) |res| {
        total_line_count += res.line_count;
        for (res.counts, 0..) |count, code| {
            total_status_counts[code] += count;
        }
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ms = @divTrunc(end_time - start_time, std.time.ns_per_ms);

    // 6. Ergebnisse ausgeben
    std.debug.print("\n--- Parsing abgeschlossen ---\n", .{});
    std.debug.print("Verarbeitete Zeilen: {d}\n", .{total_line_count});
    std.debug.print("Benötigte Zeit:      {d} ms\n", .{elapsed_ms});
    std.debug.print("Statuscode-Statistik:\n", .{});

    for (total_status_counts, 0..) |count, code| {
        if (count > 0) {
            std.debug.print("    HTTP {d}: {d}\n", .{ code, count });
        }
    }
}
