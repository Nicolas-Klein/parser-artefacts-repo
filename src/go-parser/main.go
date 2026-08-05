package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"runtime/pprof"
	"strconv"
	"strings"
	"time"
)

func main() {
	profileFlag := flag.Bool("profile", false, "Aktiviert CPU- und Memory-Profiling")

	flag.Parse()

	// flag.Arg(0) holt das ERSTE Argument nach den verarbeiteten Flags
	if flag.NArg() < 1 {
		fmt.Println("Fehler: Kein Dateipfad angegeben.")
		fmt.Println("Nutzung: ./go-parser-artefact [-profile] <pfad-zur-logdatei>")
		os.Exit(1)
	}

	if *profileFlag {
		f, _ := os.Create("cpu.prof")
		defer f.Close()
		pprof.StartCPUProfile(f)
		defer pprof.StopCPUProfile()
	}

	fmt.Println("GO-Parser")

	filepath := flag.Arg(0)

	file, err := os.Open(filepath)
	if err != nil {
		fmt.Printf("Fehler beim Öffnen der Datei: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	statusCounts := make(map[int]int)
	var lineCount int64 = 0

	fmt.Println("Starte Go-Parser (Stufe 1: Baseline)...")
	startTime := time.Now()

	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := scanner.Text()
		lineCount++

		parts := strings.Split(line, " ")

		if len(parts) >= 9 {
			statusStr := parts[8]
			if status, err := strconv.Atoi(statusStr); err == nil {
				statusCounts[status]++
			}
		}
	}

	if err := scanner.Err(); err != nil {
		fmt.Printf("Fehler beim Lesen der Datei: %v\n", err)
		os.Exit(1)
	}

	elapsed := time.Since(startTime)

	fmt.Println("\n--- Parsing abgeschlossen ---")
	fmt.Printf("Verarbeitete Zeilen: %d\n", lineCount)
	fmt.Printf("Benötigte Zeit: %v\n", elapsed)
	fmt.Println("Statuscode-Statistik:")
	for code, count := range statusCounts {
		fmt.Printf("    HTTP %d: %d\n", code, count)
	}

	if *profileFlag {
		// Tipp: Garbage Collector kurz vor dem Heap-Snapshot steuern oder
		// während des Parsings allozierten Gesamtspeicher auslesen
		fm, _ := os.Create("mem.prof")
		defer fm.Close()
		pprof.WriteHeapProfile(fm)
	}
}
