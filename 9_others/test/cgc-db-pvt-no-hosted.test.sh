#!/bin/sh
# #951: on the pvt surface NO job may run on a GitHub-hosted runner (the account budget
# blocks hosted jobs of the private repo). In cgc-db-index.yml every job's runs-on must be
# the pvt-aware expression (hosted only as the pub fallback); in the rendered pvt
# orchestrator every job must be `self-hosted` or a reusable-workflow call.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567
python3 "$ROOT/9_others/render-pvt-orchestrator.py" "$SHA" "$ROOT/.github/workflows/cgc-db.yml" > "$T/pvt.yml"
python3 - "$ROOT/.github/workflows/cgc-db-index.yml" "$T/pvt.yml" <<'PY'
import sys, yaml
bad = []
for j, d in yaml.safe_load(open(sys.argv[1]))["jobs"].items():
    r = str(d.get("runs-on", ""))
    if "inputs.surface == 'pvt' && inputs.runner" not in r:
        bad.append(f"index workflow job {j}: runs-on {r!r} is not pvt-aware")
for j, d in yaml.safe_load(open(sys.argv[2]))["jobs"].items():
    if "uses" in d: continue
    if d.get("runs-on") != "self-hosted":
        bad.append(f"pvt orchestrator job {j}: runs-on {d.get('runs-on')!r}")
print("\n".join("  FAIL " + b for b in bad) or "  ok   no hosted runs-on on the pvt surface")
sys.exit(1 if bad else 0)
PY
echo PASS
