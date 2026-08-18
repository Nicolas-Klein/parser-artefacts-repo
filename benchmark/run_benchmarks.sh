#!/usr/bin/env bash

# Abbruch bei Fehlern
set -e

# Ermittle das Hauptverzeichnis des Projekts (egal von wo das Skript gestartet wird)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_FILE="$PROJECT_ROOT/generator/benchmark_large.log"
GO_BIN="$PROJECT_ROOT/src/go-parser/go-parser-artefact"
ZIG_BIN="$PROJECT_ROOT/src/zig-parser/zig-parser-artefact"
RESULTS_DIR="$SCRIPT_DIR/results"

mkdir -p "$RESULTS_DIR"

echo "=================================================="
echo "Starte Automatisierten Benchmark (Stufe 1)"
echo "=================================================="

# 1. Prüfen ob Hyperfine installiert ist
if ! command -v hyperfine &> /dev/null; then
    echo "Fehler: 'hyperfine' ist nicht installiert."
    echo "Installiere es z. B. über 'sudo apt install hyperfine'."
    exit 1
fi

# 2. Prüfen ob Binärdateien existieren
if [ ! -f "$GO_BIN" ]; then
    echo "Fehler: Go-Artefakt nicht gefunden unter: $GO_BIN"
    echo "Bitte kompiliere erst den Go-Parser!"
    exit 1
fi

if [ ! -f "$ZIG_BIN" ]; then
    echo "Fehler: Zig-Artefakt nicht gefunden unter: $ZIG_BIN"
    echo "Bitte kompiliere erst den Zig-Parser!"
    exit 1
fi

# 3. Prüfen ob Logdatei existiert
if [ ! -f "$LOG_FILE" ]; then
    echo "Fehler: Logdatei nicht gefunden unter: $LOG_FILE"
    exit 1
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
  --export-json "$RESULTS_DIR/stage1_v2_results.json" \
  --export-markdown "$RESULTS_DIR/stage1_v2_results.md" \
  --command-name "Go-Baseline (Stufe 1)" "$GO_BIN $LOG_FILE" \
  --command-name "Zig-Baseline (Stufe 1)" "$ZIG_BIN $LOG_FILE"

echo ""
echo "=================================================="
echo "Benchmark abgeschlossen!"
echo "Ergebnisse gespeichert in: $RESULTS_DIR/stage1_v2_results.md"
echo "=================================================="