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

type LogEntry struct {
	RemoteHost string
	Identity   string
	User       string
	Timestamp  string
	Request    string
	Statuscode int
	BytesSent  int64
}

func parseLine(line string) (LogEntry, error) {
	firstQuote := strings.IndexByte(line, '"')
	lastQuote := strings.LastIndexByte(line, '"')

	if firstQuote == -1 || lastQuote == -1 || firstQuote >= lastQuote {
		return LogEntry{}, fmt.Errorf("ungültiges Request-Format")
	}

	prefix := line[:firstQuote]
	request := line[firstQuote+1 : lastQuote]
	suffix := line[lastQuote+1:]

	prefixParts := strings.Fields(prefix)
	if len(prefixParts) < 4 {
		return LogEntry{}, fmt.Errorf("ungültiges Prefix-Format")
	}

	timestamp := strings.Join(prefixParts[3:], " ")

	suffixParts := strings.Fields(suffix)
	if len(suffixParts) < 1 {
		return LogEntry{}, fmt.Errorf("ungültiges Suffix-Format")
	}

	statusCode, err := strconv.Atoi(suffixParts[0])
	if err != nil {
		return LogEntry{}, fmt.Errorf("ungültiger Statuscode")
	}

	var bytesSent int64 = 0
	if len(suffixParts) >= 2 && suffixParts[1] != "-" {
		bytesSent, _ = strconv.ParseInt(suffixParts[1], 10, 64)
	}

	return LogEntry{
		RemoteHost: prefixParts[0],
		Identity:   prefixParts[1],
		User:       prefixParts[2],
		Timestamp:  timestamp,
		Request:    request,
		Statuscode: statusCode,
		BytesSent:  bytesSent,
	}, nil
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

	file, err := os.Open(filepath)
	if err != nil {
		fmt.Printf("Fehler beim Öffnen der Datei: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	statusCounts := make(map[int]int)
	var lineCount int64 = 0
	var parseErrorCount int64 = 0

	fmt.Println("Starte Go-Parser (Stufe 1: Baseline)...")
	startTime := time.Now()

	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := scanner.Text()
		lineCount++

		entry, err := parseLine(line)
		if err != nil {
			parseErrorCount++
			continue
		}

		statusCounts[entry.Statuscode]++
	}

	if err := scanner.Err(); err != nil {
		fmt.Printf("Fehler beim Lesen der Datei: %v\n", err)
		os.Exit(1)
	}

	elapsed := time.Since(startTime)

	fmt.Println("\n--- Parsing abgeschlossen ---")
	fmt.Printf("Verarbeitete Zeilen: %d (Fehlerhaft: %d)\n", lineCount, parseErrorCount)
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
