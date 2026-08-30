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
for cmd in hyperfine python3 /usr/bin/time; do
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
    
    # Aufräumen der temporären Dateien
    rm -f "$SUMMARY_TIME" "$SUMMARY_SYS"
    
    git checkout "$ORIGINAL_BRANCH" > /dev/null 2>&1 || true
    git stash pop > /dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. Zusammenfassende Dateien mit den KORREKTEN Tabellenköpfen initialisieren
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

# Hilfsfunktion für Systemmetriken
measure_sys_metrics() {
    local LANG_NAME=$1
    local BIN_PATH=$2
    local TAG_NAME=$3

    echo "  > Erfasse Prozess-Metriken (User/Kernel CPU Time & RAM) für $LANG_NAME..."

    local TMP_TIME="$RESULTS_DIR/time_${LANG_NAME}_${TAG_NAME}.txt"

    # GNU time Ausführung (-v schreibt auf stderr)
    /usr/bin/time -v "$BIN_PATH" "$LOG_FILE" > /dev/null 2> "$TMP_TIME"
    
    # Python-Script liest GNU time aus und hängt die Zeile an SUMMARY_SYS an
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

    # 2. Hyperfine-Messung
    echo "  > Starte Hyperfine..."
    hyperfine \
      --warmup 3 \
      --runs 10 \
      --export-json "$JSON_OUT" \
      --command-name "Go ($TAG)" "$GO_BIN $LOG_FILE" \
      --command-name "Zig ($TAG)" "$ZIG_BIN $LOG_FILE" > /dev/null

    # 3. Hyperfine-Daten aus JSON an SUMMARY_TIME hängen
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