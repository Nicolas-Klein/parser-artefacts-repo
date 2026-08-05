# Log-Parser Performance & Ressourceneffizienz: Go vs. Zig

Dieses Repository enthält die Artefakte und den Quellcode für die Bachelorarbeit:
> **„Auswirkungen von Designentscheidungen auf die Performance und Ressourceneffizienz eines Log-Parsers bei der Verarbeitung großer Datenmengen: Ein Vergleich zweier Artefakte mit unterschiedlichen Speichermanagement-Paradigmen“**

Im Rahmen eines Design Science Research (DSR) Ansatzes werden zwei Log-Parser (in **Go** und **Zig**) iterativ entwickelt, um die Auswirkungen von automatischem Garbage Collection (Go) gegenüber manuellem Speichermanagement (Zig) auf Durchsatz und Speicherverbrauch zu evaluieren.

## 📁 Projektstruktur

* `generator/` - Python-Skript zur Generierung der Test-Log-Datei (5 GB).
* `src/go-parser/` - Implementierung des Parsers in Go (inkl. Ausbaustufen).
* `src/zig-parser/` - Implementierung des Parsers in Zig (inkl. Ausbaustufen).

## 🛠 Voraussetzungen

Um die Umgebung lokal auszuführen, werden folgende Tools benötigt:
* **Python 3.x** (für den Log-Generator)
* **Go** (ab v1.21+)
* **Zig** (aktuelle Version, z. B. 0.11.0+)
* **Hyperfine** (für die Latenz-Benchmarks)