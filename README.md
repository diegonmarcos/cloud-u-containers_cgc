# cloud-u-containers_cgc

The **public** half of the cgc code knowledge graph pipeline: octocode indexes of the
public repos of [diegonmarcos](https://github.com/diegonmarcos), published per repo to
`ghcr.io/diegonmarcos/cgc-db-<repo>:latest` and served by the `cloud-cgc-pub-mcp` MCP
server. Split out of cloud-infra and cloud-u-containers (split-outs are named
`<parent>_<name>`).

* `.github/workflows/cgc-db.yml`: pub orchestrator (semantic, then graphrag), twice daily.
* `.github/workflows/cgc-db-index.yml`: reusable index phase, one matrix job per repo.
  Also called, pinned by sha, by the private orchestrator in `cloud-u-containers_cgc-pvt`.
* `1_cicd/src/ops/`: index, chunk planner, packaging, pull and restore scripts.
* `9_others/test/`: testers (`sh 9_others/test/run-all.sh`, needs
  `diegonmarcos/cloud-u-containers` checked out at `a_solutions/`).
* `a0_docs/eng-specs/`: `cgc-public-private-split.md` (how the surfaces are split, the
  safety audit, cutover) and `cgc-incremental-chunked.md` (how indexing works).

Only public repos are ever indexed from here: this repository's Actions logs are public.
Config comes from `user-ai_cloud-cgc-pub-mcp/build.json` in cloud-u-containers.
