# horizontal_experiment — findings

Comparing four ways of giving **Claude Code** (`claude-opus-4-8` on Vertex,
region `global`) access to Cloud SQL, holding the dataset, judge, and
scorers constant. One single-turn scenario: *"List all Cloud SQL
instances in project astana-evaluation."*

Run configuration for the numbers below: **Tool Search OFF**
(`ENABLE_TOOL_SEARCH=false`), **prompt caching ON**
(`DISABLE_PROMPT_CACHING=0`). Fake home wiped before each variant
(`onemcp` uses the developer's real `~/.claude`, see below).

## Results

| Variant | tool path | token_consumption¹ | latency | turns | cost² | goal |
|---|---|---:|---:|---:|---:|:---:|
| **gcloud** | `Bash(gcloud sql instances list)` | 680 | 22.7 s | 1 | $0.31 | — |
| **onemcp** | `cloudsql__list_instances` (managed MCP) | 840 | 14.8 s | 1 | $0.51 | — |
| **toolbox_agent_skill** | `Skill → Bash(node …list_instances.js)` | 1,996 | 34.4 s | 1 | $0.11 | — |
| **toolbox_cli_skill** | `Skill → Bash(describe-tool) → Bash(invoke)` | 2,009 | 30.4 s | 1 | $0.25 | — |

¹ `token_consumption` = `tokens.total` (input + output only). With prompt
caching ON this **excludes** the cold-start cost that lands in
`cache_creation` / `cached` — so it reflects only the fresh per-turn
delta, not total tokens processed. See "Caveat: what this number means".

² `cost_usd` is Claude Code's self-reported `total_cost_usd`, which DOES
account for cache_creation (1.25×) and cache reads (~0.1×). Cost and the
token_consumption column therefore tell different stories on purpose.

## Latest run — Tool Search OFF, caching ON (2026-06-30)

Repeat of the same single-turn scenario, **Tool Search explicitly OFF**
(`ENABLE_TOOL_SEARCH=false`), prompt caching ON. All four variants
exercised their intended tooling surface — `onemcp` used the managed MCP
tool directly (not a gcloud fallback).

| Variant | tool path | token_consumption¹ | latency | turns | cost² |
|---|---|---:|---:|---:|---:|
| **gcloud** | `Bash(gcloud sql instances list)` | 729 | 17.0 s | 1 | $0.31 |
| **onemcp** | `cloudsql__list_instances` (managed MCP) | 7,136 | 63.1 s | 1 | $0.60 |
| **toolbox_agent_skill** | `Skill → Bash(node …list_instances.js)` | 1,815 | 31.9 s | 1 | $0.12 |
| **toolbox_cli_skill** | `Skill → Bash(describe-tool) → Bash(invoke)` | 1,981 | 29.3 s | 1 | $0.24 |

What changed vs the earlier table above (same config):

- **`onemcp` token_consumption jumped 840 → 7,136 and latency 14.8 s →
  63.1 s.** The managed MCP returned the full instance list (~120+) as
  structured JSON straight into the model's context; that tool output is
  counted as input on the synthesis turn, so the number scales with
  result-set size. This is real run-to-run variance specific to the MCP
  variant — the gcloud-table and skill paths get terser stdout and stay
  stable (~700–2,000). With Tool Search OFF the MCP tool schema is also
  preloaded rather than lazy-fetched, which is part of why onemcp is the
  most expensive ($0.60) and slowest.
- **gcloud and the two skill variants are stable** within noise across
  runs (gcloud ~680–729, toolbox_agent_skill ~1,815–1,996,
  toolbox_cli_skill ~1,981–2,009).

Footnotes ¹ and ² are the same as the Results section above.

## What each variant actually did

- **gcloud** — bare Claude Code, no MCP, no skills. Shelled out to
  `gcloud sql instances list` via Bash. Works because the host gcloud is
  authenticated; the agent never had a named `list_instances` tool, so
  `goal_completion` / `skills_trajectory` structurally can't match.
- **onemcp** — Claude Code + Google's managed
  `sqladmin.googleapis.com/mcp`. Called `cloudsql__list_instances`
  directly and returned real data (122 instances). Requires
  `use_real_home: true` (see below).
- **toolbox_agent_skill** — helloeve `main`. Routed through the
  `cloud-sql-postgres-admin` Skill, which ran a Node script via Bash.
- **toolbox_cli_skill** — helloeve `toolbox-cli`. The unified skill's
  documented workflow makes the agent run `describe-tool` then `invoke`
  through the toolbox CLI — three tool calls for one logical operation.

## Insights

1. **Tool count scales token_consumption.** The single-call variants
   (gcloud 680, onemcp 840) sit far below the skill variants (≈2,000),
   which each fan out into 2–3 tool calls. Each extra call re-enters the
   model with the prior turn's context, inflating fresh input+output.

2. **`onemcp` is the fastest** (14.8 s) — one direct MCP call, no Bash
   subprocess spin-up, no skill-doc parsing. But it's the most
   **expensive** ($0.51) because the MCP tool schema is loaded fresh into
   the prompt (Tool Search is OFF), and that bulk is billed as
   cache_creation.

3. **`toolbox_agent_skill` is the cheapest** ($0.11) despite processing
   ~3× the tokens of gcloud. Most of its tokens are cache reads (the big
   skill doc, cached after the first internal request) billed at ~0.1×.
   Caching rewards the load-once-reuse-often shape.

4. **`toolbox_cli_skill` pays for its three-call protocol.** Highest
   token_consumption and middling cost — the `describe-tool` round-trip
   is pure overhead for a caller that already knows it wants
   `list_instances`.

5. **token_consumption and cost rank differently, on purpose.** Tokens:
   gcloud < onemcp < toolbox_agent_skill < toolbox_cli_skill. Cost:
   toolbox_agent_skill < toolbox_cli_skill < gcloud < onemcp. The
   divergence is entirely a caching artifact — fresh tokens
   (cache_creation, billed 1.25×) cost ~12× a cache read. A variant can
   process many tokens cheaply if they're mostly reused.

## Caveat: what `token_consumption` means here

The `token_consumption` scorer sums `tokens.total` = input + output for
the turn. On Claude Code with prompt caching ON, the cold-start prompt
(system prompt + tool/skill schemas) is billed as `cache_creation` on
the first internal request and read back as `cached` on later requests —
**neither is in `tokens.total`.** So with caching ON, this column
under-reports the true tokens-processed by 10–100× and is best read as
"incremental per-turn work," not "total model load."

To measure total tokens processed deterministically, set
`DISABLE_PROMPT_CACHING=1` in `run.sh`: every turn collapses to fresh
`input + output`, `cache_creation`/`cached` go to zero, and
`tokens.total` becomes the real processed-token count. That run mode
costs more dollars but gives an apples-to-apples architecture
comparison. (For reference, in a prior DISABLE_PROMPT_CACHING=1 /
Tool-Search-ON run the processed-token totals were gcloud 53K,
toolbox_agent_skill 82K, onemcp 90K, toolbox_cli_skill 104K.)

## Operational notes

- **`onemcp` needs `use_real_home: true`.** The managed MCP endpoint
  authenticates via Claude Code's native OAuth, which persists a refresh
  token in the macOS keychain. Repointing `HOME` to a sandboxed fake
  home breaks keychain access ("a keychain cannot be found to store
  …"), so this variant runs against the developer's real `~/.claude`
  where the `cloud-sql` MCP server is pre-registered and already
  OAuth-authorized. Consequence: `onemcp` is **not hermetic** and can't
  run under the service-based (`eval_server.py`) deployment. Its OAuth
  token expires periodically; re-auth locally before rerunning.

- **Agent freely chooses gcloud over MCP.** With both Bash and the MCP
  tool available, the model sometimes prefers `gcloud`. To force the MCP
  path deterministically, restrict `allowed_tools` in the onemcp model
  config so Bash isn't an option.

- **Judge strictness.** `goal_completion` faults variants for (a)
  summarizing instead of enumerating all instance names, and (b) making
  "more than one" tool call when a Skill internally invokes Bash. These
  are rubric quirks, not tooling failures — read the tool trajectory,
  not just the pass/fail.

- **Bash result capture.** The claude_code generator records
  `tool_calls[].response = null` for Bash calls (stdout isn't captured
  into the trajectory), which has previously misled the judge into
  flagging real summaries as hallucinations. The model sees the output;
  the harness doesn't.

## Reproduce

```bash
# all four variants, wiping fake_home between each
bash horizontal_experiment/run.sh

# one variant
bash horizontal_experiment/run.sh onemcp
```

Toggle the run mode at the top of `horizontal_experiment/run.sh`:
`ENABLE_TOOL_SEARCH` (default false) and `DISABLE_PROMPT_CACHING`
(default 0). Results land under `results/horizontal_experiment/<variant>/`.
