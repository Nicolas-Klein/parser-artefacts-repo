$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path "$ScriptDir\.."
$LogFile = "$ProjectRoot\benchmark_large.log"
$ResultsDir = "$ScriptDir\results"
$SummaryFile = "$ResultsDir\current_summary.md"
$JsonOut = "$ResultsDir\current_results.json"

New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

if (-not (Test-Path $LogFile)) {
    Write-Host "Fehler: Log-Datei unter '$LogFile' nicht gefunden!" -ForegroundColor Red
    exit 1
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " BENCHMARKE AKTUELLE ARTEFAKTE (LOKALER STAND)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# 1. Go kompilieren
Write-Host "`nKompiliere Go-Parser..." -ForegroundColor Yellow
Push-Location "$ProjectRoot\src\go-parser"
try {
    go build -o go-parser-artefact.exe main.go
} finally {
    Pop-Location
}

# 2. Zig kompilieren
Write-Host "Kompiliere Zig-Parser..." -ForegroundColor Yellow
Push-Location "$ProjectRoot\src\zig-parser"
try {
    zig build-exe src/main.zig -O ReleaseFast --name zig-parser-artefact
} finally {
    Pop-Location
}

$GoBin = "$ProjectRoot\src\go-parser\go-parser-artefact.exe"
$ZigBin = "$ProjectRoot\src\zig-parser\zig-parser-artefact.exe"

# 3. Hyperfine ausführen
Write-Host "`nStarte Hyperfine (10 Runs, 3 Warmups)..." -ForegroundColor Green
hyperfine --warmup 3 --runs 10 `
  --export-json "$JsonOut" `
  --command-name "Go (Current)" "$GoBin `"$LogFile`"" `
  --command-name "Zig (Current)" "$ZigBin `"$LogFile`""

# 4. JSON-Auswertung via Python (-c Option verhindert REPL-Shell)
$PyScript = @"
import sys, json

json_file = r'$JsonOut'
summary_file = r'$SummaryFile'

with open(json_file) as f:
    data = json.load(f)

lines = [
    "# Benchmark-Ergebnis (Aktueller Stand)\n\n",
    "| Sprache / Command | Mean Time (ms) | StdDev (ms) | Min (ms) | Max (ms) |\n",
    "| :--- | :--- | :--- | :--- | :--- |\n"
]

for res in data['results']:
    name = res['command']
    mean_ms = res['mean'] * 1000
    std_ms = res['stddev'] * 1000
    min_ms = res['min'] * 1000
    max_ms = res['max'] * 1000
    lines.append(f"| {name} | {mean_ms:.1f} | {std_ms:.1f} | {min_ms:.1f} | {max_ms:.1f} |\n")

with open(summary_file, 'w') as f:
    f.writelines(lines)

print('\n'.join(lines))
"@

python -c "$PyScript"

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host " BENCHMARK ABGESCHLOSSEN!" -ForegroundColor Cyan
Write-Host " Ergebnisse gespeichert in: $SummaryFile" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan