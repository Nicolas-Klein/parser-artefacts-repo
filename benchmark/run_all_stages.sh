#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_FILE="$PROJECT_ROOT/generator/benchmark_large.log"
RESULTS_DIR="$SCRIPT_DIR/results"
SUMMARY_FILE="$RESULTS_DIR/master_summary.md"

# Temporäre Dateien für die getrennten Tabellen
SUMMARY_TIME="$RESULTS_DIR/summary_time.md"
SUMMARY_SYS="$RESULTS_DIR/summary_sys.md"
SUMMARY_GC="$RESULTS_DIR/summary_gc.md"
SUMMARY_PMAP="$RESULTS_DIR/summary_pmap.md"

# Die zu testenden Tags in exakter Reihenfolge
TAGS=("new-stage1" "new-stage2" "new-stage3")

mkdir -p "$RESULTS_DIR"

# Tool-Abhängigkeiten prüfen
for cmd in hyperfine python3 /usr/bin/time pmap; do
    if ! command -v "$cmd" &> /dev/null && [ ! -x "$cmd" ]; then
        echo "Fehler: '$cmd' ist nicht installiert oder nicht im PATH."
        exit 1
    fi
done

if [ ! -f "$LOG_FILE" ]; then
    echo "Fehler: Benchmark-Logfile unter $LOG_FILE nicht gefunden!"
    exit 1
fi

echo "=================================================="
echo " STARTE MASTER-BENCHMARK ÜBER ALLE STUFEN"
echo "=================================================="

# Aktuellen Git-Zustand sichern
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Aktueller Branch: $ORIGINAL_BRANCH (wird gesichert)"
git stash push -m "Automated master benchmark temporary stash" > /dev/null 2>&1 || true

cleanup() {
    echo ""
    echo "Füge Tabellen zusammen und kehre zum Branch zurück..."
    
    # Füge Laufzeit, System-Metriken, GC und Pmap in einer Datei zusammen
    cat "$SUMMARY_TIME" > "$SUMMARY_FILE"
    echo -e "\n<br>\n" >> "$SUMMARY_FILE"
    cat "$SUMMARY_SYS" >> "$SUMMARY_FILE"
    echo -e "\n<br>\n" >> "$SUMMARY_FILE"
    cat "$SUMMARY_GC" >> "$SUMMARY_FILE"
    echo -e "\n<br>\n" >> "$SUMMARY_FILE"
    [ -f "$SUMMARY_PMAP" ] && cat "$SUMMARY_PMAP" >> "$SUMMARY_FILE"
    
    # Aufräumen der temporären Dateien
    rm -f "$SUMMARY_TIME" "$SUMMARY_SYS" "$SUMMARY_GC" "$SUMMARY_PMAP"
    
    git checkout "$ORIGINAL_BRANCH" > /dev/null 2>&1 || true
    git stash pop > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Tabellenköpfe initialisieren
cat <<EOF > "$SUMMARY_TIME"
# 1. Gesamtauswertung: Laufzeit (Go vs. Zig)
Gemessen mit \`hyperfine\` (10 Durchläufe, 3 Warmups).

| Stufe / Tag | Sprache | Mean Time (ms) | StdDev (ms) | Min (ms) | Max (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- |
EOF

cat <<EOF > "$SUMMARY_SYS"
# 2. System- & Prozess-Metriken (Linux)
Gemessen via \`/usr/bin/time -v\`.

| Stufe / Tag | Sprache | Max RAM (MB) | User CPU Time (ms) | Kernel/System CPU Time (ms) | Total CPU Time (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- |
EOF

cat <<EOF > "$SUMMARY_GC"
# 3. Go Garbage Collector Auswertung (GCTRACE)
Gemessen via \`GODEBUG=gctrace=1\`.

| Stufe / Tag | GC Runs (Anzahl) | Total GC Pause (ms) | Avg GC Pause / Run (ms) | Peak Heap before GC (MB) |
| :--- | :--- | :--- | :--- | :--- |
EOF

cat <<EOF > "$SUMMARY_PMAP"
# 4. Speicheranalyse via pmap / smaps (Linux)
Erfasst via \`/proc/[PID]/smaps\` (Werte in Megabyte / MB).

| Stufe / Tag | Sprache | Mapped File Size (MB) | Mapped File WS (MB) | Heap WS (MB) | Private Data Size (MB) | Total Working Set (MB) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
EOF

# Hilfsfunktion für Systemmetriken
measure_sys_metrics() {
    local LANG_NAME=$1
    local BIN_PATH=$2
    local TAG_NAME=$3

    echo "  > Erfasse Prozess-Metriken (User/Kernel CPU Time & RAM) für $LANG_NAME..."

    local TMP_TIME="$RESULTS_DIR/time_${LANG_NAME}_${TAG_NAME}.txt"

    /usr/bin/time -v "$BIN_PATH" "$LOG_FILE" > /dev/null 2> "$TMP_TIME"
    
    python3 - "$TMP_TIME" "$TAG_NAME" "$LANG_NAME" "$SUMMARY_SYS" <<'END'
import sys

time_file = sys.argv[1]
tag = sys.argv[2]
lang = sys.argv[3]
summary_sys = sys.argv[4]

user_sec = 0.0
sys_sec = 0.0
max_ram_kb = 0.0

with open(time_file) as f:
    for line in f:
        if "User time (seconds):" in line:
            user_sec = float(line.split(":")[-1].strip())
        elif "System time (seconds):" in line:
            sys_sec = float(line.split(":")[-1].strip())
        elif "Maximum resident set size" in line:
            max_ram_kb = float(line.split(":")[-1].strip())

user_ms = round(user_sec * 1000, 1)
kernel_ms = round(sys_sec * 1000, 1)
total_cpu_ms = round(user_ms + kernel_ms, 1)
max_ram_mb = round(max_ram_kb / 1024, 2)

out_line = f"| {tag} | {lang} | {max_ram_mb} | {user_ms} | {kernel_ms} | {total_cpu_ms} |\n"

with open(summary_sys, 'a') as f:
    f.write(out_line)
END
}

measure_pmap_metrics() {
    local LANG_NAME=$1
    local BIN_PATH=$2
    local TAG_NAME=$3

    echo "  > Erfasse pmap / smaps Speicherlayout für $LANG_NAME..."

    # BENCHMARK_PAUSE aktivieren, damit schnelle Artefakte am Ende der main() nicht sofort terminieren
    export BENCHMARK_PAUSE=1

    # 1. Prozess im Hintergrund starten
    "$BIN_PATH" "$LOG_FILE" > /dev/null 2>&1 &
    local TARGET_PID=$!

    # 2. Polling: Warten bis VmRSS > 0 ist (max 100ms)
    local count=0
    while [ $count -lt 100 ]; do
        if [ -d "/proc/$TARGET_PID" ]; then
            local rss=$(grep -i "VmRSS:" "/proc/$TARGET_PID/status" 2>/dev/null | awk '{print $2}')
            if [ -n "$rss" ] && [ "$rss" -gt 0 ]; then
                break
            fi
        fi
        sleep 0.001
        count=$((count + 1))
    done

    # 3. Python liest /proc/[PID]/smaps aus
    python3 - "$TARGET_PID" "$TAG_NAME" "$LANG_NAME" "$SUMMARY_PMAP" <<'END'
import sys
import os
import re

pid = sys.argv[1]
tag = sys.argv[2]
lang = sys.argv[3]
summary_pmap = sys.argv[4]

smaps_path = f"/proc/{pid}/smaps"

mapped_size, mapped_ws = 0.0, 0.0
heap_ws = 0.0
private_size, private_ws = 0.0, 0.0
total_ws = 0.0

if os.path.exists(smaps_path):
    try:
        with open(smaps_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

        for block in content.split("\n\n"):
            lines = block.split("\n")
            if not lines or not lines[0]:
                continue
            
            header = lines[0]
            match_path = re.search(r'/[^\s]+', header)
            filepath = match_path.group(0) if match_path else ""

            size_kb, rss_kb, priv_dirty_kb, priv_clean_kb = 0, 0, 0, 0

            for line in lines[1:]:
                if line.startswith("Size:"):
                    size_kb = int(line.split()[1])
                elif line.startswith("Rss:"):
                    rss_kb = int(line.split()[1])
                elif line.startswith("Private_Dirty:"):
                    priv_dirty_kb = int(line.split()[1])
                elif line.startswith("Private_Clean:"):
                    priv_clean_kb = int(line.split()[1])

            total_ws += rss_kb
            priv_total = priv_dirty_kb + priv_clean_kb
            private_ws += priv_total
            private_size += size_kb

            if "[heap]" in header:
                heap_ws += rss_kb
            elif filepath and not filepath.endswith(".so") and "/bin/" not in filepath and "go-parser" not in filepath and "zig-parser" not in filepath:
                mapped_size += size_kb
                mapped_ws += rss_kb

        # Fallback falls mapped_ws 0.0, aber Total vorhanden ist (Zero-Copy Paging)
        if mapped_ws == 0.0 and total_ws > 0.0:
            mapped_ws = max(0.0, total_ws - heap_ws - private_ws)

        out_line = f"| {tag} | {lang} | {mapped_size/1024.0:.1f} | {mapped_ws/1024.0:.1f} | {heap_ws/1024.0:.2f} | {private_size/1024.0:.1f} | {total_ws/1024.0:.1f} |\n"
        with open(summary_pmap, "a", encoding="utf-8") as f:
            f.write(out_line)

    except Exception as e:
        print(f"  [pmap error] {e}")

END

    # 4. Nach der Messung den Prozess bei Bedarf beenden und Aufräumen
    unset BENCHMARK_PAUSE
    kill -9 "$TARGET_PID" 2>/dev/null || true
    wait "$TARGET_PID" 2>/dev/null || true
}

# Hilfsfunktion für Go GC Trace Metriken
measure_go_gc() {
    local BIN_PATH=$1
    local TAG_NAME=$2

    echo "  > Erfasse Go GC-Trace (GODEBUG=gctrace=1)..."

    local GC_LOG="$RESULTS_DIR/gc_${TAG_NAME}.log"

    GODEBUG=gctrace=1 "$BIN_PATH" "$LOG_FILE" > /dev/null 2> "$GC_LOG"

    python3 - "$GC_LOG" "$TAG_NAME" "$SUMMARY_GC" <<'END'
import sys
import re

gc_log = sys.argv[1]
tag = sys.argv[2]
summary_gc = sys.argv[3]

gc_count = 0
total_clock_ms = 0.0
max_heap_mb = 0.0

pattern = re.compile(r'gc (\d+).*?: ([\d\.\+]+) ms clock, ([\d\.\+/]+) ms cpu, (\d+)->(\d+)->(\d+) MB')

try:
    with open(gc_log) as f:
        for line in f:
            match = pattern.search(line)
            if match:
                gc_count += 1
                clock_parts = [float(x) for x in match.group(2).split('+')]
                total_clock_ms += sum(clock_parts)
                heap_before = float(match.group(4))
                if heap_before > max_heap_mb:
                    max_heap_mb = heap_before
except Exception:
    pass

avg_pause = round(total_clock_ms / gc_count, 3) if gc_count > 0 else 0.0
total_clock_ms = round(total_clock_ms, 2)

out_line = f"| {tag} | {gc_count} | {total_clock_ms} | {avg_pause} | {max_heap_mb:.2f} |\n"

with open(summary_gc, 'a') as f:
    f.write(out_line)
END
}

# Durch alle Tags iterieren
for TAG in "${TAGS[@]}"; do
    echo ""
    echo "--------------------------------------------------"
    echo " 🚀 Verarbeite Git-Tag: $TAG"
    echo "--------------------------------------------------"

    git checkout --force "$TAG" --quiet

    echo "Kompiliere Go-Parser..."
    (cd "$PROJECT_ROOT/src/go-parser" && go build -o go-parser-artefact main.go)

    echo "Kompiliere Zig-Parser..."
    (cd "$PROJECT_ROOT/src/zig-parser" && zig build-exe src/main.zig -O ReleaseFast --name zig-parser-artefact)

    GO_BIN="$PROJECT_ROOT/src/go-parser/go-parser-artefact"
    ZIG_BIN="$PROJECT_ROOT/src/zig-parser/zig-parser-artefact"
    JSON_OUT="$RESULTS_DIR/results_${TAG}.json"

    # 1. System & Process Metriken erfassen
    measure_sys_metrics "Go" "$GO_BIN" "$TAG"
    measure_sys_metrics "Zig" "$ZIG_BIN" "$TAG"
    
    # 2. Memory Mapping via pmap/smaps erfassen
    measure_pmap_metrics "Go" "$GO_BIN" "$TAG"
    measure_pmap_metrics "Zig" "$ZIG_BIN" "$TAG"

    # 3. Go GC Trace erfassen
    measure_go_gc "$GO_BIN" "$TAG"

    # 4. Hyperfine-Messung
    echo "  > Starte Hyperfine..."
    hyperfine \
      --warmup 3 \
      --runs 10 \
      --export-json "$JSON_OUT" \
      --command-name "Go ($TAG)" "$GO_BIN $LOG_FILE" \
      --command-name "Zig ($TAG)" "$ZIG_BIN $LOG_FILE" > /dev/null

    # 5. Hyperfine-Daten aus JSON an SUMMARY_TIME hängen
    python3 - "$JSON_OUT" "$TAG" "$SUMMARY_TIME" <<'END'
import sys
import json

json_file = sys.argv[1]
tag = sys.argv[2]
summary_file = sys.argv[3]

with open(json_file) as f:
    data = json.load(f)

lines = []
for res in data['results']:
    name = res['command']
    mean_ms = res['mean'] * 1000
    std_ms = res['stddev'] * 1000
    min_ms = res['min'] * 1000
    max_ms = res['max'] * 1000
    lines.append(f"| {tag} | {name} | {mean_ms:.1f} | {std_ms:.1f} | {min_ms:.1f} | {max_ms:.1f} |\n")

with open(summary_file, 'a') as f:
    f.writelines(lines)
END

done

echo ""
echo "=================================================="
echo " MASTER-BENCHMARK ERFOLGREICH ABGESCHLOSSEN!"
echo " Alle Messungen gebündelt in: $SUMMARY_FILE"
echo "=================================================="