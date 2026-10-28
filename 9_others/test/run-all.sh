#!/bin/sh
# Runs every tester under 9_others/test/ (*.test.sh). Needs cloud-u-containers checked
# out at a_solutions/ (CI does it; locally: git clone .../cloud-u-containers a_solutions).
# Exit 1 if any tester fails; each tester's own output says why.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json" ] \
  || { echo "::error::a_solutions/user-ai_cloud-cgc-pub-mcp/build.json missing — check out diegonmarcos/cloudy-u-containers at a_solutions/"; exit 1; }
failed=""
for t in "$ROOT"/9_others/test/*.test.sh; do
  n=$(basename "$t")
  if bash "$t" > "/tmp/run-all.$$.log" 2>&1; then
    echo "PASS $n"
  else
    echo "FAIL $n"; tail -25 "/tmp/run-all.$$.log" | sed 's/^/    /'
    failed="$failed $n"
  fi
done
rm -f "/tmp/run-all.$$.log"
[ -z "$failed" ] || { echo "::error::failed:$failed"; exit 1; }
echo "all testers passed"
