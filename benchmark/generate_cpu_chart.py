import pandas as pd
import matplotlib.pyplot as plt

# 1. Daten aus CSV einlesen
df = pd.read_csv('diagramm_data_cpu.csv')

df['Stufe'] = df['Stufe'].str.strip()
df['Sprache'] = df['Sprache'].str.strip()
df['System'] = df['System'].str.strip()

# 2. Erstelle kombinierte Kategorie für die X-Achse
df['Kategorie'] = df['Stufe'] + '\n(' + df['Sprache'] + ')'

# 3. Festlegung der exakten X-Achsen-Reihenfolge
kategorien_reihenfolge = [
    'Stufe 1\n(Go)', 'Stufe 1\n(Zig)',
    'Stufe 2\n(Go)', 'Stufe 2\n(Zig)',
    'Stufe 3\n(Go)', 'Stufe 3\n(Zig)'
]

systems = ['Linux', 'WSL2', 'Windows']

# 4. Figure und Subplots erstellen
fig, axes = plt.subplots(1, 3, figsize=(16, 6), sharey=True)

# 5. Gestapelte Balken pro System zeichnen
for idx, sys_name in enumerate(systems):
    # Filtern und Index setzen
    sys_df = df[df['System'] == sys_name].set_index('Kategorie').reindex(kategorien_reihenfolge)
    
    ax = axes[idx]
    
    # User CPU (unten)
    ax.bar(
        sys_df.index, 
        sys_df['User_CPU'], 
        label='User CPU Time', 
        color='#1f77b4', 
        edgecolor='black', 
        linewidth=0.8
    )
    
    # System CPU (oben drauf gestapelt)
    ax.bar(
        sys_df.index, 
        sys_df['System_CPU'], 
        bottom=sys_df['User_CPU'], 
        label='Kernel/System CPU Time', 
        color='#d62728', 
        edgecolor='black', 
        linewidth=0.8
    )
    
    ax.set_title(f'System: {sys_name}', fontsize=12, fontweight='bold')
    ax.set_xlabel('Ausbaustufe & Sprache', fontsize=10, fontweight='bold', labelpad=10)
    ax.grid(axis='y', linestyle='--', alpha=0.7)
    ax.tick_params(axis='x', rotation=0)

# Beschriftungen der Y-Achse und Legende
axes[0].set_ylabel('CPU Zeit (ms) [Total = User + System]', fontsize=11, fontweight='bold')
axes[2].legend(loc='upper right', frameon=True, facecolor='white', edgecolor='gray')

# Titelseite ohne Beschneidung: erst tight_layout, dann suptitle platzieren
plt.tight_layout()
fig.subplots_adjust(top=0.85)  # Schafft oben genau den nötigen Platz für den Titel
fig.suptitle('Vergleich der CPU-Auslastung (User vs. System CPU Time)', fontsize=14, fontweight='bold')

# Speichern der Bilddateien
plt.savefig('cpu_auslastung_vergleich.pdf', format='pdf', dpi=300)
plt.savefig('cpu_auslastung_vergleich.png', format='png', dpi=300)

print("Diagramm erfolgreich korrigiert und gespeichert!")