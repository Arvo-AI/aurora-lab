import sys, time, requests
mode, url = sys.argv[1], sys.argv[2]
mb = int(sys.argv[3]) if len(sys.argv) > 3 else 40
def gen():
    for _ in range(mb * 4):
        yield b"x" * 262144
        time.sleep(0.25)
try:
    r = requests.post(url, data=gen(), timeout=90) if mode == "upload" else requests.get(url, timeout=90)
    print("python requests status:", r.status_code, r.text[:40].strip())
except Exception as e:
    print(f"python requests error: {type(e).__module__}.{type(e).__name__}: {e}")
