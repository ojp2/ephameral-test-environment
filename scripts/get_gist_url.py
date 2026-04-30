import sys, json
try:
    d = json.load(sys.stdin)
    for r in d.get("status", {}).get("resources", []):
        if r.get("name") == "jmeter-gist-url" and r.get("kind") == "ConfigMap":
            print(r.get("liveState", {}).get("data", {}).get("url", "not-found"))
            sys.exit(0)
    print("not-found")
except Exception:
    print("not-found")