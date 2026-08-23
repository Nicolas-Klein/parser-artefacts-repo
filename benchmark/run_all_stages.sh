#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_FILE="$PROJECT_ROOT/generator/benchmark_large.log"
RESULTS_DIR="$SCRIPT_DIR/results"
SUMMARY_FILE="$RESULTS_DIR/master_summary.md"

# Die zu testenden Tags in exakter Reihenfolge
TAGS=("new-stage1" "new-stage2" "new-stage3")

mkdir -p "$RESULTS_DIR"

# Prüfen, ob hyperfine installiert ist
if ! command -v hyperfine &> /dev/null; then
    echo "Fehler: 'hyperfine' ist nicht installiert."
    exit 1
fi

# Prüfen, ob die Log-Datei existiert
if [ ! -f "$LOG_FILE" ]; then
    echo "Fehler: Benchmark-Logfile unter $LOG_FILE nicht gefunden!"
    exit 1
fi

echo "=================================================="
echo " STARTE MASTER-BENCHMARK ÜBER ALLE STUFEN"
echo "=================================================="

# Aktuellen Git-Zustand und Branch sichern
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Aktueller Branch: $ORIGINAL_BRANCH (wird gesichert)"
git stash push -m "Automated master benchmark temporary stash" > /dev/null 2>&1 || true

# Funktion zur Wiederherstellung des Git-Zustands bei Abbruch/Erfolg
cleanup() {
    echo ""
    echo "Kehre zum ursprünglichen Stand zurück..."
    git checkout --force "$ORIGINAL_BRANCH" > /dev/null 2>&1 || true
    git stash pop > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Zusammenfassende Datei initialisieren
cat <<EOF > "$SUMMARY_FILE"
# Gesamtauswertung aller Optimierungsstufen (Go vs. Zig)

Gemessen mit \`hyperfine\` (10 Durchläufe, 3 Warmups) auf 10 Mio. Log-Zeilen.

| Stufe / Tag | Sprache | Mean Time (ms) | StdDev (ms) | Min (ms) | Max (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- |
EOF

# Durch alle Tags iterieren
for TAG in "${TAGS[@]}"; do
    echo ""
    echo "--------------------------------------------------"
    echo " 🚀 Verarbeite Git-Tag: $TAG"
    echo "--------------------------------------------------"

    # 1. Auschecken
    git checkout --force "$TAG" --quiet

    # 2. Bauen (Go & Zig)
    echo "Kompiliere Go-Parser..."
    (cd "$PROJECT_ROOT/src/go-parser" && go build -o go-parser-artefact main.go)

    echo "Kompiliere Zig-Parser..."
    (cd "$PROJECT_ROOT/src/zig-parser" && zig build-exe src/main.zig -O ReleaseFast -femit-bin=zig-parser-artefact)

    GO_BIN="$PROJECT_ROOT/src/go-parser/go-parser-artefact"
    ZIG_BIN="$PROJECT_ROOT/src/zig-parser/zig-parser-artefact"
    JSON_OUT="$RESULTS_DIR/results_${TAG}.json"

    # 3. Hyperfine-Messung
    echo "Starte Hyperfine..."
    hyperfine \
      --warmup 3 \
      --runs 10 \
      --export-json "$JSON_OUT" \
      --command-name "Go ($TAG)" "$GO_BIN $LOG_FILE" \
      --command-name "Zig ($TAG)" "$ZIG_BIN $LOG_FILE"

    # 4. Daten aus JSON extrahieren und in Summary-Tabelle schreiben (mittels python)
    python3 - "$JSON_OUT" "$TAG" "$SUMMARY_FILE" <<'END'
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
echo " Ergebnisse gespeichert in: $SUMMARY_FILE"
echo "=================================================="