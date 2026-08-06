package main

import (
	"flag"
	"fmt"
	"os"
	"runtime/pprof"
	"time"

	"golang.org/x/sys/unix"
)

func fastParseInt(b []byte) int {
	n := 0

	for _, ch := range b {
		if ch >= '0' && ch <= '9' {
			n = n*10 + int(ch-'0')
		}
	}

	return n
}

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

	// Open File
	file, err := os.Open(filepath)
	if err != nil {
		fmt.Printf("Fehler beim Öffnen der Datei: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	// File size for mmap
	fi, err := file.Stat()
	if err != nil {
		fmt.Printf("Fehler beim Abrufen der Dateigröße: %v\n", err)
	}
	size := int(fi.Size())

	if size == 0 {
		fmt.Println("Datei ist leer.")
		return
	}

	data, err := unix.Mmap(int(file.Fd()), 0, size, unix.PROT_READ, unix.MAP_SHARED)
	if err != nil {
		fmt.Printf("mmap-Fehler: %v\n", err)
		os.Exit(1)
	}
	defer unix.Munmap(data)

	statusCounts := make(map[int]int)
	var lineCount int64 = 0

	fmt.Println("Starte Go-Parser (Stufe 2: Zero-Copy & mmap)...")
	startTime := time.Now()

	i := 0
	length := len(data)

	for i < length {
		lineStart := i

		for i < length && data[i] != '\n' {
			i++
		}

		line := data[lineStart:i]
		i++
		lineCount++

		spaceCount := 0
		tokenStart := 0
		foundStatus := false

		for j := 0; j < len(line); j++ {
			if line[j] == ' ' {
				if spaceCount == 8 {
					code := fastParseInt(line[tokenStart:j])

					if code > 0 {
						statusCounts[code]++
					}

					foundStatus = true
					break
				}
				spaceCount++
				tokenStart = j + 1
			}
		}

		if !foundStatus && spaceCount == 8 {
			code := fastParseInt(line[tokenStart:])

			if code > 0 {
				statusCounts[code]++
			}
		}
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
