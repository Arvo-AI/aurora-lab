import signal, sys, time

def on_term(signum, frame):
    print("app: got SIGTERM, exiting 0", flush=True)
    sys.exit(0)

signal.signal(signal.SIGTERM, on_term)
print("app: started", flush=True)
while True:
    time.sleep(1)
