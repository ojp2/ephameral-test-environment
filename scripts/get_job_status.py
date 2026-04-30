import sys, json
try:
    d = json.load(sys.stdin)
    for r in d.get("status", {}).get("resources", []):
        if r.get("name") == "jmeter" and r.get("kind") == "Job":
            health = r.get("health", {}).get("status", "")
            status = r.get("status", "")
            # ArgoCD reports Succeeded jobs as Healthy
            result = health if health else status
            print(result)
            sys.exit(0)
    print("unknown")
except Exception:
    print("unknown")