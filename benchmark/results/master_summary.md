# Gesamtauswertung aller Optimierungsstufen (Go vs. Zig)

Gemessen mit `hyperfine` (10 Durchläufe, 3 Warmups) auf 10 Mio. Log-Zeilen.

| Stufe / Tag | Sprache | Mean Time (ms) | StdDev (ms) | Min (ms) | Max (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| v1.0-stage1 | Go (v1.0-stage1) | 1929.8 | 149.7 | 1727.1 | 2176.2 |
| v1.0-stage1 | Zig (v1.0-stage1) | 1683.2 | 82.8 | 1540.1 | 1819.3 |
| v2.0-stage2a | Go (v2.0-stage2a) | 1338.8 | 45.7 | 1282.3 | 1420.9 |
| v2.0-stage2a | Zig (v2.0-stage2a) | 497.5 | 26.6 | 459.0 | 536.1 |
| v2.1-stage2b | Go (v2.1-stage2b) | 644.5 | 30.2 | 608.9 | 703.2 |
| v2.1-stage2b | Zig (v2.1-stage2b) | 257.5 | 25.6 | 230.3 | 308.1 |
| v3.0-stage3 | Go (v3.0-stage3) | 146.4 | 8.0 | 130.9 | 155.7 |
| v3.0-stage3 | Zig (v3.0-stage3) | 113.1 | 6.2 | 104.8 | 123.2 |
