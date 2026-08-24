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
	// 1. Naives Zerlegen der gesamten Zeile an jedem Leerzeichen
	parts := strings.Split(line, " ")
	if len(parts) < 9 {
		return LogEntry{}, fmt.Errorf("ungültiges Log-Format: zu wenige Tokens")
	}

	// 2. RemoteHost, Identity und User aus den ersten drei Tokens auslesen
	remoteHost := parts[0]
	identity := parts[1]
	user := parts[2]

	// 3. Timestamp suchen: Tokens zwischen '[' und ']' wieder zusammenfügen
	startTS := -1
	endTS := -1
	for i := 3; i < len(parts); i++ {
		if startTS == -1 && strings.HasPrefix(parts[i], "[") {
			startTS = i
		}
		if startTS != -1 && strings.HasSuffix(parts[i], "]") {
			endTS = i
			break
		}
	}
	if startTS == -1 || endTS == -1 {
		return LogEntry{}, fmt.Errorf("ungültiges Timestamp-Format")
	}
	timestamp := strings.Join(parts[startTS:endTS+1], " ")

	// 4. Request suchen: Tokens zwischen den ersten und letzten Anführungszeichen zusammenfügen
	startReq := -1
	endReq := -1
	for i := endTS + 1; i < len(parts); i++ {
		if startReq == -1 && strings.HasPrefix(parts[i], "\"") {
			startReq = i
		}
		if startReq != -1 && strings.HasSuffix(parts[i], "\"") {
			endReq = i
			break
		}
	}
	if startReq == -1 || endReq == -1 {
		return LogEntry{}, fmt.Errorf("ungültiges Request-Format")
	}

	// Anführungszeichen am Anfang und Ende des gefügten Strings entfernen
	rawRequest := strings.Join(parts[startReq:endReq+1], " ")
	request := strings.Trim(rawRequest, "\"")

	// 5. Suffix (Statuscode & BytesSent) aus den Tokens nach dem Request lesen
	suffixIdx := endReq + 1
	if suffixIdx >= len(parts) {
		return LogEntry{}, fmt.Errorf("ungültiges Suffix-Format")
	}

	statusCode, err := strconv.Atoi(parts[suffixIdx])
	if err != nil {
		return LogEntry{}, fmt.Errorf("ungültiger Statuscode")
	}

	var bytesSent int64 = 0
	if suffixIdx+1 < len(parts) && parts[suffixIdx+1] != "-" {
		bytesSent, _ = strconv.ParseInt(parts[suffixIdx+1], 10, 64)
	}

	return LogEntry{
		RemoteHost: remoteHost,
		Identity:   identity,
		User:       user,
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
