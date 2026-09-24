import sys
import re

def analyze_gctrace(file_path):
    gc_count = 0
    total_clock_ms = 0.0
    total_cpu_ms = 0.0
    max_heap_mb = 0.0
    
    # Regex zum Auslesen der Kernwerte aus der GCTRACE-Zeile
    # Bsp: gc 918 @3.576s 0%: 0.015+0.25+0.041 ms clock, 0.12+0/0/0+0.32 ms cpu, 3->3->0 MB, ...
    pattern = re.compile(r'gc (\d+).*?: ([\d\.\+]+) ms clock, ([\d\.\+/]+) ms cpu, (\d+)->(\d+)->(\d+) MB')

    with open(file_path, 'r') as f:
        for line in f:
            match = pattern.search(line)
            if match:
                gc_count += 1
                
                # 1. Clock Time (Wanduhrzeit der GC-Phasen aufsummierten ms)
                clock_parts = [float(x) for x in match.group(2).split('+')]
                total_clock_ms += sum(clock_parts)
                
                # 2. Heap-Belegung vor dem GC (MB)
                heap_before = float(match.group(4))
                if heap_before > max_heap_mb:
                    max_heap_mb = heap_before

    print("=" * 50)
    print("GO GARBAGE COLLECTOR ZUSAMMENFASSUNG (GCTRACE)")
    print("=" * 50)
    print(f"Anzahl GC-Zyklen (Total GC Runs) : {gc_count}")
    print(f"Gesamte GC-Pause (Total Wall Clock) : {total_clock_ms:.2f} ms")
    if gc_count > 0:
        print(f"Durchschnittliche GC-Pause/Run   : {total_clock_ms / gc_count:.3f} ms")
    print(f"Maximaler Heap vor GC (Peak Heap)  : {max_heap_mb:.2f} MB")
    print("=" * 50)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        analyze_gctrace(sys.argv[1])
    else:
        print("Nutzung: python parse_gctrace.py <gctrace_output.txt>")