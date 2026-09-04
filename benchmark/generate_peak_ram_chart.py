import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

# 1. Daten einlesen (Dateiname anpassen)
df = pd.read_csv('diagramm_data_peak_ram.csv')

# Leerzeichen in String-Spalten bereinigen
df['Stufe'] = df['Stufe'].str.strip()
df['Sprache'] = df['Sprache'].str.strip()
df['System'] = df['System'].str.strip()

# 2. Kombinierte Kategorie für die X-Achse
df['Kategorie'] = df['Stufe'] + '\n(' + df['Sprache'] + ')'

# Festlegung der exakten Reihenfolge auf der X-Achse
kategorien_reihenfolge = [
    'Stufe 1\n(Go)', 'Stufe 1\n(Zig)',
    'Stufe 2\n(Go)', 'Stufe 2\n(Zig)',
    'Stufe 3\n(Go)', 'Stufe 3\n(Zig)'
]
df['Kategorie'] = pd.Categorical(df['Kategorie'], categories=kategorien_reihenfolge, ordered=True)

# 3. Layout & Stil
plt.figure(figsize=(11, 6))
sns.set_theme(style="whitegrid", font_scale=1.0)

palette = {
    'Linux': '#1f77b4',   # Blau
    'WSL2': '#ff7f0e',    # Orange
    'Windows': '#2ca02c'  # Grün
}

# 4. Balkendiagramm zeichnen
ax = sns.barplot(
    data=df,
    x='Kategorie',
    y='Peak_RAM_MB', # Spaltenname für deinen Speicherwert in MB
    hue='System',
    palette=palette,
    edgecolor="black",
    linewidth=0.8
)

# 5. Beschriftungen und Feinschliff
plt.title('Maximaler Arbeitsspeicherbedarf (Peak RAM / RSS) nach System und Stufe', fontsize=13, fontweight='bold', pad=15)
plt.xlabel('Ausbaustufe & Programmiersprache', fontsize=11, fontweight='bold', labelpad=10)
plt.ylabel('Peak RAM (MB) [weniger ist besser]', fontsize=11, fontweight='bold')
plt.legend(title='Systemumgebung', frameon=True, facecolor='white', edgecolor='gray')

plt.tight_layout()

# Speichern der Bilddateien
plt.savefig('diagramm_peak_ram_vergleich.pdf', format='pdf', dpi=300)
plt.savefig('diagramm_peak_ram_vergleich.png', format='png', dpi=300)

print("Speicher-Diagramm erfolgreich gespeichert!")