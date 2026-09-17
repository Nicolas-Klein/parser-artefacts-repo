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
SUMMARY_SMEM="$RESULTS_DIR/summary_smem.md"

# Die zu testenden Tags in exakter Reihenfolge
TAGS=("new-stage1" "new-stage2" "new-stage3")

mkdir -p "$RESULTS_DIR"

# Tool-Abhängigkeiten prüfen
for cmd in hyperfine python3 /usr/bin/time smem; do
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
    
    # 1. Hauptdatei leeren / neu anlegen
    : > "$SUMMARY_FILE"
    
    # 2. Laufzeit-Tabelle anhängen
    if [ -f "$SUMMARY_TIME" ]; then
        cat "$SUMMARY_TIME" >> "$SUMMARY_FILE"
        echo -e "\n<br>\n" >> "$SUMMARY_FILE"
    fi

    # 3. System-Metriken anhängen
    if [ -f "$SUMMARY_SYS" ]; then
        cat "$SUMMARY_SYS" >> "$SUMMARY_FILE"
        echo -e "\n<br>\n" >> "$SUMMARY_FILE"
    fi

    # 4. GC Trace Auswertung anhängen
    if [ -f "$SUMMARY_GC" ]; then
        cat "$SUMMARY_GC" >> "$SUMMARY_FILE"
        echo -e "\n<br>\n" >> "$SUMMARY_FILE"
    fi

    # 5. Smem Speicheranalyse anhängen
    if [ -f "$SUMMARY_SMEM" ]; then
        cat "$SUMMARY_SMEM" >> "$SUMMARY_FILE"
    fi
    
    # Temporäre Dateien aufräumen (Fehler ignorieren)
    rm -f "$SUMMARY_TIME" "$SUMMARY_SYS" "$SUMMARY_GC" "$SUMMARY_SMEM" 2>/dev/null || true
    
    # Git-Zustand wiederherstellen
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

cat <<EOF > "$SUMMARY_SMEM"
# 4. Speicheranalyse via smem (Linux)
Erfasst via \`smem\` (USS = Unique Set Size, PSS = Proportional Set Size, RSS = Resident Set Size).

| Stufe / Tag | Sprache | USS (MB) | PSS (MB) | RSS / Total WS (MB) | Swap (MB) |
| :--- | :--- | :--- | :--- | :--- | :--- |
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

# Hilfsfunktion für smem Speicheranalyse
measure_smem_metrics() {
    local LANG_NAME=$1
    local BIN_PATH=$2
    local TAG_NAME=$3

    echo "  > Erfasse smem Speicheranalyse für $LANG_NAME..."

    local TMP_SMEM="$RESULTS_DIR/smem_${LANG_NAME}_${TAG_NAME}.txt"

    # 1. Prozess im Hintergrund starten
    "$BIN_PATH" "$LOG_FILE" > /dev/null 2>&1 &
    local TARGET_PID=$!

    # 2. Polling: Warten bis der Prozess echten RSS-Speicher zugewiesen hat (max 100ms)
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

    # 3. Prozess per SIGSTOP einfrieren
    kill -STOP "$TARGET_PID" 2>/dev/null || true

    # 4. smem für die konkrete PID ausführen (-n: numerische User/PIDs, -k: formatiert Ausgaben in KiB/MiB)
    smem -P "^${TARGET_PID}$" -c "pid uss pss rss swap" -n > "$TMP_SMEM" 2>/dev/null || true

    # 5. Python-Script parsed die smem-Ausgabe und hängt die Zeile an SUMMARY_SMEM an
    python3 - "$TMP_SMEM" "$TAG_NAME" "$LANG_NAME" "$SUMMARY_SMEM" <<'END'
import sys
import os

smem_file = sys.argv[1]
tag = sys.argv[2]
lang = sys.argv[3]
summary_smem = sys.argv[4]

uss_mb = 0.0
pss_mb = 0.0
rss_mb = 0.0
swap_mb = 0.0

if os.path.exists(smem_file):
    try:
        with open(smem_file, "r") as f:
            lines = [line.strip() for line in f if line.strip()]

        # smem Ausgabe enthält Header in Zeile 1, Werte in Zeile 2
        if len(lines) >= 2:
            parts = lines[1].split()
            if len(parts) >= 5:
                # smem Werte sind standardmäßig in KiB
                uss_mb = float(parts[1]) / 1024.0
                pss_mb = float(parts[2]) / 1024.0
                rss_mb = float(parts[3]) / 1024.0
                swap_mb = float(parts[4]) / 1024.0
    except Exception as e:
        print(f"  [smem error] {e}")

out_line = f"| {tag} | {lang} | {uss_mb:.1f} | {pss_mb:.1f} | {rss_mb:.1f} | {swap_mb:.1f} |\n"

with open(summary_smem, "a", encoding="utf-8") as f:
    f.write(out_line)
END

    # 6. Prozess wieder aufwecken und beenden
    kill -CONT "$TARGET_PID" 2>/dev/null || true
    kill -9 "$TARGET_PID" 2>/dev/null || true
    wait "$TARGET_PID" 2>/dev/null || true

    rm -f "$TMP_SMEM" 2>/dev/null || true
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
    
    # 2. Memory Mapping via smem erfassen
    measure_smem_metrics "Go" "$GO_BIN" "$TAG"
    measure_smem_metrics "Zig" "$ZIG_BIN" "$TAG"

    # 3. Go GC Trace erfassen
    measure_go_gc "$GO_BIN" "$TAG"

    # 4. Hyperfine-Messung
    echo "  > Starte Hyperfine..."
    hyperfine \
      --warmup 3 \
      --runs 10 \
      --export-json "$JSON_OUT" \
      --command-name "Go ($TAG)" "$GO_BIN$LOG_FILE" \
      --command-name "Zig ($TAG)" "$ZIG_BIN$LOG_FILE" > /dev/null

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