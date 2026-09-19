$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path "$ScriptDir\.."
$LogFile = "$ProjectRoot\benchmark_large.log"
$ResultsDir = "$ScriptDir\results"
$SummaryFile = "$ResultsDir\master_summary-windows.md"

$SummaryTime = "$ResultsDir\summary_time_win.md"
$SummarySys = "$ResultsDir\summary_sys_win.md"
$SummaryGC    = "$ResultsDir\summary_gc_win.md"
$SummaryVMMap = "$ResultsDir\summary_vmmap_win.md"

$Tags = @("new-stage1-windows", "new-stage2-windows", "new-stage3-windows")

New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# EULA für VMMap stumm in der Registry akzeptieren
try {
    Set-ItemProperty -Path "HKCU:\Software\Sysinternals\VMMap" -Name "EulaAccepted" -Value 1 -ErrorAction SilentlyContinue
} catch {}

# Vorab prüfen, ob benötigte Tools verfügbar sind
if (-not (Get-Command hyperfine -ErrorAction SilentlyContinue)) {
    Write-Host "Fehler: 'hyperfine' ist nicht im PATH enthalten!" -ForegroundColor Red
    exit 1
}

$VMMapCmd = Get-Command vmmap -ErrorAction SilentlyContinue
if ($VMMapCmd) {
    $VMMapPath = $VMMapCmd.Source
} elseif (Test-Path "$env:ProgramFiles\Sysinternals\vmmap.exe") {
    $VMMapPath = "$env:ProgramFiles\Sysinternals\vmmap.exe"
} else {
    $VMMapPath = "vmmap.exe"
}

if (-not (Test-Path $LogFile)) {
    Write-Host "Fehler: Log-Datei unter '$LogFile' nicht gefunden! Generiere neue Datei" -ForegroundColor Red
    python "$ProjectRoot\generator\data_generator.py" "$LogFile"
    
    if (-not (Test-Path $LogFile)) {
        Write-Host "Fehler: Log-Datei konnte nicht automatisch generiert werden!" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "  > Log-Datei erfolgreich erstellt." -ForegroundColor Green
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
        [string]$TagName,
        [int]$WarmupRuns = 2,         [int]$MeasuredRuns = 5
    )

    Write-Host "  > Erfasse Prozess- & Perfmon-Metriken für $LangName ($WarmupRuns Warmups,$MeasuredRuns Läufe)..." -ForegroundColor Yellow

    # 1. Warmup-Läufe (ohne Aufzeichnung)
    for ($i = 1; $i -le$WarmupRuns; $i++) {$pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $BinPath
        $pinfo.Arguments = "`"$LogPath`""
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $proc.WaitForExit()
    }

    # 2. Gemessene Durchläufe
    $ramList = @()
    $userCpuList = @()
    $sysCpuList = @()
    $totalCpuList = @()

    for ($run = 1; $run -le$MeasuredRuns; $run++) {$pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $BinPath
        $pinfo.Arguments = "`"$LogPath`""
        $pinfo.UseShellExecute =$false
        $pinfo.RedirectStandardOutput =$true
        $pinfo.RedirectStandardError =$true
        $pinfo.CreateNoWindow =$true

        $process = [System.Diagnostics.Process]::Start($pinfo)
        $peakWorkingSet = 0

        while (-not $process.HasExited) {
            try {
                $process.Refresh()
                $currentWorkingSet =$process.WorkingSet64
                if ($currentWorkingSet -gt$peakWorkingSet) {
                    $peakWorkingSet =$currentWorkingSet
                }
            } catch {}
            Start-Sleep -Milliseconds 5
        }

        $process.WaitForExit()

        try {
            if ($process.PeakWorkingSet64 -gt$peakWorkingSet) {
                $peakWorkingSet =$process.PeakWorkingSet64
            }
        } catch {}

        $ramList += ($peakWorkingSet / 1MB)
        $userCpuList +=$process.UserProcessorTime.TotalMilliseconds
        $sysCpuList +=$process.PrivilegedProcessorTime.TotalMilliseconds
        $totalCpuList +=$process.TotalProcessorTime.TotalMilliseconds
    }

    # 3. Mittelwerte berechnen
    $avgRam = [math]::Round(($ramList | Measure-Object -Average).Average, 2)
    $avgUser = [math]::Round(($userCpuList | Measure-Object -Average).Average, 1)
    $avgSys = [math]::Round(($sysCpuList | Measure-Object -Average).Average, 1)
    $avgTotal = [math]::Round(($totalCpuList | Measure-Object -Average).Average, 1)

    "| $TagName | $LangName | $avgRam | $avgUser | $avgSys | $avgTotal | " |  Add-Content -Path $SummarySys
}

# Hilfsfunktion: Go Garbage Collector Trace erfassen & auswerten
function Measure-GoGCTrace {
    param (
        [string]$BinPath,
        [string]$LogPath,
        [string]$TagName,
        [int]$WarmupRuns = 2,         [int]$MeasuredRuns = 5
    )

    Write-Host "  > Erfasse Go GC-Trace ($WarmupRuns Warmups,$MeasuredRuns Läufe)..." -ForegroundColor Yellow

    $gcLog = "$ResultsDir\gc_${TagName}.log"
    Remove-Item $gcLog -ErrorAction SilentlyContinue

    # 1. Warmup-Läufe
    for ($i = 1; $i -le$WarmupRuns; $i++) {$pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $BinPath
        $pinfo.Arguments = "`"$LogPath`""
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $proc.WaitForExit()
    }

    # 2. Gemessene Läufe (stderr anhängen)
    $allStderr = ""
    for ($run = 1; $run -le$MeasuredRuns; $run++) {$pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $BinPath
        $pinfo.Arguments = "`"$LogPath`""
        $pinfo.UseShellExecute = $false
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.EnvironmentVariables["GODEBUG"] = "gctrace=1"

        $process = [System.Diagnostics.Process]::Start($pinfo)
        $allStderr += $process.StandardError.ReadToEnd()
        $process.WaitForExit()
    }

    Set-Content -Path $gcLog -Value $allStderr -Encoding utf-8

    $gcLogPy =$gcLog.Replace('\', '/')
    $SummaryGCPy =$SummaryGC.Replace('\', '/')

    # 3. Python berechnet den Durchschnitt über alle Runs
    $PyExtractGC = @"
import re

gc_log = '$gcLogPy'
tag = '$TagName'
summary_file = '$SummaryGCPy'
runs = $MeasuredRuns

gc_count = 0
total_clock_ms = 0.0
max_heap_mb = 0.0

pattern = re.compile(r'gc (\d+).*?: ([\d\.\+]+) ms clock, ([\d\.\+/]+) ms cpu, (\d+)->(\d+)->(\d+) MB')

try:
    with open(gc_log, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            match = pattern.search(line)
            if match:
                gc_count += 1
                clock_parts = [float(x) for x in match.group(2).split('+')]
                total_clock_ms += sum(clock_parts)
                heap_before = float(match.group(4))
                if heap_before > max_heap_mb:
                    max_heap_mb = heap_before
except Exception as e:
    print(f"  [Python Error processing GC Trace] {e}")

# Durch die Anzahl der Messläufe teilen, um Durchschnitt pro Durchlauf zu erhalten
avg_gc_runs_per_execution = round(gc_count / runs, 1) if runs > 0 else 0
avg_total_pause_per_execution = round(total_clock_ms / runs, 2) if runs > 0 else 0.0
avg_pause_per_run = round(total_clock_ms / gc_count, 3) if gc_count > 0 else 0.0

out_line = f"| {tag} | {avg_gc_runs_per_execution} | {avg_total_pause_per_execution} | {avg_pause_per_run} | {max_heap_mb:.2f} |\n"

with open(summary_file, 'a', encoding='utf-8') as f:
    f.write(out_line)
"@

    python -c "$PyExtractGC"
}

function Measure-VMMapMetrics {
    param (
        [string]$LangName,
        [string]$BinPath,
        [string]$LogPath,
        [string]$TagName
    )

    Write-Host "  > Erfasse VMMap Speicher-Analyse für $LangName..." -ForegroundColor Yellow

    $csvOut = "$ResultsDir\vmmap_${LangName}_${TagName}.csv"
    $mmpOut = "$ResultsDir\vmmap_${LangName}_${TagName}.mmp"
    
    Start-Sleep -Milliseconds 250

    try {
        # 1. Start-Info vorbereiten & BENCHMARK_PAUSE explizit in den Prozess injizieren
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $BinPath
        $pinfo.Arguments = "`"$LogPath`""
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $pinfo.EnvironmentVariables["BENCHMARK_PAUSE"] = "1"

        # 2. Prozess starten (schläft nun für 2 Sekunden am Ende der Ausführung)
        $targetProc = [System.Diagnostics.Process]::Start($pinfo)
        $targetPid = $targetProc.Id

        # 100ms warten, damit das Memory-Mapping von Stufe 3 aktiv aufgebaut ist
        Start-Sleep -Milliseconds 100

        # 3. VMMap via PID anhängen (-p <PID>)
        $argsCsv = @("-p", $targetPid, $csvOut)
        $vmmapProc = Start-Process -FilePath $VMMapPath -ArgumentList $argsCsv -PassThru -WindowStyle Hidden

        # Warten, bis der Prozess und VMMap geordnet fertig sind
        $null = $targetProc.WaitForExit(5000)
        $null = $vmmapProc.WaitForExit(5000)

        if (-not $vmmapProc.HasExited) {
            try { $vmmapProc.Kill() } catch {}
        }

        # 4. Zweiter Durchlauf für den .mmp Snapshot
        $targetProcSnap = [System.Diagnostics.Process]::Start($pinfo)
        Start-Sleep -Milliseconds 100

        $argsMmp = @("-p", $targetProcSnap.Id, $mmpOut)
        $vmmapSnap = Start-Process -FilePath $VMMapPath -ArgumentList $argsMmp -PassThru -WindowStyle Hidden

        $null = $targetProcSnap.WaitForExit(5000)
        $null = $vmmapSnap.WaitForExit(5000)
        if (-not $vmmapSnap.HasExited) { try { $vmmapSnap.Kill() } catch {} }

    } catch {
        Write-Host "  [VMMap Fehler] Konnte Speicheranalyse nicht durchführen: $_" -ForegroundColor Red
        return
    }

    Start-Sleep -Milliseconds 300

    if (-not (Test-Path $csvOut)) {
        Write-Host "  [VMMap Fehler] CSV-Datei wurde nicht erzeugt ($csvOut)" -ForegroundColor Red
        return
    }

    # Pfade für Python maskieren
    $csvOutPy = $csvOut.Replace('\', '/')
    $SummaryVMMapPy = $SummaryVMMap.Replace('\', '/')

    # Python-Script Auswertung
    $PyExtractVMMap = @"
import csv

csv_file = '$csvOutPy'
tag = '$TagName'
lang = '$LangName'
summary_file = '$SummaryVMMapPy'

def parse_vmmap_val(val_str):
    cleaned = val_str.strip().replace('.', '').replace(',', '')
    try:
        return float(cleaned)
    except ValueError:
        return 0.0

mapped_size, mapped_ws = 0.0, 0.0
heap_ws = 0.0
private_size, private_ws = 0.0, 0.0
total_ws = 0.0

try:
    with open(csv_file, 'r', encoding='utf-8', errors='ignore') as f:
        reader = csv.reader(f)
        for row in reader:
            if not row or len(row) < 3:
                continue
            
            category = row[0].strip()
            nums = [parse_vmmap_val(col) for col in row[1:]]
            
            if category in ["Mapped File", "Section", "Shareable"]:
                if len(nums) >= 1 and nums[0] > 0: mapped_size = max(mapped_size, nums[0] / 1024.0)
                if len(nums) >= 4 and nums[3] > 0: mapped_ws = max(mapped_ws, nums[3] / 1024.0)
                elif len(nums) >= 2 and nums[1] > 0: mapped_ws = max(mapped_ws, nums[1] / 1024.0)

            elif category == "Heap":
                if len(nums) >= 4 and nums[3] > 0: heap_ws = nums[3] / 1024.0
                elif len(nums) >= 2 and nums[1] > 0: heap_ws = nums[1] / 1024.0

            elif category == "Private Data":
                if len(nums) >= 1 and nums[0] > 0: private_size = nums[0] / 1024.0
                if len(nums) >= 4 and nums[3] > 0: private_ws = nums[3] / 1024.0
                elif len(nums) >= 2 and nums[1] > 0: private_ws = nums[1] / 1024.0

            elif category == "Total":
                if len(nums) >= 4 and nums[3] > 0: total_ws = nums[3] / 1024.0
                elif len(nums) >= 1 and nums[0] > 0: total_ws = nums[0] / 1024.0

    out_line = f"| {tag} | {lang} | {mapped_size:.1f} | {mapped_ws:.1f} | {heap_ws:.2f} | {private_size:.1f} | {total_ws:.1f} |\n"
    with open(summary_file, 'a', encoding='utf-8') as f:
        f.write(out_line)
except Exception as e:
    print(f"  [Python Error processing VMMap CSV] {e}")
"@

    python -c "$PyExtractVMMap"
}

try {
    # 1. Tabellenköpfe initialisieren
    "# 1. Gesamtauswertung: Laufzeit (Go vs. Zig)`nGemessen mit ``hyperfine`` (10 Durchläufe, 3 Warmups).`n`n| Stufe / Tag | Sprache / Command | Mean Time (ms) | StdDev (ms) | Min (ms) | Max (ms) |`n| :--- | :--- | :--- | :--- | :--- | :--- |" | Set-Content -Path $SummaryTime

    "# 2. System- & Perfmon-Metriken (Windows)`nGemessen via Win32 Process API & System Diagnostics.`n`n| Stufe / Tag | Sprache | Max RAM / Peak Working Set (MB) | User CPU Time (ms) | Kernel/System CPU Time (ms) | Total CPU Time (ms) |`n| :--- | :--- | :--- | :--- | :--- | :--- |" | Set-Content -Path $SummarySys

    "# 3. Go Garbage Collector Auswertung (GCTRACE)`nGemessen via ``GODEBUG=gctrace=1``.`n`n| Stufe / Tag | GC Runs (Anzahl) | Total GC Pause (ms) | Avg GC Pause / Run (ms) | Peak Heap before GC (MB) |`n| :--- | :--- | :--- | :--- | :--- |" | Set-Content -Path $SummaryGC

    "# 4. Speicheranalyse via VMMap (Windows)`nErfasst über Sysinternals VMMap CLI (Werte in Megabyte / MB).`n`n| Stufe / Tag | Sprache | Mapped File Size (MB) | Mapped File WS (MB) | Heap WS (MB) | Private Data Size (MB) | Total Working Set (MB) |`n| :--- | :--- | :--- | :--- | :--- | :--- | :--- |" | Set-Content -Path $SummaryVMMap

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
        
        # B) VMMap Speicheranalyse erfassen
        Measure-VMMapMetrics -LangName "Go" -BinPath $GoBin -LogPath $LogFile -TagName $Tag
        Measure-VMMapMetrics -LangName "Zig" -BinPath $ZigBin -LogPath $LogFile -TagName $Tag

        # C) Go GC Trace erfassen
        Measure-GoGCTrace -BinPath $GoBin -LogPath $LogFile -TagName$Tag

        # D) Hyperfine für präzise Gesamtlaufzeit ausführen
        Write-Host "  > Starte Hyperfine..." -ForegroundColor Yellow
        hyperfine --warmup 3 --runs 10 --export-json "$JsonOut" --command-name "Go ($Tag)" "$GoBin `"$LogFile`"" --command-name "Zig ($Tag)" "$ZigBin `"$LogFile`"" | Out-Null

        # E) JSON-Ergebnisse an die Laufzeit-Tabelle anhängen
        $SummaryTimePy = $SummaryTime.Replace('\', '/')
        $JsonOutPy = $JsonOut.Replace('\', '/')
        $PyScript = @"
import json

json_file = '$JsonOutPy'
tag = '$Tag'
summary_file = '$SummaryTimePy'

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
    Write-Host "`nFüge Auswertungs-Tabellen in $SummaryFile zusammen..." -ForegroundColor Yellow

    # Falls die Hauptdatei existiert, leeren oder neu anlegen
    "" | Set-Content -Path $SummaryFile -Encoding utf-8

    # 1. Laufzeit-Tabelle anhängen
    if (Test-Path $SummaryTime) {
        Get-Content $SummaryTime | Add-Content -Path $SummaryFile
        "`n<br>`n" | Add-Content -Path $SummaryFile
        Remove-Item $SummaryTime -ErrorAction SilentlyContinue
    }

    # 2. System-Metriken-Tabelle anhängen
    if (Test-Path $SummarySys) {
        Get-Content $SummarySys | Add-Content -Path $SummaryFile
        "`n<br>`n" | Add-Content -Path $SummaryFile
        Remove-Item $SummarySys -ErrorAction SilentlyContinue
    }
    
    # 3. GC Trace Tabelle anhängen
    if (Test-Path $SummaryGC) {
        Get-Content $SummaryGC | Add-Content -Path $SummaryFile
        "`n<br>`n" | Add-Content -Path $SummaryFile
        Remove-Item $SummaryGC -ErrorAction SilentlyContinue
    }

    # 4. VMMap-Tabelle anhängen
    if (Test-Path $SummaryVMMap) {
        Get-Content $SummaryVMMap | Add-Content -Path $SummaryFile
        Remove-Item $SummaryVMMap -ErrorAction SilentlyContinue
    }

    # Ursprünglichen Git-Branch wiederherstellen
    Set-Location $ProjectRoot
    git checkout --force $OriginalBranch | Out-Null
    git stash pop | Out-Null
}

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host " MASTER-BENCHMARK ERFOLGREICH ABGESCHLOSSEN!" -ForegroundColor Cyan
Write-Host " Alle Ergebnisse gebündelt in: $SummaryFile" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan