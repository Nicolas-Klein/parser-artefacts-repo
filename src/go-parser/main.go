package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"runtime"
	"runtime/pprof"
	"sync"
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

type parseResult struct {
	counts    [1000]int64
	lineCount int64
}

func processChunck(data []byte, start, end int, wg *sync.WaitGroup, resultChan chan<- parseResult) {
	defer wg.Done()

	var res parseResult

	if start > 0 {
		for start < end && data[start-1] != '\n' {
			start++
		}
	}

	if end < len(data) {
		for end < len(data) && data[end-1] != '\n' {
			end++
		}
	}

	i := start

	for i < end {
		lineStart := i

		for i < end && data[i] != '\n' {
			i++
		}

		line := data[lineStart:i]
		i++

		if len(line) < 10 {
			continue
		}
		res.lineCount++

		quotePos := bytes.LastIndexByte(line, '"')

		if quotePos != -1 {
			rest := line[quotePos+1:]
			idx := 0

			for idx < len(rest) && rest[idx] == ' ' {
				idx++
			}

			if idx+3 <= len(rest) {
				code := fastParseInt(rest[idx : idx+3])

				if code < 1000 {
					res.counts[code]++
				}
			}
		}

	}

	resultChan <- res

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

	numWorkers := runtime.NumCPU()
	fmt.Printf("GO-Parser (Stufe 3: Multi-Threading mit %d Core)\n", numWorkers)

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

	fmt.Println("Starte Go-Parser (Stufe 3: Multi-Threading)...")
	startTime := time.Now()

	chunckSize := size / numWorkers
	var wg sync.WaitGroup
	resultChan := make(chan parseResult, numWorkers)

	for w := 0; w < numWorkers; w++ {
		start := w * chunckSize
		end := start + chunckSize
		if w == numWorkers-1 {
			end = size
		}

		wg.Add(1)
		go processChunck(data, start, end, &wg, resultChan)
	}

	go func() {
		wg.Wait()
		close(resultChan)
	}()

	var totalStatusCounts [1000]int64
	var totalLineCount int64 = 0

	for res := range resultChan {
		totalLineCount += res.lineCount
		for code := 0; code < 1000; code++ {
			totalStatusCounts[code] += res.counts[code]
		}
	}

	elapsed := time.Since(startTime)

	fmt.Println("\n--- Parsing abgeschlossen ---")
	fmt.Printf("Verarbeitete Zeilen: %d\n", totalLineCount)
	fmt.Printf("Benötigte Zeit: %v\n", elapsed)
	fmt.Println("Statuscode-Statistik:")
	for code, count := range totalStatusCounts {

		if count > 0 {
			fmt.Printf("    HTTP %d: %d\n", code, count)
		}

	}

	if *profileFlag {
		// Tipp: Garbage Collector kurz vor dem Heap-Snapshot steuern oder
		// während des Parsings allozierten Gesamtspeicher auslesen
		fm, _ := os.Create("mem.prof")
		defer fm.Close()
		pprof.WriteHeapProfile(fm)
	}
}
