# Log-Parser Performance & Ressourceneffizienz: Go vs. Zig

Dieses Repository enthält die Artefakte und den Quellcode.

## Projektstruktur

* `generator/` - Python-Skript zur Generierung der Test-Log-Datei (5 GB).
* `src/go-parser/` - Implementierung des Parsers in Go.
* `src/zig-parser/` - Implementierung des Parsers in Zig.

Die Tags dieses Projekts repräsentieren die 3 Implementierungsstufe der Artefakte. Aufgrund Systemspezifischen Code gibt es die Stufen jeweils für Windows und Linux.

* Stufe 1: Unoptimierter Baseline-Parser: `new-stage1` für Linux und `new-stage1-windows` für Windows
* Stufe 2: Speicheroptimierter-Parser: `new-stage2` für Linux und `new-stage2-windows` für Windows
* Stufe 3: Parallelisierter-Parser: `new-stage3` für Linux und `new-stage3-windows` für Windows

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
```sh 
git clone --branch new-stage3 https://github.com/Nicolas-Klein/parser-artefacts-repo.git
```

**Windows** 
```sh 
git clone --branch new-stage3-windows https://github.com/Nicolas-Klein/parser-artefacts-repo.git
```

Nachdem Clonen des Repos können folgende Skripts je nach Betriebssystem ausgeführt werden: 

```sh
cd parser-artefacts-repo/
```

**Linux** 
```sh
benchmark/run_all_stages.sh
```

**Windows** 
```sh
.\benchmark\run_all_stages.ps1
```

Das Ausführen der Skripts erstellt automatisch eine Datei für das Benchmarking und führt automatisch das Benchmarking für die drei Implementierungsstufen durch. Die Ergebnisse werden in der Datei master_summary.md ausgegeben. 


Bei der Erstellung der Dateien dieses Repos wurde KI verwendet, zum Debuggen und finden und beheben von Logik Fehlern. 
