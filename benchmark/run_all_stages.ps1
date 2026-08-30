$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path "$ScriptDir\.."
$LogFile = "$ProjectRoot\benchmark_large.log"
$ResultsDir = "$ScriptDir\results"
$SummaryFile = "$ResultsDir\master_summary-windows.md"

$SummaryTime = "$ResultsDir\summary_time_win.md"
$SummarySys = "$ResultsDir\summary_sys_win.md"

$Tags = @("new-stage1-windows", "new-stage2-windows", "new-stage3-windows")

New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# Vorab prüfen, ob benötigte Tools verfügbar sind
if (-not (Get-Command hyperfine -ErrorAction SilentlyContinue)) {
    Write-Host "Fehler: 'hyperfine' ist nicht im PATH enthalten!" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $LogFile)) {
    Write-Host "Fehler: Benchmark-Logfile unter $LogFile nicht gefunden!" -ForegroundColor Red
    exit 1
}

# Aktuellen Branch sichern
$OriginalBranch = (git rev-parse --abbrev-ref HEAD)
git stash push -m "Automated master benchmark temporary stash" | Out-Null

# Hilfsfunktion: System- & Prozess-Metriken unter Windows erfassen
function Measure-WinProcessMetrics {
    param (
        [string]$LangName,
        [string]$BinPath,
        [string]$LogPath,
        [string]$TagName
    )

    Write-Host "  > Erfasse Prozess- & Perfmon-Metriken für $LangName..." -ForegroundColor Yellow

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $BinPath
    $pinfo.Arguments = "`"$LogPath`""
    $pinfo.UseShellExecute = $false
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($pinfo)

    $peakWorkingSet = 0

    # Polling-Schleife: Solange der Prozess läuft, den Speicher abfragen
    while (-not $process.HasExited) {
        try {
            $process.Refresh()
            $currentWorkingSet = $process.WorkingSet64
            if ($currentWorkingSet -gt $peakWorkingSet) {
                $peakWorkingSet = $currentWorkingSet
            }
        } catch {
            # Abfangen, falls der Prozess genau im Moment der Abfrage beendet wird
        }
        Start-Sleep -Milliseconds 10
    }

    $process.WaitForExit()

    # Letzter Check auf PeakWorkingSet64 aus dem System
    try {
        if ($process.PeakWorkingSet64 -gt $peakWorkingSet) {
            $peakWorkingSet = $process.PeakWorkingSet64
        }
    } catch {}

    $maxRamMb = [math]::Round($peakWorkingSet / 1MB, 2)
    $userCpuMs = [math]::Round($process.UserProcessorTime.TotalMilliseconds, 1)
    $sysCpuMs = [math]::Round($process.PrivilegedProcessorTime.TotalMilliseconds, 1)
    $totalCpuMs = [math]::Round($process.TotalProcessorTime.TotalMilliseconds, 1)

    # In die System-Summary-Tabelle schreiben
    "| $TagName | $LangName | $maxRamMb | $userCpuMs | $sysCpuMs | $totalCpuMs |" | Add-Content -Path $SummarySys
}

try {
    # 1. Tabellenköpfe initialisieren
    "# 1. Gesamtauswertung: Laufzeit (Go vs. Zig)`nGemessen mit ``hyperfine`` (10 Durchläufe, 3 Warmups).`n`n| Stufe / Tag | Sprache / Command | Mean Time (ms) | StdDev (ms) | Min (ms) | Max (ms) |`n| :--- | :--- | :--- | :--- | :--- | :--- |" | Set-Content -Path $SummaryTime

    "# 2. System- & Perfmon-Metriken (Windows)`nGemessen via Win32 Process API & System Diagnostics.`n`n| Stufe / Tag | Sprache | Max RAM / Peak Working Set (MB) | User CPU Time (ms) | Kernel/System CPU Time (ms) | Total CPU Time (ms) |`n| :--- | :--- | :--- | :--- | :--- | :--- |" | Set-Content -Path $SummarySys

    foreach ($Tag in $Tags) {
        Write-Host "`n--------------------------------------------------" -ForegroundColor Cyan
        Write-Host " 🚀 Verarbeite Git-Tag: $Tag" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------" -ForegroundColor Cyan

        git checkout --force $Tag

        # Kompilieren
        Write-Host "Kompiliere Go-Parser..." -ForegroundColor Yellow
        Push-Location "$ProjectRoot\src\go-parser"
        try { go build -o go-parser-artefact.exe main.go } finally { Pop-Location }

        Write-Host "Kompiliere Zig-Parser..." -ForegroundColor Yellow
        Push-Location "$ProjectRoot\src\zig-parser"
        try { zig build-exe src/main.zig -O ReleaseFast --name zig-parser-artefact } finally { Pop-Location }

        $GoBin = "$ProjectRoot\src\go-parser\go-parser-artefact.exe"
        $ZigBin = "$ProjectRoot\src\zig-parser\zig-parser-artefact.exe"
        $JsonOut = "$ResultsDir\results_$Tag.json"

        # A) Prozess- & Perfmon-Metriken erfassen
        Measure-WinProcessMetrics -LangName "Go" -BinPath $GoBin -LogPath $LogFile -TagName $Tag
        Measure-WinProcessMetrics -LangName "Zig" -BinPath $ZigBin -LogPath $LogFile -TagName $Tag

        # B) Hyperfine für präzise Gesamtlaufzeit ausführen
        Write-Host "  > Starte Hyperfine..." -ForegroundColor Yellow
        hyperfine --warmup 3 --runs 10 --export-json "$JsonOut" --command-name "Go ($Tag)" "$GoBin `"$LogFile`"" --command-name "Zig ($Tag)" "$ZigBin `"$LogFile`"" | Out-Null

        # C) JSON-Ergebnisse an die Laufzeit-Tabelle anhängen
        $PyScript = @"
import sys, json

json_file = r'$JsonOut'
tag = r'$Tag'
summary_file = r'$SummaryTime'

with open(json_file) as f:
    data = json.load(f)

lines = []
for res in data['results']:
    name = res['command']
    mean_ms = res['mean'] * 1000
    std_ms = res['stddev'] * 1000
    min_ms = res['min'] * 1000
    max_ms = res['max'] * 1000
    lines.append(f"| {tag} | {name} | {mean_ms:.1f} | {std_ms:.1f} | {min_ms:.1f} | {max_ms:.1f} |\n")

with open(summary_file, 'a', encoding='utf-8') as f:
    f.writelines(lines)
"@
        python -c "$PyScript"
    }
}
finally {
    # Beide Tabellen in der finalen $SummaryFile zusammenführen
    if ((Test-Path $SummaryTime) -and (Test-Path $SummarySys)) {
        Get-Content $SummaryTime | Set-Content $SummaryFile
        "`n<br>`n" | Add-Content $SummaryFile
        Get-Content $SummarySys | Add-Content $SummaryFile
        Remove-Item $SummaryTime, $SummarySys -ErrorAction SilentlyContinue
    }

    # Ursprünglichen Branch wiederherstellen
    Set-Location $ProjectRoot
    git checkout --force $OriginalBranch | Out-Null
    git stash pop | Out-Null
}

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host " MASTER-BENCHMARK ERFOLGREICH ABGESCHLOSSEN!" -ForegroundColor Cyan
Write-Host " Alle Ergebnisse gebündelt in: $SummaryFile" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan