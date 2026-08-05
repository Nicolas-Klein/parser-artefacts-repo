import random
import time

ips = [f"192.168.1.{random.randint(1, 255)}" for _ in range(100)]
methods = ["GET", "POST", "PUT", "DELETE"]
resources = ["/index.html", "/api/v1/login", "/images/logo.png", "/css/style.css"]
statuses = [200, 201, 304, 400, 404, 500]

# Generiert ca. 10 Millionen Zeilen (ca. 1 GB)
with open("benchmark_large.log", "w") as f:
    start_time = time.time()
    for i in range(10_000_000):
        ip = random.choice(ips)
        method = random.choice(methods)
        resource = random.choice(resources)
        status = random.choice(statuses)
        size = random.randint(100, 5000)
        # Standard Common Log Format
        f.write(f'{ip} - - [14/Jul/2026:12:00:00 +0200] "{method} {resource} HTTP/1.1" {status} {size}\n')
    print(f"Datei generiert in {time.time() - start_time:.2f} Sekunden.")