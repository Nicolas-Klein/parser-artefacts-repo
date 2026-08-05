package main

import (
	"fmt"
	"os"
	"runtime/pprof"
)

func main() {
	// CPU Profile schreiben
	f, _ := os.Create("cpu.prof")
	defer f.Close()
	pprof.StartCPUProfile(f)
	defer pprof.StopCPUProfile()

	fmt.Println("GO-Parser")

	// Speicher-Snapshot (Heap) am Ende schreiben
	fm, _ := os.Create("mem.prof")
	defer fm.Close()
	pprof.WriteHeapProfile(fm)
}
