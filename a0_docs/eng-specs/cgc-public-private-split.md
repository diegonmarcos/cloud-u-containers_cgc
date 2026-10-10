# cgc knowledge-graph pipeline: public/private split

Status: phases 1-2 done (2026-10-09): both repos live, CI and leak scan green, pvt pinned to
7fdcf5f, cloud-infra `cgc-db-restore.yml` live (dispatch-only). Phase 3 (first green run) waits on repository
secrets (section 8); phases 4-5 follow the order in section 7.

Spec for the indexer itself (chunk windows, manifests, GraphRAG on top of semantic):
`a0_docs/eng-specs/cgc-incremental-chunked.md` (moved here from cloud-infra; its paths
are relative to this repo, the layout is the same).

## 1. Decision

The cgc pipeline left cloud-infra and was split by **surface**:

| Repo | Visibility | Holds | Indexes |
|---|---|---|---|
| `diegonmarcos/cloud-u-containers_cgc` (this repo) | public | all pipeline code (scripts, chunk planner, packaging, restore script, testers, specs), the reusable `cgc-db-index.yml`, the **pub** orchestrator `cgc-db.yml` | the 6 public repos |
| `diegonmarcos/cloud-u-containers_cgc-pvt` | **private** | the **pvt** orchestrator only; calls this repo's `cgc-db-index.yml` pinned by sha | the 2 private repos |
| `diegonmarcos/cloud-infra` | public | `cgc-db-restore.yml`: restore-all onto oci-apps for one surface per run (WireGuard + SSH + `ship-wg-runner` lock) | nothing |

Naming: the code ran as part of the cloud-u-containers service `user-ai_cloud-cgc-pub-mcp`
(its build.json is the pipeline's config), and split-outs are named `<parent>_<name>`
(registry: `git-repos-master/repos.json`, group `a_cloud`).

### Why a separate private repo, not cloud-infra

cloud-infra is **public**. Every cgc-db index job for `cloud-data` and
`cloud-data-my-ai-memory` printed private file paths and file content (export strings,
AI descriptions) to public Actions logs; see section 6.1. The private surface therefore
needed a private home for its *runs*, not just for its config. A called reusable workflow
runs in the **caller's** context (jobs, logs, secrets are the caller's), so the private
orchestrator calling public code still produces private logs.

### Why restore stays in cloud-infra

Restore-all needs the WireGuard mesh and SSH to oci-apps. The mesh client in CI is ONE
WireGuard peer (`gha-runner`) shared with every fleet deploy, serialised by cloud-infra's
`ship-wg-runner` concurrency group (`queue: max`). Concurrency groups do not span
repositories, so a restore started from another repo would race deploys for the peer
slot (the 2026-08-24 incident shape, run 32721840450) and add a second repo holding
`WG_PRIVATE_KEY` + `OCI_SSH_KEY`. Restore logs carry only repo names, image names,
counts and the mesh IP already published in cloud-u-containers' build.json (verified on
job 113748705828), so keeping them in cloud-infra exposes nothing new. Both orchestrators
end by **dispatching** `cloud-infra/cgc-db-restore.yml` with their surface and the cgc
commit to run; cloud-infra validates that commit is on this repo's `main`.

### Shared code: consumed by sha, not copied

The private side consumes this repo's code pinned by sha (`uses: …/cgc-db-index.yml@<sha>`
plus `cgc_ref: <sha>`, which makes the index jobs check out the same commit's scripts),
and cloud-infra's restore fetches `cloud-cgc-db-restore-all.sh` at the dispatched sha.
Chosen over a copy + parity guard because:

* the two pipelines must agree byte-for-byte on the on-disk contract (per-repo image
  layout, `.cgc-manifest-<phase>.json`, `.cgc-chunks-<phase>.json`, `.cgc-status-<phase>.json`,
  base image tag, octocode pin); a copy can only detect drift after the fact, a pin
  cannot drift;
* updating the private side is a one-line, reviewable sha bump in a repo nobody else
  writes;
* the private repo's tester asserts `uses:@sha == cgc_ref` so the workflow and the
  scripts can never come from different commits.

### Service code (cloud-cgc-pub-mcp, kg-ingest, octocode-export): recommendation

Not moved. It is deployed by cloud-u-containers' ship path (one dir per service, a
`build.json` the derive engine and `ship.yml` glob) and runs as the `cloud-cgc-pub-mcp` and
`cloud-cgc-pvt-mcp` containers from ONE image. Moving it would need: a container build
+ GHCR publish workflow here, a cloud-u-containers `build.json` that points at an
external image, and the derive engine's `a_solutions/*/build.json` contract to accept a
service whose source is elsewhere. Recommended as a follow-up once that ship path exists;
until then the pipeline reads the service's build.json as its config and that is the
only coupling.

Also noted: cloud-u-containers carries its own `user-ai_cloud-cgc-pub-mcp/src/cloud-cgc-db-restore-all.sh`
(630 lines), an older diverged copy. The shipped one is this repo's
`1_cicd/src/ops/cloud-cgc-db-restore-all.sh`; the other should be deleted or made a pointer.

## 2. Surface mapping

| | **pub** | **pvt** |
|---|---|---|
| Orchestrator | `cloud-u-containers_cgc/.github/workflows/cgc-db.yml` | `cloud-u-containers_cgc-pvt/.github/workflows/cgc-db.yml` |
| Logs | public | private |
| Repos indexed | cloud-infra, cloud-infra-desktop, front (= diegonmarcos.github.io), front-data, cloud-u-containers, cloud-u-android | cloud-data, cloud-data-my-ai-memory |
| Repo set source | `index_repos − private_repos` (build.json), each verified public via unauthenticated GitHub API at run time | `private_repos` |
| GHCR images written | `ghcr.io/diegonmarcos/cgc-db-<repo>:latest` (+ `:latest-force-<phase>`) for the 6 public repos; public packages linked to their own repos | same names for the 2 private repos; private packages linked to `cloud-me_vault` |
| GHCR images read at restore | base + the 6 public images | base + **all 8** images (pvt is the full store) |
| Shared | `ghcr.io/diegonmarcos/cgc-db-base:0.22.0` (read by both, auto-seeded only if missing) | same |
| Chunk/manifest state | inside each repo's own image (`.cgc-chunks-<phase>.json`, `.cgc-status-<phase>.json`, `.cgc-manifest-<phase>.json`) | same |
| Restore | `cloud-infra/cgc-db-restore.yml surfaces=pub` | `cloud-infra/cgc-db-restore.yml surfaces=pvt` |
| LanceDB volume (oci-apps) | `octocode_db` | `octocode_db_pvt` |
| MCP container | `cloud-cgc-pub-mcp` (port 3105, public route `mcp.diegonmarcos.com/cloud-cgc-pub-mcp`) | `cloud-cgc-pvt-mcp` (port 3107, mesh-only route `/cloud-cgc-pvt-mcp`) |
| kg-store (SurrealDB) | `kg_store_pub` 127.0.0.1:8002, refreshed ONLY by the pub restore, private repos stripped | `kg_store_pvt` 127.0.0.1:8001, refreshed ONLY by the pvt restore, all staged repos |

Writers never overlap: the two orchestrators write disjoint image sets, and each restore
writes only its own volume and its own kg-store
(`cloud-cgc-db-restore-all.sh`: `CGC_INCLUDE_PRIVATE=0` → pub store only, `=1` → pvt
store only; `CGC_KG_REFRESH=both` restores the old two-store refresh). The pvt store keeps
the public repos: the pvt restore stages every image, so public updates reach it on the
next pvt cycle (at most 12 h later).

Baseline before the split (pub MCP, `SELECT repo, count() FROM file GROUP BY repo`):
cloud-infra 476, cloud-infra-desktop 121, cloud-u-android 29, cloud-u-containers 11,
front 2022, front-data 29. No private repo in the pub store.

## 3. Guards (all executed by testers)

* `cgc-db-index.yml`: `surface=pvt` refuses unless the **calling** repository is private
  (GitHub API); `surface=pub` matrix = public repos only, each probed unauthenticated
  (HTTP 200 or refuse); the `repos` input can only narrow within the surface.
* `cloud-cgc-db-update.sh` `cgc_apply_surface`: `CGC_SURFACE=pub` drops private repos
  from the default list, refuses an explicitly named one, refuses when `private_repos`
  is unreadable; `ensure_repos` never clones a private repo on pub.
* Log redaction (`octo_log_redact`): any private repo's octocode output that reaches a log
  is reduced to count-shaped lines unless the caller is the verified private repo
  (`CGC_LOG_REDACT=off` is only set for `surface=pvt`).
* Restore: the existing `CGC_INCLUDE_PRIVATE` guard (pvt target may not be the public
  volume) plus the per-surface kg refresh above.
* Testers: `cgc-db-surface-split.test.sh` (30 checks + 6 mutations),
  `cgc-db-private-log-redact.test.sh` (21 checks).

## 4. Overlap protection during the move

Both new orchestrators start with a `guard` job:

1. scheduled runs skip every job unless the repo variable `CGC_SCHEDULE_ENABLED=true`
   (the cutover switch; dispatch always runs). `guard` itself is skipped at job level, so a
   pre-cutover scheduled run ends green (one notice job, every other job skipped), never
   cancelled or failed;
2. any run refuses while a run of the **legacy** `cloud-infra/.github/workflows/cgc-db.yml`
   is queued or in progress (public API; 404 after the legacy file is deleted = drained).
   The legacy pipeline writes the same `cgc-db-<repo>:latest` tags and chunk state, and
   concurrency groups cannot serialise across repositories, so this is the one
   cross-repo exclusion.

Progress carries over unchanged: same image names, same tags, same in-image state files.

## 5. Phases

1. Design + audit: this document.
2. Repos created, code pushed (history kept, section 6.3), registered in
   `git-repos-master/repos.json`, cloud-master `repos.json` and cloud-infra's fleet
   manifest (`0_apps/src/manifest.json` → Claude settings, dotfiles, leak-scan gate).
   cloud-infra gains `cgc-db-restore.yml` (dispatch-only; inert until called).
3. Green once: dispatch the pub orchestrator (`phase=semantic repos=front-data restore=false`
   first, then a full run) once the legacy run in flight has finished; then the pvt
   orchestrator. Needs section 8's secrets.
4. Cut over (one window between two crons, 04:00/16:00 UTC):
   a. message the #888 agent with the new run locations;
   b. merge the cloud-infra change that deletes `cgc-db.yml`, `cgc-db-index.yml`,
      `cgc-db-propagate.yml` (legacy schedule gone; any still-queued legacy run keeps its
      pinned sha and the new guards wait for it);
   c. set `CGC_SCHEDULE_ENABLED=true` in both new repos;
   d. verify both MCPs: pub counts ≥ baseline above, pvt counts include cloud-data and
      cloud-data-my-ai-memory, both `kg_store_*` refreshed by their own restore.
5. Remove the moved files from cloud-infra. cloud-infra is main-only (its
   reference-transaction hook refuses new branches), so this is one commit on main,
   made in the same window as 4b, AFTER #888's run 37929244331 has finished (any push
   touching `unjam-ship.yml` triggers Unjam Ship, which cancels in-progress lock holders
   older than 25 min: it did so to 37843203892 on 2026-10-09):
   * delete `1_cicd/{src/cicd,dist}/` + `.github/workflows/` copies of `cgc-db.yml`,
     `cgc-db-index.yml`, `cgc-db-propagate.yml`; `ship-cgc-db-seed.yml` and
     `cloud-cgc-db-seed.sh` are proposed for retirement (one run ever; update.sh
     auto-seeds a missing base), owner to confirm;
   * delete `1_cicd/{src/ops,dist/scripts}/cloud-cgc-db-{update,chunk,package,pull,restore-all,restore,seed}.sh`
     and `cloud-cgc-verify-surfaces.sh` (this repo is the source);
   * delete the moved testers in `9_others/test/` and `9_others/dist/test/`
     (every `cgc-db-*.test.sh` listed in this repo) and their `9_others/test-registry.json`
     entries; drop lint-pipeline's hand-written steps for
     `cgc-db-lance-integrity.test.sh` and `cgc-db-noindex-private.test.sh`
     (`1_cicd/src/cicd/lint-pipeline.yml` and its copies);
   * retarget, do not delete: `cgc-db-ssh-retry.test.sh` and `cgc-db-poll-liveness.test.sh`
     test the restore STEP, which now lives in `cgc-db-restore.yml` (change `YML=`);
     `test_ship_burst_no_dropped_deploy.sh` reads `cgc-db-index.yml`'s
     `restore-all.concurrency` (line ~246) → `cgc-db-restore.yml`;
     `unjam-ship.yml` `WG_WORKFLOWS` drops `cgc-db.yml` and `cgc-db-propagate.yml`
     (and `ship-cgc-db-seed.yml` if retired) and keeps `cgc-db-restore.yml`;
     `1_cloud-configs/src/derive/derive-code-signatures.test.ts` defaults
     `CGC_DB_UPDATE_SH` to cloud-infra's update.sh: point it at a checkout of this repo;
   * comment-only mentions (`wg_group_jobs.py`, `test_wg_group_lock_bounded.sh`,
     `health_mail_full.yml`, `startup-gpu-embed.sh`, `ship-terraform.yml`,
     `dispatch-policy.json`, `derive-repo-map.ts`) can follow later;
   * delete `a0_docs/eng-specs/cgc-incremental-chunked.md` there (moved here).
6. Delete the logs of 37843203892 and 37929244331 once both are completed (section 6.1).

## 6. Public-safety audit (2026-10-09)

### 6.1 Finding: private repo content in cloud-infra's public logs (fixed)

* cloud-infra is public. cgc-db index jobs for private repos replayed octocode's last
  40-60 lines (file paths, exported symbols, AI descriptions), smart-noindex directory
  names and the graphrag overview. Example: run 37843203892, job 113811440672.
* Stopped at the source: cloud-infra 8c188f344 + 9676011e1 (`octo_log_redact`, tester
  `cgc-db-private-log-redact.test.sh`).
* Logs deleted (runs kept) for **229** completed runs that executed a private-repo index
  job: 142 of `cgc-db.yml` (per-repo matrix jobs for cloud-data / cloud-data-my-ai-memory,
  and the pre-matrix "index all repos" job) and 87 of the monolith `ship-cgc-db.yml`,
  2026-06-25 → 2026-10-07. Two runs were live and are pending deletion once complete:
  37843203892 and 37929244331 (they run the pre-fix code).
* Residual: cloud-infra commit 8c188f344's message names the leaked directory shape; it
  cannot be rewritten (shared history). It names no file content.

### 6.2 This repo's content (HEAD and full history)

* gitleaks 8.30.1 (the fleet's pinned, checksum-verified build) over all 143 commits, with
  the fleet ruleset (`.gitleaks.toml`) and with the default ruleset: **no leaks**.
* No key material (PEM, WireGuard private keys, `ghp_`/`github_pat_`/`sk-or-`/AWS keys) in
  any added line of history.
* Secrets are referenced by NAME only (`secrets.*`), resolved from repo secrets.
* IPs present: `10.0.0.1`, `10.0.0.6` (RFC 1918 WireGuard mesh, also in the public
  cloud-u-containers build.json), `129.151.228.66` (oci-apps public address, in a comment
  in history; also in public cloud-infra), `127.0.0.x`. No WireGuard config, no peer keys,
  no hub public key value.
* Internal names present (oci-apps, container and volume names, ports): all already public
  in cloud-u-containers and cloud-infra. They identify, they do not grant.
* Private-repo strings: the redaction tester's fixtures were made synthetic and the older
  fixture text was replaced throughout this repo's history before the first push.
* The history was extracted from cloud-infra after its own secret purge (#759/#760); the
  fleet `history-gate` markers apply here too (`.githooks/purged-history`).

### 6.3 History

`git filter-repo` over a fresh clone in /dev/shm, keeping only the moved source paths and
their earlier locations (`1_workflows/src/{scripts,cicd,test}/`, `1_configs/src/...`),
renamed onto this layout. Source: cloud-infra `9676011e1`. 143 commits, authorship kept.

## 7. Cutover invariants

* never two writers on one GHCR tag (section 4);
* schedule switched only after a green run of the new path;
* legacy workflows removed in the same window the new schedules are enabled;
* no surface loses data: restores are additive per repo (`kg-ingest` shrink guard,
  per-repo images), and nothing is deleted from GHCR.

## 8. Secrets (least privilege)

`cloud-u-containers_cgc` (public):

| Secret | Scope | Why |
|---|---|---|
| `CGC_GHCR_PAT` | classic PAT: `write:packages`, `read:packages`, `delete:packages` (no `repo`) | push `cgc-db-<public repo>` packages (linked to their own repos, so `GITHUB_TOKEN` cannot); delete is the visibility backstop. Public repos need no `repo` scope for the visibility probe. |
| `OPENROUTER_API_KEY` | OpenRouter key, ideally a dedicated one with a spend cap | graphrag LLM calls |
| `CLOUD_INFRA_DISPATCH_TOKEN` | fine-grained PAT, repository `diegonmarcos/cloud-infra` only, Actions: read and write | dispatch `cgc-db-restore.yml surfaces=pub` |
| variable `CGC_SCHEDULE_ENABLED` | repo variable, `true` at cutover | schedule switch |

`cloud-u-containers_cgc-pvt` (private):

| Secret | Scope | Why |
|---|---|---|
| `CGC_GHCR_PAT` | classic PAT: `write:packages`, `read:packages`, `delete:packages`, `repo` (the visibility probe reads private repos; packages link to `cloud-me_vault`) | push the 2 private packages |
| `OPENROUTER_API_KEY` | as above | graphrag |
| `CLOUD_DATA_DEPLOY_KEY` | read-only deploy key on `cloud-data` (the existing one can be reused) | clone |
| `CLOUD_MY_AI_MEMORY_DEPLOY_KEY` | read-only deploy key on `cloud-data-my-ai-memory` | clone |
| `CLOUD_INFRA_DISPATCH_TOKEN` | as above | dispatch `cgc-db-restore.yml surfaces=pvt` |
| variable `CGC_SCHEDULE_ENABLED` | `true` at cutover | schedule switch |

`cloud-infra`: unchanged (`CGC_GHCR_PAT` for the box's GHCR login on the pvt restore,
`WG_PRIVATE_KEY`, `OCI_SSH_KEY`, `vars.WG_HUB_PUBKEY`).
