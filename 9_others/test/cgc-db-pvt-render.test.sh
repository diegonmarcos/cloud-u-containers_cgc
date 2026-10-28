#!/bin/sh
# The private orchestrator (cloud-me-pvt-cgc) is RENDERED from this repo's
# .github/workflows/cgc-db.yml by 9_others/render-pvt-orchestrator.py. A pub edit that
# breaks a substitution must fail HERE, before anyone bumps the private pin onto it.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567
python3 "$ROOT/9_others/render-pvt-orchestrator.py" "$SHA" "$ROOT/.github/workflows/cgc-db.yml" > "$T/pvt.yml"
python3 - "$T/pvt.yml" "$SHA" <<'PY'
import sys, yaml
y = yaml.safe_load(open(sys.argv[1])); sha = sys.argv[2]; bad = []
j = y["jobs"]
for ph in ("per-repo", "semantic", "graphrag"):
    w = j[ph]["with"]; s = j[ph]["secrets"]
    if w.get("surface") != "pvt": bad.append(f"{ph}: surface {w.get('surface')}")
    if w.get("cgc_ref") != sha: bad.append(f"{ph}: cgc_ref {w.get('cgc_ref')}")
    if j[ph]["uses"] != f"diegonmarcos/cloudy-u-containers_cgc/.github/workflows/cgc-db-index.yml@{sha}": bad.append(f"{ph}: uses {j[ph]['uses']}")
    for k in ("CLOUD_DATA_DEPLOY_KEY", "CLOUD_MY_AI_MEMORY_DEPLOY_KEY"):
        if k not in s: bad.append(f"{ph}: secret {k} not passed")
    # #951: the private caller's index jobs run on its own self-hosted runner.
    if w.get("runner") != "self-hosted": bad.append(f"{ph}: runner {w.get('runner')}")
for jn in ("schedule-off", "guard", "coalesce"):
    if j[jn].get("runs-on") != "self-hosted": bad.append(f"{jn}: runs-on {j[jn].get('runs-on')}")
# #951: no cross-repo dispatch (and so no PAT) in the private orchestrator; cloud-infra pulls.
if "restore" in j: bad.append("pvt orchestrator still has a restore (dispatch) job")
txt = open(sys.argv[1]).read()
for tok in ("CLOUD_INFRA_DISPATCH_TOKEN", "gh workflow run", "secrets.CLOUD_INFRA"):
    if tok in txt: bad.append(f"pvt orchestrator mentions {tok}")
if y.get("concurrency", {}).get("group") != "cgc-db": bad.append("concurrency group lost")
if "guard" not in j: bad.append("guard job lost")
print("\n".join("  FAIL " + b for b in bad) or "  ok   rendered pvt orchestrator: surface pvt, pinned uses + cgc_ref, self-hosted runner, deploy keys, no dispatch")
sys.exit(1 if bad else 0)
PY
# A wrong sha shape is refused, never rendered.
if python3 "$ROOT/9_others/render-pvt-orchestrator.py" main "$ROOT/.github/workflows/cgc-db.yml" >/dev/null 2>&1; then echo "  FAIL render accepted a branch name as the pin"; exit 1; fi
echo "  ok   render refuses a non-sha pin"
echo PASS
