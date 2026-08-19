#!/usr/bin/env python3
import os
import sys
import matplotlib.pyplot as plt
import numpy as np

# Farben für wissenschaftliche Arbeiten (Offizielle Sprachakzente)
COLOR_GO = "#00ADD8"   # Go Cyan
COLOR_ZIG = "#F7A41D"  # Zig Orange

# Pfade definieren
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(SCRIPT_DIR, "results")
SUMMARY_FILE = os.path.join(RESULTS_DIR, "master_summary.md")

# Stufen-Beschriftungen für die X-Achse
STAGES_LABELS = [
    "Stufe 1\n(Baseline: Naive)",
    "Stufe 2\n(Single-Core: mmap & Zero-Copy)",
    "Stufe 3\n(Multi-Core: 16 Threads)"
]

# Standard-/Fallback-Daten (falls master_summary.md noch nicht existiert)
data = {
    "new-stage1": {"Go": {"mean": 0.0, "std": 0.0}, "Zig": {"mean": 0.0, "std": 0.0}},
    "new-stage2": {"Go": {"mean": 0.0, "std": 0.0}, "Zig": {"mean": 0.0, "std": 0.0}},
    "new-stage3": {"Go": {"mean": 0.0, "std": 0.0}, "Zig": {"mean": 0.0, "std": 0.0}},
}

# 1. Daten aus master_summary.md parsen
if os.path.exists(SUMMARY_FILE):
    print(f"Lese Daten aus: {SUMMARY_FILE}")
    with open(SUMMARY_FILE, "r") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("|") or "Stufe / Tag" in line or "---" in line:
                continue
            
            parts = [p.strip() for p in line.split("|")[1:-1]]
            if len(parts) >= 4:
                tag = parts[0]
                command = parts[1]
                mean_ms = float(parts[2])
                std_ms = float(parts[3])

                lang = "Go" if "Go" in command else "Zig" if "Zig" in command else None
                if tag in data and lang:
                    data[tag][lang] = {"mean": mean_ms, "std": std_ms}
else:
    print(f"Hinweis: {SUMMARY_FILE} nicht gefunden. Verwende Platzhalter-Daten.")

# Array-Vektoren für Matplotlib aufbereiten
tags = ["new-stage1", "new-stage2", "new-stage3"]

go_means = [data[tag]["Go"]["mean"] for tag in tags]
go_errors = [data[tag]["Go"]["std"] for tag in tags]

zig_means = [data[tag]["Zig"]["mean"] for tag in tags]
zig_errors = [data[tag]["Zig"]["std"] for tag in tags]

# 2. Plot aufbauen
plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')
fig, ax = plt.subplots(figsize=(9, 6), dpi=300)

x = np.arange(len(STAGES_LABELS))
width = 0.35

rects1 = ax.bar(x - width/2, go_means, width, yerr=go_errors, label='Go', color=COLOR_GO, capsize=5, edgecolor='black', linewidth=0.8)
rects2 = ax.bar(x + width/2, zig_means, width, yerr=zig_errors, label='Zig', color=COLOR_ZIG, capsize=5, edgecolor='black', linewidth=0.8)

# Achsen & Titel
ax.set_ylabel('Laufzeit in Millisekunden (ms) [weniger ist besser]', fontsize=11, fontweight='bold')
ax.set_title('Full Struct Parsing Performance: Go vs. Zig (10 Mio. Log-Zeilen)', fontsize=13, fontweight='bold', pad=15)
ax.set_xticks(x)
ax.set_xticklabels(STAGES_LABELS, fontsize=10, fontweight='bold')
ax.legend(fontsize=11, frameon=True, facecolor='white', framealpha=0.9)

# Datenwerte auf den Balken platzieren
def autolabel(rects):
    for rect in rects:
        height = rect.get_height()
        if height > 0:
            ax.annotate(f'{height:.1f} ms',
                        xy=(rect.get_x() + rect.get_width() / 2, height),
                        xytext=(0, 5),
                        textcoords="offset points",
                        ha='center', va='bottom', fontsize=9, fontweight='bold')

autolabel(rects1)
autolabel(rects2)

plt.tight_layout()

# 3. Speichern (PNG & PDF)
os.makedirs(RESULTS_DIR, exist_ok=True)

png_path = os.path.join(RESULTS_DIR, "benchmark_full_struct.png")
pdf_path = os.path.join(RESULTS_DIR, "benchmark_full_struct.pdf")

plt.savefig(png_path, dpi=300)
plt.savefig(pdf_path, format='pdf')

print("\nGrafiken erfolgreich erzeugt:")
print(f" 🖼️ PNG (Vorschau): {png_path}")
print(f" 📄 PDF (Für LaTeX): {pdf_path}")