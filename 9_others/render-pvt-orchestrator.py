#!/usr/bin/env python3
"""Render the PVT orchestrator from this repo's PUB orchestrator.

    python3 9_others/render-pvt-orchestrator.py <cgc-sha> [path/to/cgc-db.yml] > cgc-db.yml

diegonmarcos/cloud-me_cgc (private) commits the output as its
.github/workflows/cgc-db.yml. Its tester re-renders from the pinned sha and fails on any
difference, so the two orchestrators cannot drift: every change lands here first and
reaches the private side as a sha bump.

Each substitution must apply exactly the expected number of times; a pub edit that
breaks one fails the render (and this repo's tester) instead of silently producing a
pvt orchestrator that still says `surface: pub`.

pvt differs from pub in these ways beyond names (#951):
  * the hosted-runner jobs (schedule-off, guard, coalesce) run on `self-hosted` too;
  * every index call passes `runner: self-hosted` — the private repo's own repo-scoped
    oci-apps runner (hosted minutes of a private repo come out of the account budget);
  * the `restore` job (a cross-repo dispatch that needs a PAT) is CUT: cloud-infra's
    cgc-db-restore.yml pulls — it polls the private packages and restores the pvt surface
    itself when one is newer than its last restore;
  * no secret is required besides the two deploy keys: the GHCR push uses the run's
    GITHUB_TOKEN and graphrag the keyless mesh relay (CGC_GHCR_PAT / OPENROUTER_API_KEY
    are still forwarded, as optional overrides).
"""
import re
import sys

USES = "diegonmarcos/cloud-u-containers_cgc/.github/workflows/cgc-db-index.yml"
PVT_RUNNER = "self-hosted"
# The pub restore job starts at this comment and runs to the end of the file.
RESTORE_START = "  # Propagation onto oci-apps needs the WireGuard mesh and SSH."
PVT_RESTORE = (
    "  # No restore job here (#951). cloud-infra's cgc-db-restore.yml PULLS: on its schedule\n"
    "  # it compares the private cgc-db-<repo> packages with its last pvt restore and, when\n"
    "  # one is newer, restores the pvt surface itself. No cross-repo token in this repo.\n"
)


def render(src: str, sha: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"render: '{sha}' is not a 40-hex commit sha")
    body = src[src.index("\nname: ") + 1:]  # drop the pub header box
    if body.count(RESTORE_START) != 1:
        raise SystemExit(f"render: expected 1 occurrence of {RESTORE_START!r}, found {body.count(RESTORE_START)}")
    body = body[:body.index(RESTORE_START)] + PVT_RESTORE
    subs = [
        ('name: "cgc-db (pub surface:', 'name: "cgc-db (pvt surface:', 1),
        ("'cgc-db pub · ", "'cgc-db pvt · ", 2),
        ("subset of the PUBLIC index repos", "subset of the PRIVATE index repos", 1),
        ("Ask cloud-infra to restore the pub surface afterwards (default true).",
         "No effect on the pvt surface: cloud-infra's cgc-db-restore.yml pulls new private images itself (#951).", 1),
        ("uses: ./.github/workflows/cgc-db-index.yml", f"uses: {USES}@{sha}", 3),
        # #951: hosted minutes of a private repo come out of the account budget, so the
        # guard/coalesce/schedule-off jobs run on the same repo-scoped runner too.
        ("    runs-on: ubuntu-latest\n", f"    runs-on: {PVT_RUNNER}\n", 3),
        ("      surface: pub\n", f"      surface: pvt\n      cgc_ref: {sha}\n      runner: {PVT_RUNNER}\n", 3),
        ("      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}\n",
         "      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}\n"
         "      CLOUD_DATA_DEPLOY_KEY: ${{ secrets.CLOUD_DATA_DEPLOY_KEY }}\n"
         "      CLOUD_MY_AI_MEMORY_DEPLOY_KEY: ${{ secrets.CLOUD_MY_AI_MEMORY_DEPLOY_KEY }}\n", 3),
    ]
    for old, new, n in subs:
        got = body.count(old)
        if got != n:
            raise SystemExit(f"render: expected {n} occurrence(s) of {old!r}, found {got}")
        body = body.replace(old, new)
    for leftover in ("surface: pub", "surfaces=pub", "./.github/workflows/cgc-db-index.yml",
                     "CLOUD_INFRA_DISPATCH_TOKEN", "gh workflow run"):
        if leftover in body:
            raise SystemExit(f"render: pub-only text survived: {leftover!r}")
    head = (
        "# GENERATED — do not edit. Rendered by cloud-u-containers_cgc's\n"
        f"# 9_others/render-pvt-orchestrator.py from its .github/workflows/cgc-db.yml @ {sha}.\n"
        "# Bump: sh 9_others/bump.sh <new sha>. The tester re-renders and diffs.\n"
        "#\n"
        "# cloud-cgc octocode DB — PVT surface orchestrator. Indexes the PRIVATE repos only\n"
        "# (build.json private_repos) by calling the public reusable cgc-db-index.yml pinned\n"
        "# by sha; this repository is private, so these runs' logs are private. The index\n"
        f"# jobs run on this repo's own self-hosted oci-apps runner (runs-on: {PVT_RUNNER}).\n"
        "# cloud-infra's cgc-db-restore.yml then PULLS the new private images and restores the\n"
        "# pvt surface (octocode_db_pvt + kg_store_pvt, all 8 repos) — nothing here dispatches.\n"
        "# Spec: cloud-u-containers_cgc a0_docs/eng-specs/cgc-public-private-split.md\n\n"
    )
    return head + body


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    path = sys.argv[2] if len(sys.argv) == 3 else ".github/workflows/cgc-db.yml"
    sys.stdout.write(render(open(path, encoding="utf8").read(), sys.argv[1]))
