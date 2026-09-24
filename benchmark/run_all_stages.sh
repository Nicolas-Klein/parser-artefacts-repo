#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_FILE="$PROJECT_ROOT/benchmark_large.log"
RESULTS_DIR="$SCRIPT_DIR/results"
SUMMARY_FILE="$RESULTS_DIR/master_summary.md"

# Temporäre Dateien für die getrennten Tabellen
SUMMARY_TIME="$RESULTS_DIR/summary_time.md"
SUMMARY_SYS="$RESULTS_DIR/summary_sys.md"
SUMMARY_GC="$RESULTS_DIR/summary_gc.md"

# Die zu testenden Tags in exakter Reihenfolge
TAGS=("new-stage1" "new-stage2" "new-stage3")

mkdir -p "$RESULTS_DIR"

# Tool-Abhängigkeiten prüfen (smem entfernt)
for cmd in hyperfine python3 /usr/bin/time; do
    if ! command -v "$cmd" &> /dev/null && [ ! -x "$cmd" ]; then
        echo "Fehler: '$cmd' ist nicht installiert oder nicht im PATH."
        exit 1
    fi
done

if [ ! -f "$LOG_FILE" ]; then
    echo -e "\033[0;31mFehler: Log-Datei unter '$LOG_FILE' nicht gefunden! Generiere neue Datei\033[0m"
    
    python3 "$PROJECT_ROOT/generator/data_generator.py" "$LOG_FILE"
    
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "\033[0;31mFehler: Log-Datei konnte nicht automatisch generiert werden!\033[0m"
        exit 1
    fi
    
    echo -e "\033[0;32m  > Log-Datei erfolgreich erstellt.\033[0m"
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
    
    # Temporäre Dateien aufräumen
    rm -f "$SUMMARY_TIME" "$SUMMARY_SYS" "$SUMMARY_GC" 2>/dev/null || true
    
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

# Hilfsfunktion für Systemmetriken
measure_sys_metrics() {
    local LANG_NAME=$1
    local BIN_PATH=$2
    local TAG_NAME=$3
    local WARMUP_RUNS=3
    local MEASURED_RUNS=10

    echo "  > Erfasse Prozess-Metriken für $LANG_NAME ($WARMUP_RUNS Warmups, $MEASURED_RUNS Läufe)..."

    local TMP_TIME="$RESULTS_DIR/time_${LANG_NAME}_${TAG_NAME}.txt"
    : > "$TMP_TIME" # Datei leeren

    # 1. Warmup-Läufe (ohne Aufzeichnung)
    for ((i=1; i<=WARMUP_RUNS; i++)); do
        "$BIN_PATH" "$LOG_FILE" > /dev/null 2>&1
    done

    # 2. Gemessene Läufe (Ausgabe an TMP_TIME anhängen)
    for ((i=1; i<=MEASURED_RUNS; i++)); do
        /usr/bin/time -v "$BIN_PATH" "$LOG_FILE" > /dev/null 2>> "$TMP_TIME"
    done

    # 3. Python-Auswertung: Summiert alle Läufe auf und berechnet den Durchschnitt
    python3 - "$TMP_TIME" "$TAG_NAME" "$LANG_NAME" "$SUMMARY_SYS" "$MEASURED_RUNS" <<'END'
import sys

time_file = sys.argv[1]
tag = sys.argv[2]
lang = sys.argv[3]
summary_sys = sys.argv[4]
runs = float(sys.argv[5])

total_user_sec = 0.0
total_sys_sec = 0.0
max_ram_kb_list = []

with open(time_file) as f:
    for line in f:
        if "User time (seconds):" in line:
            total_user_sec += float(line.split(":")[-1].strip())
        elif "System time (seconds):" in line:
            total_sys_sec += float(line.split(":")[-1].strip())
        elif "Maximum resident set size" in line:
            max_ram_kb_list.append(float(line.split(":")[-1].strip()))

# Durschnitte berechnen
avg_user_ms = round((total_user_sec / runs) * 1000, 1)
avg_kernel_ms = round((total_sys_sec / runs) * 1000, 1)
avg_total_cpu_ms = round(avg_user_ms + avg_kernel_ms, 1)

# Peak RAM ist der Maximalwert über alle Läufe (oder der Durchschnitt, hier Peak Max)
peak_ram_mb = round(max(max_ram_kb_list) / 1024, 2) if max_ram_kb_list else 0.0

out_line = f"| {tag} | {lang} | {peak_ram_mb} | {avg_user_ms} | {avg_kernel_ms} | {avg_total_cpu_ms} |\n"

with open(summary_sys, 'a') as f:
    f.write(out_line)
END

    rm -f "$TMP_TIME" 2>/dev/null || true
}

measure_go_gc() {
    local BIN_PATH=$1
    local TAG_NAME=$2
    local WARMUP_RUNS=3
    local MEASURED_RUNS=10

    echo "  > Erfasse Go GC-Trace (GODEBUG=gctrace=1) mit $WARMUP_RUNS Warmups und $MEASURED_RUNS Läufen..."

    local GC_LOG="$RESULTS_DIR/gc_${TAG_NAME}.log"
    : > "$GC_LOG"

    # Warmups
    for ((i=1; i<=WARMUP_RUNS; i++)); do
        "$BIN_PATH" "$LOG_FILE" > /dev/null 2>&1
    done

    # Gemessene Läufe
    for ((i=1; i<=MEASURED_RUNS; i++)); do
        GODEBUG=gctrace=1 "$BIN_PATH" "$LOG_FILE" > /dev/null 2>> "$GC_LOG"
    done

    python3 - "$GC_LOG" "$TAG_NAME" "$SUMMARY_GC" "$MEASURED_RUNS" <<'END'
import sys
import re

gc_log = sys.argv[1]
tag = sys.argv[2]
summary_gc = sys.argv[3]
runs = int(sys.argv[4])

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

avg_gc_runs = round(gc_count / runs, 1) if runs > 0 else 0
avg_total_pause = round(total_clock_ms / runs, 2) if runs > 0 else 0.0
avg_pause_per_run = round(total_clock_ms / gc_count, 3) if gc_count > 0 else 0.0

out_line = f"| {tag} | {avg_gc_runs} | {avg_total_pause} | {avg_pause_per_run} | {max_heap_mb:.2f} |\n"

with open(summary_gc, 'a') as f:
    f.write(out_line)
END
}

# Durch alle Tags iterieren
for TAG in "${TAGS[@]}"; do
    echo ""
    echo "--------------------------------------------------"
    echo " Verarbeite Git-Tag: $TAG"
    echo "--------------------------------------------------"

    git checkout --force "$TAG" --quiet

    echo "Kompiliere Go-Parser..."
    (cd "$PROJECT_ROOT/src/go-parser" && go build -o go-parser-artefact main.go) || {
        echo "Fehler beim Kompilieren des Go-Parsers!"
        exit 1
    }

    echo "Kompiliere Zig-Parser..."
    (cd "$PROJECT_ROOT/src/zig-parser" && zig build-exe src/main.zig -O ReleaseFast --name zig-parser-artefact) || {
        echo "Fehler beim Kompilieren des Zig-Parsers!"
        exit 1
    }

    GO_BIN="$PROJECT_ROOT/src/go-parser/go-parser-artefact"
    ZIG_BIN="$PROJECT_ROOT/src/zig-parser/zig-parser-artefact"
    JSON_OUT="$RESULTS_DIR/results_${TAG}.json"

    # 1. System & Process Metriken erfassen
    measure_sys_metrics "Go" "$GO_BIN" "$TAG"
    measure_sys_metrics "Zig" "$ZIG_BIN" "$TAG"

    # 2. Go GC Trace erfassen
    measure_go_gc "$GO_BIN" "$TAG"

    # 3. Hyperfine-Messung
    echo "  > Starte Hyperfine..."
    hyperfine \
      --warmup 3 \
      --runs 10 \
      --export-json "$JSON_OUT" \
      --command-name "Go ($TAG)" "\"$GO_BIN\" \"$LOG_FILE\"" \
      --command-name "Zig ($TAG)" "\"$ZIG_BIN\" \"$LOG_FILE\"" > /dev/null

    # 4. Hyperfine-Daten aus JSON an SUMMARY_TIME hängen
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