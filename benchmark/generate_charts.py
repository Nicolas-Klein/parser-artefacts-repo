#!/usr/bin/env python3
import os
import matplotlib.pyplot as plt
import numpy as np

# Farben für universitäre/wissenschaftliche Arbeiten (Akzente für Go & Zig)
COLOR_GO = "#00ADD8"   # Offizielles Go Cyan
COLOR_ZIG = "#F7A41D"  # Offizielles Zig Orange

# Daten direkt aus der master_summary.md
stages = ["Stufe 1\n(Baseline)", "Stufe 2a\n(mmap & Zero-Copy)", "Stufe 2b\n(SIMD Target Search)", "Stufe 3\n(Multi-Threading)"]

go_means = [1929.8, 1338.8, 644.5, 146.4]
go_errors = [149.7, 45.7, 30.2, 8.0]

zig_means = [1683.2, 497.5, 257.5, 113.1]
zig_errors = [82.8, 26.6, 25.6, 6.2]

x = np.arange(len(stages))
width = 0.35

# Layout konfigurieren
plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')
fig, ax = plt.subplots(figsize=(10, 6), dpi=300)

rects1 = ax.bar(x - width/2, go_means, width, yerr=go_errors, label='Go', color=COLOR_GO, capsize=5, edgecolor='black', linewidth=0.8)
rects2 = ax.bar(x + width/2, zig_means, width, yerr=zig_errors, label='Zig', color=COLOR_ZIG, capsize=5, edgecolor='black', linewidth=0.8)

# Achsenbeschriftungen & Titel
ax.set_ylabel('Laufzeit in Millisekunden (ms) [weniger ist besser]', fontsize=12, fontweight='bold')
ax.set_title('Performance-Vergleich: Go vs. Zig (10 Mio. Log-Zeilen)', fontsize=14, fontweight='bold', pad=15)
ax.set_xticks(x)
ax.set_xticklabels(stages, fontsize=10, fontweight='bold')
ax.legend(fontsize=11, frameon=True, facecolor='white', framealpha=0.9)

# Datenwerte auf den Balken platzieren
def autolabel(rects):
    for rect in rects:
        height = rect.get_height()
        ax.annotate(f'{height:.1f} ms',
                    xy=(rect.get_x() + rect.get_width() / 2, height),
                    xytext=(0, 6),  # 6 points vertical offset
                    textcoords="offset points",
                    ha='center', va='bottom', fontsize=9, fontweight='bold')

autolabel(rects1)
autolabel(rects2)

plt.tight_layout()

# Ordner anlegen & Grafiken speichern
results_dir = os.path.join(os.path.dirname(__file__), "results")
os.makedirs(results_dir, exist_ok=True)

png_path = os.path.join(results_dir, "benchmark_chart.png")
pdf_path = os.path.join(results_dir, "benchmark_chart.pdf")

plt.savefig(png_path, dpi=300)
plt.savefig(pdf_path, format='pdf')

print(f"Diagramm erfolgreich gespeichert in:")
print(f" - PNG (Vorschau): {png_path}")
print(f" - PDF (Für LaTeX/Bachelorarbeit): {pdf_path}")