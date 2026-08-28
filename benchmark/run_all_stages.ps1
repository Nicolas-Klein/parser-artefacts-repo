$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path "$ScriptDir\.."
$LogFile = "$ProjectRoot\generator\benchmark_large.log"
$ResultsDir = "$ScriptDir\results"
$SummaryFile = "$ResultsDir\master_summary.md"

$Tags = @("new-stage1-windows", "new-stage2-windows", "new-stage3-windows")

New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# Aktuellen Branch sichern
$OriginalBranch = (git rev-parse --abbrev-ref HEAD)
git stash push -m "Automated master benchmark temporary stash" | Out-Null

try {
    Set-Content -Path $SummaryFile -Value "# Gesamtauswertung aller Optimierungsstufen (Go vs. Zig)`n`n| Stufe / Tag | Sprache | Mean Time (ms) | StdDev (ms) | Min (ms) | Max (ms) |`n| :--- | :--- | :--- | :--- | :--- | :--- |"

    foreach ($Tag in $Tags) {
        Write-Host "`n--------------------------------------------------" -ForegroundColor Cyan
        Write-Host " 🚀 Verarbeite Git-Tag: $Tag" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------" -ForegroundColor Cyan

        git checkout --force $Tag

        # Kompilieren
        Write-Host "Kompiliere Go-Parser..."
        Set-Location "$ProjectRoot\src\go-parser"
        go build -o go-parser-artefact.exe main.go

        Write-Host "Kompiliere Zig-Parser..."
        Set-Location "$ProjectRoot\src\zig-parser"
        zig build-exe main.zig -O ReleaseFast -femit-bin=zig-parser-artefact.exe

        $GoBin = "$ProjectRoot\src\go-parser\go-parser-artefact.exe"
        $ZigBin = "$ProjectRoot\src\zig-parser\zig-parser-artefact.exe"
        $JsonOut = "$ResultsDir\results_$Tag.json"

        # Hyperfine ausführen
        hyperfine --warmup 3 --runs 10 --export-json "$JsonOut" --command-name "Go ($Tag)" "$GoBin $LogFile" --command-name "Zig ($Tag)" "$ZigBin $LogFile"
    }
}
finally {
    # Ursprünglichen Branch wiederherstellen
    Set-Location $ProjectRoot
    git checkout --force $OriginalBranch | Out-Null
    git stash pop | Out-Null
}