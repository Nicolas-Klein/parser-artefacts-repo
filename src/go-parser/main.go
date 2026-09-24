package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"runtime/pprof"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

type LogEntry struct {
	RemoteHost []byte
	Identity   []byte
	User       []byte
	Timestamp  []byte
	Request    []byte
	Statuscode int
	BytesSent  int64
}

// Reset bereinigt die Referenzen vor der Rückgabe in den sync.Pool
func (e *LogEntry) Reset() {
	e.RemoteHost = nil
	e.Identity = nil
	e.User = nil
	e.Timestamp = nil
	e.Request = nil
	e.Statuscode = 0
	e.BytesSent = 0
}

// Globaler sync.Pool zur Reduktion von Heap-Allokationen
var entryPool = sync.Pool{
	New: func() any {
		return &LogEntry{}
	},
}

// Allokationsfreie Integer-Parsing-Hilfsfunktion für Bytes
func fastParseInt(b []byte) int {
	n := 0
	for _, ch := range b {
		if ch >= '0' && ch <= '9' {
			n = n*10 + int(ch-'0')
		}
	}
	return n
}

func parseLine(line []byte, entry *LogEntry) error {
	firstQuote := bytes.IndexByte(line, '"')
	lastQuote := bytes.LastIndexByte(line, '"')

	if firstQuote == -1 || lastQuote == -1 || firstQuote >= lastQuote {
		return fmt.Errorf("ungültiges Request-Format")
	}

	prefix := line[:firstQuote]
	entry.Request = line[firstQuote+1 : lastQuote]
	suffix := line[lastQuote+1:]

	// 1. Prefix manuell parsen (RemoteHost, Identity, User, Timestamp)
	idx := 0

	// RemoteHost
	start := idx
	for idx < len(prefix) && prefix[idx] != ' ' {
		idx++
	}
	if idx >= len(prefix) {
		return fmt.Errorf("ungültiger RemoteHost")
	}
	entry.RemoteHost = prefix[start:idx]
	idx++

	// Identity
	start = idx
	for idx < len(prefix) && prefix[idx] != ' ' {
		idx++
	}
	if idx >= len(prefix) {
		return fmt.Errorf("ungültige Identity")
	}
	entry.Identity = prefix[start:idx]
	idx++

	// User
	start = idx
	for idx < len(prefix) && prefix[idx] != ' ' {
		idx++
	}
	if idx >= len(prefix) {
		return fmt.Errorf("ungültiger User")
	}
	entry.User = prefix[start:idx]
	idx++

	// Timestamp (Rest des Prefixes z.B. [10/Oct/2000:13:55:36 -0700])
	if idx < len(prefix) {
		entry.Timestamp = bytes.TrimSpace(prefix[idx:])
	}

	// 2. Suffix parsen (Statuscode & BytesSent)
	idx = 0
	for idx < len(suffix) && suffix[idx] == ' ' {
		idx++
	}
	start = idx
	for idx < len(suffix) && suffix[idx] != ' ' {
		idx++
	}
	if start == idx {
		return fmt.Errorf("ungültiger Statuscode")
	}

	entry.Statuscode = fastParseInt(suffix[start:idx])

	// BytesSent
	for idx < len(suffix) && suffix[idx] == ' ' {
		idx++
	}
	if idx < len(suffix) {
		if suffix[idx] != '-' {
			entry.BytesSent = int64(fastParseInt(suffix[idx:]))
		}
	}

	return nil
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

	fi, err := file.Stat()
	if err != nil {
		fmt.Printf("Fehler beim Abrufen der Dateigröße: %v\n", err)
		os.Exit(1)
	}

	size := int(fi.Size())
	if size == 0 {
		fmt.Println("Datei ist leer.")
		return
	}

	// 1. mmap anwenden
	data, err := unix.Mmap(int(file.Fd()), 0, size, unix.PROT_READ, unix.MAP_SHARED)
	if err != nil {
		fmt.Printf("Fehler bei mmap: %v\n", err)
		os.Exit(1)
	}
	defer unix.Munmap(data)

	statusCounts := make(map[int]int)
	var lineCount int64 = 0
	var parseErrorCount int64 = 0

	fmt.Println("Starte Go-Parser (Stufe 2: Speicheroptimierung)...")
	startTime := time.Now()

	i := 0
	for i < len(data) {
		lineStart := i
		for i < len(data) && data[i] != '\n' {
			i++
		}

		line := data[lineStart:i]
		i++ // \n überspringen

		if len(line) == 0 {
			continue
		}
		lineCount++

		// 3. sync.Pool Objekt leihen
		entry := entryPool.Get().(*LogEntry)

		err := parseLine(line, entry)
		if err != nil {
			parseErrorCount++
		} else {
			if entry.Statuscode < 1000 {
				statusCounts[entry.Statuscode]++
			}
		}

		// Objekt säubern und zurück in den Pool geben
		entry.Reset()
		entryPool.Put(entry)
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
		fm, _ := os.Create("mem.prof")
		defer fm.Close()
		pprof.WriteHeapProfile(fm)
	}
}
