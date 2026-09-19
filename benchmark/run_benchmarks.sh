#!/usr/bin/env bash

# Abbruch bei Fehlern
set -e

# Ermittle das Hauptverzeichnis des Projekts (egal von wo das Skript gestartet wird)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_FILE="$PROJECT_ROOT/generator/benchmark_large.log"
GO_DIR="$PROJECT_ROOT/src/go-parser"
ZIG_DIR="$PROJECT_ROOT/src/zig-parser"

GO_BIN="$GO_DIR/go-parser-artefact"
ZIG_BIN="$ZIG_DIR/zig-parser-artefact"
RESULTS_DIR="$SCRIPT_DIR/results"

mkdir -p "$RESULTS_DIR"

echo "=================================================="
echo "Starte Automatisierten Benchmark (Stufe 3)"
echo "=================================================="

# 1. Prüfen ob Hyperfine installiert ist
if ! command -v hyperfine &> /dev/null; then
    echo "Fehler: 'hyperfine' ist nicht installiert."
    echo "Installiere es z. B. über 'sudo apt install hyperfine'."
    exit 1
fi

# Go bauen
echo "  > Baue Go-Parser ($GO_BIN)..."
(cd "$GO_DIR" && go build -o "$GO_BIN" .)

echo "  > Baue Zig-Parser ($ZIG_BIN)..."
(cd "$ZIG_DIR" && zig build-exe -O ReleaseFast -femit-bin="$ZIG_BIN" src/main.zig)

echo "  > Build erfolgreich abgeschlossen."
echo ""

# 3. Prüfen ob Logdatei existiert
if [ ! -f "$LOG_FILE" ]; then
    echo -e "\033[0;31mFehler: Log-Datei unter '$LOG_FILE' nicht gefunden! Generiere neue Datei\033[0m"
    
    python3 "$PROJECT_ROOT/generator/data_generator.py" "$LOG_FILE"
    
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "\033[0;31mFehler: Log-Datei konnte nicht automatisch generiert werden!\033[0m"
        exit 1
    fi
    
    echo -e "\033[0;32m  > Log-Datei erfolgreich erstellt.\033[0m"
fi

echo "Verwendete Binärdateien:"
echo "  Go:  $GO_BIN"
echo "  Zig: $ZIG_BIN"
echo "  Log: $LOG_FILE"
echo ""
echo "Führe Hyperfine-Messungen durch (10 Durchläufe, 3 Warmups)..."

hyperfine \
  --warmup 3 \
  --runs 10 \
  --export-json "$RESULTS_DIR/stage3_v2_results.json" \
  --export-markdown "$RESULTS_DIR/stage3_v2_results.md" \
  --command-name "Go-Baseline (Stufe 3)" "$GO_BIN $LOG_FILE" \
  --command-name "Zig-Baseline (Stufe 3)" "$ZIG_BIN $LOG_FILE"

echo ""
echo "=================================================="
echo "Benchmark abgeschlossen!"
echo "Ergebnisse gespeichert in: $RESULTS_DIR/stage3_v2_results.md"
echo "=================================================="