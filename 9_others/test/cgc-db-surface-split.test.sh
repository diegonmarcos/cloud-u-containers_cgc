#!/bin/sh
# The public/private split (a0_docs/eng-specs/cgc-public-private-split.md).
#
# This repository is PUBLIC: its Actions logs and the packages it pushes are public. A
# private repo (build.json .runtime.octocode.private_repos) must therefore never be
# indexed, cloned or restored into a public store by anything that runs here. And each
# surface's restore must write only its own kg-store, so the public pipeline is never a
# writer of the private store.
#
# Every check EXECUTES the real code (functions and snippets extracted from the scripts
# and workflows), then the suite is re-run against mutated copies that must fail.
set -eu
ROOT=$(_d=$(cd "$(dirname "$0")" && pwd); while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d=$(dirname "$_d"); done; printf '%s' "$_d")
UPD="${UPD:-$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh}"
RST="${RST:-$ROOT/1_cicd/src/ops/cloud-cgc-db-restore-all.sh}"
IDX="${IDX:-$ROOT/.github/workflows/cgc-db-index.yml}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

BJ="$T/build.json"
cat > "$BJ" <<'J'
{"runtime":{"octocode":{
  "index_repos":["pub-a","priv-x","pub-b","priv-y"],
  "private_repos":["priv-x","priv-y"],
  "repo_map":{"pub-a":"pub-a","priv-x":"priv-x","pub-b":"pub-b","priv-y":"priv-y"}}}}
J

# ── 1. update.sh cgc_apply_surface, executed ────────────────────────────────────────
awk '/^cgc_apply_surface\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$UPD" > "$T/surface.sh"
ck "cgc_apply_surface extracted" "$(grep -c '^cgc_apply_surface() {' "$T/surface.sh")" "1"
run_surface() { # $1 surface, $2 REPOS, $3 CGC_INDEX_REPOS -> stdout "rc|REPOS"
  ( . "$T/surface.sh"; CGC_SURFACE="$1"; REPOS="$2"; CGC_INDEX_REPOS="$3"; export BJ
    ( cgc_apply_surface >/dev/null 2>&1; printf '0|%s' "$REPOS" ) || printf '%s|' "$?" )
}
ck "pub: default list drops every private repo" "$(run_surface pub 'pub-a priv-x pub-b priv-y' '')" "0|pub-a pub-b"
ck "pub: an explicitly named private repo is REFUSED" "$(run_surface pub 'priv-x' 'priv-x')" "1|"
ck "pub: mixed explicit list is refused, not narrowed" "$(run_surface pub 'pub-a priv-y' 'pub-a priv-y')" "1|"
ck "pub: explicit public repo passes" "$(run_surface pub 'pub-b' 'pub-b')" "0|pub-b"
ck "pvt: list unchanged" "$(run_surface pvt 'priv-x priv-y' '')" "0|priv-x priv-y"
ck "legacy (unset): list unchanged" "$(run_surface '' 'pub-a priv-x' '')" "0|pub-a priv-x"
ck "unknown surface refused" "$(run_surface both 'pub-a' '')" "1|"
BJ_SAVE="$BJ"; BJ="$T/missing.json"
ck "pub: unreadable build.json refuses (fail-safe)" "$(run_surface pub 'pub-a' '')" "1|"
BJ="$BJ_SAVE"

# ── 2. ensure_repos never clones a private repo on the pub surface ──────────────────
awk '/^ensure_repos\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$UPD" > "$T/ensure.sh"
skip_line=$(grep -n 'CGC_SURFACE" = "pub" ] && printf' "$T/ensure.sh" | head -1 | cut -d: -f1)
clone_line=$(grep -n 'clone -q' "$T/ensure.sh" | head -1 | cut -d: -f1)
ck "ensure_repos: pub skip precedes the first clone" "$([ -n "$skip_line" ] && [ -n "$clone_line" ] && [ "$skip_line" -lt "$clone_line" ] && echo yes || echo no)" "yes"
# Execute that skip condition with the private list cgc_apply_surface produced.
PRIVATE_LIST=$(jq -r '.runtime.octocode.private_repos[]' "$BJ")
skips() { CGC_SURFACE="$1"; lname="$2"; if [ "$CGC_SURFACE" = "pub" ] && printf '%s\n' "$PRIVATE_LIST" | grep -qxF "$lname"; then echo skip; else echo clone; fi; }
ck "pub surface skips priv-x" "$(skips pub priv-x)" "skip"
ck "pub surface clones pub-a" "$(skips pub pub-a)" "clone"
ck "pvt surface clones priv-x" "$(skips pvt priv-x)" "clone"
# The same condition text must be what ensure_repos really runs.
ck "ensure_repos carries that exact condition" "$(grep -c 'if \[ "\$CGC_SURFACE" = "pub" \] && printf '"'"'%s\\n'"'"' "\$PRIVATE_LIST" | grep -qxF "\$lname"; then' "$T/ensure.sh")" "1"

# ── 3. restore-all: each surface refreshes only its own kg-store, executed ──────────
awk '/case "\$\{CGC_KG_REFRESH:-surface\}" in/{p=1} p{print} p&&/kg_refresh "\$PVT_CONTAINER"/{exit}' "$RST" > "$T/kg.sh"
ck "kg refresh snippet extracted" "$(grep -c 'kg_refresh "\$PUB_CONTAINER"' "$T/kg.sh")" "1"
kg() { # $1 include_private, $2 CGC_KG_REFRESH -> which stores were written
  ( kg_refresh() { printf '%s ' "$1"; }
    PUB_CONTAINER=pubc; PVT_CONTAINER=pvtc; KG_PUBLIC_REPOS="pub-a"; STAGED_REPOS=" pub-a priv-x"
    CGC_INCLUDE_PRIVATE="$1"; CGC_KG_REFRESH="$2"
    . "$T/kg.sh" ) | sed 's/ $//'
}
ck "pub pass (include_private=0) writes ONLY kg_store_pub" "$(kg 0 '')" "pubc"
ck "pvt pass (include_private=1) writes ONLY kg_store_pvt" "$(kg 1 '')" "pvtc"
ck "CGC_KG_REFRESH=both keeps the legacy two-store refresh" "$(kg 0 both)" "pubc pvtc"

# ── 4. the reusable index workflow ───────────────────────────────────────────────────
python3 - "$IDX" "$T" <<'PY'
import sys, yaml
y = yaml.safe_load(open(sys.argv[1])); t = sys.argv[2]
w = lambda n, v: open(f"{t}/{n}", "w").write("" if v is None else str(v))
steps = y["jobs"]["repos"]["steps"]
guard = next(s for s in steps if s.get("name","").startswith("Surface guard"))["run"]
res = next(s for s in steps if s.get("id") == "repos")["run"]
w("guard", guard); w("resolve", res)
w("inputs", " ".join(sorted((y.get(True) or y.get("on"))["workflow_call"]["inputs"])))
idx_steps = y["jobs"]["index"]["steps"]
w("redact", next(s for s in idx_steps if s.get("name","").startswith("cgc-db graphrag update"))["env"].get("CGC_LOG_REDACT"))
w("runs_on", y["jobs"]["index"]["runs-on"])
w("max_par", y["jobs"]["index"]["strategy"]["max-parallel"])
w("repos_runs_on", y["jobs"]["repos"]["runs-on"])
w("runner_default", (y.get(True) or y.get("on"))["workflow_call"]["inputs"]["runner"]["default"])
PY
ck "surface is a workflow input" "$(tr ' ' '\n' < "$T/inputs" | grep -cx surface)" "1"
ck "redaction is switched off only for pvt" "$(cat "$T/redact")" "\${{ inputs.surface == 'pvt' && 'off' || '' }}"
# Execute the guard with a stubbed gh answering for the caller's visibility.
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "$STUB_PRIVATE"\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
sed 's/\${{ inputs.phase }}/semantic/g; s/'"'"'\${{ inputs.runner }}'"'"'/"$RUNNER_T"/' "$T/guard" > "$T/guard.sh"
# $3 = the runner input (default ubuntu-latest)
guard() { ( PATH="$T/bin:$PATH" STUB_PRIVATE="$2" CGC_SURFACE="$1" CALLER=x/y RUNNER_T="${3:-ubuntu-latest}" CGC_RUNNER=x sh "$T/guard.sh" >/dev/null 2>&1 && echo pass || echo refuse ); }
ck "pvt from a PUBLIC caller is refused" "$(guard pvt false)" "refuse"
ck "pvt from an unknown-visibility caller is refused" "$(guard pvt unknown)" "refuse"
ck "pvt from a PRIVATE caller passes" "$(guard pvt true)" "pass"
ck "pub from a public caller passes" "$(guard pub false)" "pass"
# #951: a self-hosted runner only for the private pvt caller; a public repo never gets one.
ck "runner input defaults to hosted" "$(cat "$T/runner_default")" "ubuntu-latest"
ck "pub asking for a self-hosted runner is refused" "$(guard pub false self-hosted)" "refuse"
ck "pvt from a public caller asking for one is refused" "$(guard pvt false self-hosted)" "refuse"
ck "pvt from a PRIVATE caller may use its self-hosted runner" "$(guard pvt true self-hosted)" "pass"
ck "index runs-on: pub always hosted, pvt the caller's choice" "$(cat "$T/runs_on")" "\${{ inputs.surface == 'pvt' && inputs.runner || 'ubuntu-latest' }}"
ck "index matrix capped at 1 on a self-hosted runner" "$(cat "$T/max_par")" "\${{ (inputs.surface == 'pvt' && inputs.runner != '' && inputs.runner != 'ubuntu-latest') && 1 || 8 }}"
ck "repo-matrix job stays hosted" "$(cat "$T/repos_runs_on")" "ubuntu-latest"
# Execute the matrix resolution (minus the network probe) against the fixture.
mkdir -p "$T/ws/a_solutions/user-ai_cloud-cgc-pub-mcp"; cp "$BJ" "$T/ws/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json"
awk '/if \[ "\$CGC_SURFACE" = pub \]; then/{exit} {print}' "$T/resolve" | sed "s/'\${{ inputs.repos }}'/\"\$FILTER_IN\"/; s/\${{ inputs.phase }}/semantic/g" > "$T/resolve.sh"
echo 'echo "repos=$REPOS_JSON" >> "$GITHUB_OUTPUT"' >> "$T/resolve.sh"
resolve() { ( cd "$T/ws" && : > out && GITHUB_OUTPUT=out CGC_SURFACE="$1" FILTER_IN="$2" sh "$T/resolve.sh" >/dev/null 2>&1 && sed -n 's/^repos=//p' out || echo refused ); }
ck "pub matrix = public repos only" "$(resolve pub '')" '["pub-a","pub-b"]'
ck "pvt matrix = private repos only" "$(resolve pvt '')" '["priv-x","priv-y"]'
ck "pub matrix refuses a private repo in the repos input" "$(resolve pub 'priv-x')" "refused"
ck "pvt matrix refuses a public repo in the repos input" "$(resolve pvt 'pub-a')" "refused"
ck "pub matrix narrows to a named public repo" "$(resolve pub 'pub-b')" '["pub-b"]'
ck "pub resolution probes GitHub visibility unauthenticated" "$(grep -c 'curl -s -o /dev/null -w .%{http_code}. "https://api.github.com/repos/diegonmarcos/\$remote"' "$T/resolve")" "1"

echo "cgc-db-surface-split: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

# ── mutations: each must turn the suite red ─────────────────────────────────────────
[ -n "${CGC_SPLIT_MUTANT:-}" ] && exit 0
m() { # $1 name, $2 file var, $3 sed expr
  cp "$(eval echo "\$$2")" "$T/mut"; sed -i "$3" "$T/mut"
  if cmp -s "$T/mut" "$(eval echo "\$$2")"; then echo "  FAIL mutation $1 did not apply"; exit 1; fi
  if env CGC_SPLIT_MUTANT=1 "$2=$T/mut" sh "$0" >/dev/null 2>&1; then echo "  FAIL mutation $1 survived"; exit 1; fi
  echo "  ok: mutation $1 caught"
}
m pub-keeps-private UPD 's/^          continue$/          :/'
m pub-ignores-explicit UPD 's/if \[ -n "\${CGC_INDEX_REPOS:-}" \]; then/if false; then/'
m ensure-clones-private UPD 's/if \[ "\$CGC_SURFACE" = "pub" \] \&\& printf/if false \&\& printf/'
m kg-both-always RST 's/\*)    if \[ "\${CGC_INCLUDE_PRIVATE:-0}" = "1" \]; then _kg_pub=0; _kg_pvt=1; else _kg_pub=1; _kg_pvt=0; fi ;;/*) _kg_pub=1; _kg_pvt=1 ;;/'
m pvt-from-public IDX 's/\[ "\$PRIV" = "true" \] ||/true ||/'
m pub-self-hosted IDX "s/runs-on: \${{ inputs.surface == 'pvt' \&\& inputs.runner || 'ubuntu-latest' }}/runs-on: \${{ inputs.runner }}/"
m pub-matrix-all IDX "s/pub) REPOS_JSON=\$(jq -nc --argjson a \"\$ALL\" --argjson p \"\$PRIV\" '\$a - \$p') ;;/pub) REPOS_JSON=\"\$ALL\" ;;/"
echo PASS
