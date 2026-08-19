# Gesamtauswertung aller Optimierungsstufen (Go vs. Zig)

Gemessen mit `hyperfine` (10 Durchläufe, 3 Warmups) auf 10 Mio. Log-Zeilen.

| Stufe / Tag | Sprache | Mean Time (ms) | StdDev (ms) | Min (ms) | Max (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| new-stage1 | Go (new-stage1) | 2655.3 | 21.5 | 2614.9 | 2681.3 |
| new-stage1 | Zig (new-stage1) | 1211.8 | 34.1 | 1162.3 | 1273.6 |
| new-stage2 | Go (new-stage2) | 1009.5 | 26.7 | 959.5 | 1043.3 |
| new-stage2 | Zig (new-stage2) | 573.2 | 21.4 | 548.7 | 620.2 |
| new-stage3 | Go (new-stage3) | 187.8 | 8.8 | 178.9 | 204.4 |
| new-stage3 | Zig (new-stage3) | 123.0 | 4.4 | 119.0 | 131.6 |
