#!/usr/bin/env bash
# #352/#375: the per-repo index STEP must time out before its JOB does, so a slow
# repo ends the run as FAILURE (graphrag still runs) and not CANCELLED (graphrag skipped).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IDX="$ROOT/.github/workflows/cgc-db-index.yml"
ORC="$ROOT/.github/workflows/cgc-db.yml"
job=$(awk '/^  index:/{i=1} i&&/^    timeout-minutes:/{print $2; exit}' "$IDX")
step=$(awk '/^  index:/{i=1} i&&/- name: "cgc-db incremental update/{s=1} s&&/^        timeout-minutes:/{print $2; exit}' "$IDX")
[ -n "$job" ] && [ -n "$step" ] || { echo "FAIL $IDX: job=$job step=$step (missing)"; exit 1; }
[ "$step" -lt "$job" ] || { echo "FAIL $IDX: step $step >= job $job"; exit 1; }
echo "ok $IDX: step $step < job $job"
grep -q "!cancelled()" "$ORC" && grep -q "needs.semantic.result == 'failure'" "$ORC" \
  || { echo "FAIL graphrag gate no longer accepts semantic failure"; exit 1; }
# 2026-10-05: a hosted-runner acquisition failure CANCELS a job. graphrag must still run
# after a cancelled semantic result.
grep -q "needs.semantic.result == 'cancelled'" "$ORC" || { echo "FAIL $ORC: graphrag gate rejects cancelled semantic"; exit 1; }
# Propagation moved to cloud-infra's cgc-db-restore.yml (mesh + ship-wg-runner lock live
# there). The orchestrator must still ask for it after a partial or cancelled phase, so
# the dispatch job is gated on !cancelled(), never on success.
awk '/^  restore:/{r=1} r&&/^    if:/{i=1} i&&/!cancelled\(\)/{f=1} r&&/gh workflow run cgc-db-restore.yml/{d=1} END{exit !(f&&d)}' "$ORC" \
  || { echo "FAIL $ORC: restore dispatch job missing or not gated on !cancelled()"; exit 1; }
# No job in the index workflow may touch the mesh.
! grep -q -i -E 'wireguard|WG_PRIVATE_KEY|OCI_SSH_KEY' "$IDX" || { echo "FAIL $IDX: index workflow references mesh credentials"; exit 1; }
echo PASS
