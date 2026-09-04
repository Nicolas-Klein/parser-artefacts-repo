package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"runtime"
	"runtime/pprof"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

// === WINDOWS MMAP IMPLEMENTIERUNG ===
func mmapFileWindows(f *os.File, size int) ([]byte, error) {
	// CreateFileMapping
	h, err := syscall.CreateFileMapping(syscall.Handle(f.Fd()), nil, syscall.PAGE_READONLY, 0, 0, nil)
	if err != nil {
		return nil, fmt.Errorf("CreateFileMapping failed: %v", err)
	}
	// Wichtig: Handle nach dem Mapping schließen
	defer syscall.CloseHandle(h)

	// MapViewOfFile
	addr, err := syscall.MapViewOfFile(h, syscall.FILE_MAP_READ, 0, 0, 0)
	if err != nil {
		return nil, fmt.Errorf("MapViewOfFile failed: %v", err)
	}

	// Byte-Slice aus Pointer rekonstruieren
	// unsafe.Slice ist der moderne Go-Weg (ab Go 1.17)
	var data []byte
	sliceHeader := (*[1 << 30]byte)(unsafe.Pointer(addr))
	data = sliceHeader[:size:size]

	return data, nil
}

func munmapWindows(data []byte) error {
	addr := uintptr(unsafe.Pointer(&data[0]))
	return syscall.UnmapViewOfFile(addr)
}

func fastParseInt(b []byte) int {
	n := 0

	for _, ch := range b {
		if ch >= '0' && ch <= '9' {
			n = n*10 + int(ch-'0')
		}
	}

	return n
}

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

// Globaler sync.Pool zur Reduktion von Heap-Allokationen und GC-Druck
var entryPool = sync.Pool{
	New: func() any {
		return &LogEntry{}
	},
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
	// Trennung nach Leerzeichen ohne strings.Fields (Allokationsfrei)
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

type parseResult struct {
	counts          [1000]int64
	lineCount       int64
	parseErrorCount int64
}

func processChunk(data []byte, start, end int, wg *sync.WaitGroup, resultChan chan<- parseResult) {
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

		if len(line) == 0 {
			continue
		}
		res.lineCount++

		entry := entryPool.Get().(*LogEntry)
		err := parseLine(line, entry)

		if err != nil {
			res.parseErrorCount++
		} else {
			if entry.Statuscode < 1000 {
				res.counts[entry.Statuscode]++
			}
		}

		entry.Reset()
		entryPool.Put(entry)
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

	data, err := mmapFileWindows(file, size)
	if err != nil {
		fmt.Printf("Fehler bei mmap: %v\n", err)
		os.Exit(1)
	}
	defer munmapWindows(data)

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
		go processChunk(data, start, end, &wg, resultChan)
	}

	go func() {
		wg.Wait()
		close(resultChan)
	}()

	var totalStatusCounts [1000]int64
	var totalLineCount int64 = 0
	var totalErrorCount int64 = 0

	for res := range resultChan {
		totalLineCount += res.lineCount
		totalErrorCount += res.parseErrorCount
		for code := 0; code < 1000; code++ {
			totalStatusCounts[code] += res.counts[code]
		}
	}

	elapsed := time.Since(startTime)

	fmt.Println("\n--- Parsing abgeschlossen ---")
	fmt.Printf("Verarbeitete Zeilen: %d (Fehlerhaft: %d)\n", totalLineCount, totalErrorCount)
	fmt.Printf("Benötigte Zeit:      %v\n", elapsed)
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
