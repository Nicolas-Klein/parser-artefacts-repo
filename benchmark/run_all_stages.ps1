$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path "$ScriptDir\.."
$LogFile = "$ProjectRoot\benchmark_large.log"
$ResultsDir = "$ScriptDir\results"
$SummaryFile = "$ResultsDir\master_summary-windows.md"

$SummaryTime = "$ResultsDir\summary_time_win.md"
$SummarySys = "$ResultsDir\summary_sys_win.md"
$SummaryVMMap = "$ResultsDir\summary_vmmap_win.md"
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

    while (-not $process.HasExited) {
        try {
            $process.Refresh()
            $currentWorkingSet = $process.WorkingSet64
            if ($currentWorkingSet -gt $peakWorkingSet) {
                $peakWorkingSet = $currentWorkingSet
            }
        } catch {}
        Start-Sleep -Milliseconds 10
    }

    $process.WaitForExit()

    try {
        if ($process.PeakWorkingSet64 -gt $peakWorkingSet) {
            $peakWorkingSet = $process.PeakWorkingSet64
        }
    } catch {}

    $maxRamMb = [math]::Round($peakWorkingSet / 1MB, 2)
    $userCpuMs = [math]::Round($process.UserProcessorTime.TotalMilliseconds, 1)
    $sysCpuMs = [math]::Round($process.PrivilegedProcessorTime.TotalMilliseconds, 1)
    $totalCpuMs = [math]::Round($process.TotalProcessorTime.TotalMilliseconds, 1)

    "| $TagName | $LangName | $maxRamMb | $userCpuMs | $sysCpuMs | $totalCpuMs |" | Add-Content -Path $SummarySys
}

# Hilfsfunktion: Go Garbage Collector Trace erfassen & auswerten
function Measure-GoGCTrace {
    param (
        [string]$BinPath,
        [string]$LogPath,
        [string]$TagName
    )

    Write-Host "  > Erfasse Go GC-Trace (GODEBUG=gctrace=1)..." -ForegroundColor Yellow

    $gcLog = "$ResultsDir\gc_${TagName}.log"

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $BinPath
    $pinfo.Arguments = "`"$LogPath`""
    
    $pinfo.UseShellExecute = $false$pinfo.RedirectStandardOutput = $true$pinfo.RedirectStandardError = $true$pinfo.EnvironmentVariables["GODEBUG"] = "gctrace=1"

    $process = [System.Diagnostics.Process]::Start($pinfo)$stderr = $process.StandardError.ReadToEnd()$process.WaitForExit()

    # GC-Output auf Festplatte schreiben
    Set-Content -Path $gcLog -Value$stderr -Encoding utf-8

    # Pfade für Python aufbereiten
    $gcLogPy =$gcLog.Replace('\', '/')
    $SummaryGCPy =$SummaryGC.Replace('\', '/')

    $PyExtractGC = @"
import re

gc_log = '$gcLogPy'
tag = '$TagName'
summary_file = '$SummaryGCPy'

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

avg_pause = round(total_clock_ms / gc_count, 3) if gc_count > 0 else 0.0
total_clock_ms = round(total_clock_ms, 2)

out_line = f"| {tag} | {gc_count} | {total_clock_ms} | {avg_pause} | {max_heap_mb:.2f} |\n"

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