# Log-Parser Performance & Ressourceneffizienz: Go vs. Zig

Dieses Repository enthält die Artefakte und den Quellcode.

## Projektstruktur

* `generator/` - Python-Skript zur Generierung der Test-Log-Datei (5 GB).
* `src/go-parser/` - Implementierung des Parsers in Go.
* `src/zig-parser/` - Implementierung des Parsers in Zig.

## Voraussetzungen

Um die Umgebung lokal auszuführen, werden folgende Tools benötigt:
* **Python 3.x** (für den Log-Generator)
* **Go** (ab v1.26.5)
* **Zig** (0.14.0)
* **Hyperfine** (für die Latenz-Benchmarks)
* **/usr/bin/time -v** für die Benchmarks der Speicher- und CPU-Auslastung

## Ausführung
Um die Benchmarks auszuführen muss zu erst der passende Tag geclont werden.

**Linux**
**Windows**
