import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

# 1. CSV-Datei einlesen / Muss selbst erstellt werden
df = pd.read_csv('diagramm_data.csv')

# 2. X-Achsen-Kategorie zusammenführen
df['Kategorie'] = df['Stufe'] + '\n(' + df['Sprache'] + ')'

# 3. Layout & Style setzen (Wissenschaftlicher Look)
plt.figure(figsize=(10, 6))
sns.set_theme(style="whitegrid", font_scale=1.1)

# Farben für die drei Systeme definieren
palette = {
    'Linux': '#1f77b4',   # Blau
    'WSL2': '#ff7f0e',    # Orange
    'Windows': '#2ca02c'  # Grün
}

# 4. Gruppiertes Balkendiagramm zeichnen
ax = sns.barplot(
    data=df,
    x='Kategorie',
    y='Mean',
    hue='System',
    palette=palette
)

# 5. Fehlerbalken für StdDev exakt aus dem DataFrame hinzufügen
for p in ax.patches:
    height = p.get_height()

    if height > 0 and not pd.isna(height):
        x_center = p.get_x() + p.get_width() / 2
        
        row = df[df['Mean'] == height]
        if not row.empty:
            std_val = row['StdDev'].values[0]
            ax.errorbar(
                x=x_center, 
                y=height, 
                yerr=std_val, 
                fmt='none', 
                c='black', 
                capsize=3, 
                capthick=1, 
                elinewidth=1
            )

# 6. Beschriftungen und Achsen anpassen
plt.title('Performance-Vergleich: Ausführungszeit nach System, Stufe und Sprache', fontsize=13, fontweight='bold', pad=15)
plt.xlabel('Ausbaustufe & Sprache', fontsize=11, labelpad=10)
plt.ylabel('Mittlere Ausführungszeit Mean (ms)', fontsize=11)
plt.legend(title='Systemumgebung', frameon=True)

# Tight Layout für saubere Ränder
plt.tight_layout()

# 7. Speichern in hoher Auflösung
plt.savefig('diagramm_performance_systeme.pdf', format='pdf', dpi=300)
plt.savefig('diagramm_performance_systeme.png', format='png', dpi=300)
print("Diagramm erfolgreich als PDF und PNG gespeichert!")