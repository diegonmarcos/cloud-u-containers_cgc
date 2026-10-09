#!/usr/bin/env python3
"""Render the PVT orchestrator from this repo's PUB orchestrator.

    python3 9_others/render-pvt-orchestrator.py <cgc-sha> [path/to/cgc-db.yml] > cgc-db.yml

diegonmarcos/cloud-u-containers_cgc-pvt (private) commits the output as its
.github/workflows/cgc-db.yml. Its tester re-renders from the pinned sha and fails on any
difference, so the two orchestrators cannot drift: every change lands here first and
reaches the private side as a sha bump.

Each substitution must apply exactly the expected number of times; a pub edit that
breaks one fails the render (and this repo's tester) instead of silently producing a
pvt orchestrator that still says `surface: pub`.
"""
import re
import sys

USES = "diegonmarcos/cloud-u-containers_cgc/.github/workflows/cgc-db-index.yml"


def render(src: str, sha: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"render: '{sha}' is not a 40-hex commit sha")
    body = src[src.index("\nname: ") + 1:]  # drop the pub header box
    subs = [
        ('name: "cgc-db (pub surface:', 'name: "cgc-db (pvt surface:', 1),
        ("'cgc-db pub · ", "'cgc-db pvt · ", 2),
        ("subset of the PUBLIC index repos", "subset of the PRIVATE index repos", 1),
        ("restore the pub surface afterwards", "restore the pvt surface afterwards", 1),
        ("uses: ./.github/workflows/cgc-db-index.yml", f"uses: {USES}@{sha}", 3),
        ("      surface: pub\n", f"      surface: pvt\n      cgc_ref: {sha}\n", 3),
        ("      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}\n",
         "      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}\n"
         "      CLOUD_DATA_DEPLOY_KEY: ${{ secrets.CLOUD_DATA_DEPLOY_KEY }}\n"
         "      CLOUD_MY_AI_MEMORY_DEPLOY_KEY: ${{ secrets.CLOUD_MY_AI_MEMORY_DEPLOY_KEY }}\n", 3),
        ("cgc-db-restore (pub)", "cgc-db-restore (pvt)", 1),
        ("Dispatch the pub-surface restore", "Dispatch the pvt-surface restore", 1),
        ('-f surfaces=pub -f cgc_ref="${{ github.sha }}"', f'-f surfaces=pvt -f cgc_ref="{sha}"', 1),
        ("surfaces=pub cgc_ref=${{ github.sha }}", f"surfaces=pvt cgc_ref={sha}", 2),
    ]
    for old, new, n in subs:
        got = body.count(old)
        if got != n:
            raise SystemExit(f"render: expected {n} occurrence(s) of {old!r}, found {got}")
        body = body.replace(old, new)
    for leftover in ("surface: pub", "surfaces=pub", "./.github/workflows/cgc-db-index.yml"):
        if leftover in body:
            raise SystemExit(f"render: pub-only text survived: {leftover!r}")
    head = (
        "# GENERATED — do not edit. Rendered by cloud-u-containers_cgc's\n"
        f"# 9_others/render-pvt-orchestrator.py from its .github/workflows/cgc-db.yml @ {sha}.\n"
        "# Bump: sh 9_others/bump.sh <new sha>. The tester re-renders and diffs.\n"
        "#\n"
        "# cloud-cgc octocode DB — PVT surface orchestrator. Indexes the PRIVATE repos only\n"
        "# (build.json private_repos) by calling the public reusable cgc-db-index.yml pinned\n"
        "# by sha; this repository is private, so these runs' logs are private. Then asks\n"
        "# cloud-infra to restore the pvt surface (octocode_db_pvt + kg_store_pvt, all 8\n"
        "# repos). Spec: cloud-u-containers_cgc a0_docs/eng-specs/cgc-public-private-split.md\n\n"
    )
    return head + body


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    path = sys.argv[2] if len(sys.argv) == 3 else ".github/workflows/cgc-db.yml"
    sys.stdout.write(render(open(path, encoding="utf8").read(), sys.argv[1]))
