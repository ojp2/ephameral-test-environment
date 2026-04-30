import sys, json
try:
    d = json.load(sys.stdin)
    for r in d.get("status", {}).get("resources", []):
        if r.get("name") == "jmeter" and r.get("kind") == "Job":
            h = r.get("health", {}).get("status", "")
            s = r.get("status", "")
            print(h if h else s)
            sys.exit(0)
    print("unknown")
except Exception:
    print("unknown")