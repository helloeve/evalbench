# horizontal_experiment

Compare four ways of giving **Claude Code** access to Cloud SQL for
PostgreSQL, holding the dataset, judge, and scorers constant.

| Variant | Tooling exposed to the agent | Source |
| --- | --- | --- |
| [`gcloud/`](gcloud) | None. Bare Claude Code — must shell out to `gcloud`, `psql`, etc. via Bash. | Baseline. |
| [`onemcp/`](onemcp) | Google's managed Cloud SQL admin MCP endpoint (`sqladmin.googleapis.com/mcp`). No local files. | Production-grade MCP. |
| [`toolbox_agent_skill/`](toolbox_agent_skill) | 8 per-domain skill folders. Each tool is a Node.js script invoked as `node <skill>/scripts/<tool>.js '{...}'`. | [helloeve/cloud-sql-postgresql] @ `main` |
| [`toolbox_cli_skill/`](toolbox_cli_skill) | One unified skill that drives the MCP Toolbox CLI directly (`toolbox --prebuilt cloud-sql-postgres list-tools / describe-tool / invoke`). | [helloeve/cloud-sql-postgresql] @ `toolbox-cli` |

[helloeve/cloud-sql-postgresql]: https://github.com/helloeve/cloud-sql-postgresql

All four variants share:

- The same dataset (`dataset.json` — currently one single-turn scenario: "list all Cloud SQL Postgres instances in project astana-evaluation").
- The same Claude Code build (`@anthropic-ai/claude-code@2.1.145`, model `claude-opus-4-8` on Vertex, region `global`).
- `ENABLE_TOOL_SEARCH=true`, exported by `run.sh` so Claude lazy-loads tool definitions across all variants.
- The same judge / simulated-user model (`gemini-2.5-pro` via `judge_model.yaml`).

So any score deltas come from the **tooling design**, not the agent or the prompts.

## Layout

```
horizontal_experiment/
├── README.md                       # this file
├── run.sh                          # orchestrator: clones the two helloeve branches into _skills/, wraps them as Claude Code plugin marketplaces, wipes .venv/fake_home_claude before each variant, then invokes ./evalbench/run.sh
├── dataset.json                    # shared scenarios (helloeve evals/gemini_dataset.json)
├── judge_model.yaml                # gemini-2.5-pro for simulated user + judge scorers
├── gcloud/                         # Variant: bare Claude Code, no setup
│   ├── claude_code_model.yaml
│   └── run_config.yaml
├── onemcp/                         # Variant: managed sqladmin MCP endpoint
│   ├── claude_code_model.yaml
│   └── run_config.yaml
├── toolbox_agent_skill/            # Variant: helloeve main (per-domain skills)
│   ├── claude_code_model.yaml
│   └── run_config.yaml
└── toolbox_cli_skill/              # Variant: helloeve toolbox-cli (unified skill)
    ├── claude_code_model.yaml
    └── run_config.yaml
```

`_skills/` is created by `run.sh` on demand (only when a selected variant needs it) and is `.gitignore`d in practice. The script writes a synthesized `.claude-plugin/marketplace.json` into each clone so Claude Code registers it as a local plugin marketplace.

## Setup

1. Confirm Application Default Credentials are present (needed by both Vertex auth and the `onemcp` MCP endpoint):

   ```bash
   gcloud auth application-default login
   ```

2. `run.sh` exports a default Cloud SQL target (`whaoyu-playground` / `whaoyupg` / `financial`) and `ENABLE_TOOL_SEARCH=true` for you. Override any of them from your shell before invoking `run.sh` if you want to point at a different instance:

   ```bash
   export CLOUD_SQL_POSTGRES_PROJECT=<project>
   export CLOUD_SQL_POSTGRES_INSTANCE=<instance>
   # ...etc
   ```

## Run

From the evalbench repo root. `run.sh` clones / refreshes the helloeve skill marketplaces on demand, wipes `.venv/fake_home_claude` before each variant (so cached MCP responses, prior plugin marketplaces, and session history don't shrink the next run's `cache_creation_input_tokens` to ~0 — see `datasets/startup-ping/FINDINGS.md`), then invokes `./evalbench/run.sh` for each variant in turn.

```bash
# All four variants
horizontal_experiment/run.sh

# One variant
horizontal_experiment/run.sh gcloud

# Any subset, in order
horizontal_experiment/run.sh onemcp toolbox_cli_skill
```

`EVAL_GCP_PROJECT_ID` and `EVAL_GCP_PROJECT_REGION` default to `astana-evaluation` / `us-central1`; override them by exporting before invoking. CSV results land under `results/horizontal_experiment/<variant>/`.

## Scorers per variant

|  | gcloud | onemcp | toolbox_agent_skill | toolbox_cli_skill |
|---|:---:|:---:|:---:|:---:|
| `goal_completion` (judge) | ✓ | ✓ | ✓ | ✓ |
| `skills_trajectory` | — | ✓ | ✓ | ✓ |
| `turn_count`, `end_to_end_latency`, `tool_call_latency`, `token_consumption` | ✓ | ✓ | ✓ | ✓ |

`skills_trajectory` needs named skills / tools to compare against — it doesn't apply to bare Claude Code + Bash.

## Caveats

- **Trajectory shape differs by variant.** The shared `dataset.json` lists bare tool names in `expected_trajectory` (`list_instances`, `get_instance`, ...). Only variants that surface those names as discrete tool calls (`onemcp`, `toolbox_agent_skill`'s MCP-style invocations) will match cleanly. `toolbox_cli_skill` wraps every call in `run_shell_command(toolbox ... invoke <tool>)`; `gcloud` doesn't produce them at all. Inspect the first run's actual trajectory before reading too much into trajectory scores.
- **Cold-start token cost.** `run.sh` exports `ENABLE_TOOL_SEARCH=true` for every variant so Claude Code lazy-loads tool definitions instead of preloading them. Without it, attaching the `onemcp` MCP server would add ~21K cache-creation tokens per session on Vertex (`datasets/startup-ping/FINDINGS.md`), and skill-loading variants would pay a similar one-time hit. `run.sh` also wipes `.venv/fake_home_claude` before every variant — without that wipe, run N reuses run N-1's prompt cache and the residual cold-start cost vanishes from `token_consumption` entirely.
- **Hardcoded skill paths.** Both `toolbox_*/claude_code_model.yaml` files hardcode `/Users/whaoyu/git/evalbench/horizontal_experiment/_skills/<branch>` as the `skills_dir`. Update those if you relocate this directory.
- **Branch pinning is by re-clone.** `run.sh` does a shallow `--branch <name>` clone; rerunning `git fetch / reset --hard`s to keep both clones at the tip of their branches.
- **Auth files.** Claude Code copies `~/.claude/.credentials.json` into its sandboxed home but ignores `settings.json` / `CLAUDE.md` so the developer's local setup can't leak into a run.
