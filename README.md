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

**Linux** ```sh 
git clone --branch new-stage3 https://github.com/Nicolas-Klein/parser-artefacts-repo.git
```

**Windows** ```git clone --branch new-stage3-windows https://github.com/Nicolas-Klein/parser-artefacts-repo.git```

Nachdem Clonen des Repos können folgende Skripts je nach Betriebssystem ausgeführt werden: 

```cd parser-artefacts-repo/```

**Linux** ```benchmark/run_all_stages.sh```

**Windows** ```.\benchmark\run_all_stages.ps1```

Das Ausführen der Skripts erstellt automatisch eine Datei für das Benchmarking und führt automatisch das Benchmarking für die drei Implementierungsstufen durch. Die Ergebnisse werden in der Datei master_summary.md ausgegeben. 


Bei der Erstellung der Dateien dieses Repos wurde KI verwendet, zum Debuggen und finden und beheben von Logik Fehlern. 
