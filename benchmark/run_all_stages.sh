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

# Die zu testenden Tags in exakter Reihenfolge
TAGS=("new-stage1" "new-stage2" "new-stage3")

mkdir -p "$RESULTS_DIR"

# Tool-Abhängigkeiten prüfen
for cmd in hyperfine python3 perf /usr/bin/time pidstat; do
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
    
    # Füge Laufzeit und System-Metriken in einer Datei zusammen
    cat "$SUMMARY_TIME" > "$SUMMARY_FILE"
    echo -e "\n<br>\n" >> "$SUMMARY_FILE"
    cat "$SUMMARY_SYS" >> "$SUMMARY_FILE"
    
    git checkout "$ORIGINAL_BRANCH" > /dev/null 2>&1 || true
    git stash pop > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Zusammenfassende Dateien initialisieren
cat <<EOF > "$SUMMARY_TIME"
# 1. Gesamtauswertung: Laufzeit (Go vs. Zig)
Gemessen mit \`hyperfine\` (10 Durchläufe, 3 Warmups).

| Stufe / Tag | Sprache | Mean Time (ms) | StdDev (ms) | Min (ms) | Max (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- |
EOF

cat <<EOF > "$SUMMARY_SYS"
# 2. System- & Hardware-Metriken
Gemessen mit \`time -v\` und \`perf stat\`.

| Stufe / Tag | Sprache | Max RAM (MB) | Context Switches (Vol / Invol) | CPU Cycles | Instructions | Cache Misses |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
EOF

# Hilfsfunktion für Systemmetriken
measure_sys_metrics() {
    local LANG_NAME=$1
    local BIN_PATH=$2
    local TAG_NAME=$3
    local BIN_NAME=$(basename "$BIN_PATH")

    echo "  > Erfasse Metriken (time, perf, pidstat) für $LANG_NAME..."

    local TMP_TIME="$RESULTS_DIR/time_${LANG_NAME}_${TAG_NAME}.txt"
    local TMP_PERF="$RESULTS_DIR/perf_${LANG_NAME}_${TAG_NAME}.txt"
    local TMP_PID="$RESULTS_DIR/pidstat_${LANG_NAME}_${TAG_NAME}.txt"

    # A) pidstat (Startet im Hintergrund, loggt jede Sekunde)
    pidstat -r -u -C "$BIN_NAME" 1 > "$TMP_PID" 2>/dev/null &
    local PIDSTAT_PID=$!

    # B) GNU time (Max RAM & Context Switches)
    /usr/bin/time -v "$BIN_PATH" "$LOG_FILE" > /dev/null 2> "$TMP_TIME"
    
    # C) perf stat (Hardware Counters)
    perf stat -e cycles,instructions,cache-misses "$BIN_PATH" "$LOG_FILE" > /dev/null 2> "$TMP_PERF"

    # pidstat stoppen
    kill -9 $PIDSTAT_PID 2>/dev/null || true

    # --- DATEN EXTRAHIEREN ---
    
    # RAM & Context Switches
    local MAX_RAM_KB=$(grep "Maximum resident set size" "$TMP_TIME" | awk -F': ' '{print $2}' || echo "0")
    local MAX_RAM_MB=$(awk "BEGIN {printf \"%.2f\", $MAX_RAM_KB / 1024}")
    local CS_VOL=$(grep "Voluntary context switches" "$TMP_TIME" | awk -F': ' '{print $2}' || echo "0")
    local CS_INVOL=$(grep "Involuntary context switches" "$TMP_TIME" | awk -F': ' '{print $2}' || echo "0")

    # Hardware Counters (tr entfernt Tausendertrennzeichen)
    local CYCLES=$(grep "cycles" "$TMP_PERF" | awk '{print $1}' | tr -d '.,' || echo "N/A")
    local INSTR=$(grep "instructions" "$TMP_PERF" | awk '{print $1}' | tr -d '.,' || echo "N/A")
    local MISSES=$(grep "cache-misses" "$TMP_PERF" | awk '{print $1}' | tr -d '.,' || echo "N/A")

    # In die System-Tabelle schreiben
    echo "| $TAG_NAME | $LANG_NAME | $MAX_RAM_MB | $CS_VOL / $CS_INVOL | $CYCLES | $INSTR | $MISSES |" >> "$SUMMARY_SYS"
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
    (cd "$PROJECT_ROOT/src/zig-parser" && zig build-exe src/main.zig -O ReleaseFast -femit-bin=zig-parser-artefact)

    GO_BIN="$PROJECT_ROOT/src/go-parser/go-parser-artefact"
    ZIG_BIN="$PROJECT_ROOT/src/zig-parser/zig-parser-artefact"
    JSON_OUT="$RESULTS_DIR/results_${TAG}.json"

    # 1. System & Hardware Metriken aufzeichnen (time, perf, pidstat)
    measure_sys_metrics "Go" "$GO_BIN" "$TAG"
    measure_sys_metrics "Zig" "$ZIG_BIN" "$TAG"

    # 2. Hyperfine-Messung
    echo "  > Starte Hyperfine..."
    hyperfine \
      --warmup 3 \
      --runs 10 \
      --export-json "$JSON_OUT" \
      --command-name "Go ($TAG)" "$GO_BIN $LOG_FILE" \
      --command-name "Zig ($TAG)" "$ZIG_BIN $LOG_FILE" > /dev/null

    # 3. Daten aus JSON an die Laufzeit-Tabelle hängen
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
echo " Alle Messungen (Laufzeit & Metriken) gebündelt in: $SUMMARY_FILE"
echo "=================================================="