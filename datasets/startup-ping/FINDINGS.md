# Startup token consumption: Claude Code vs Gemini CLI, ± cloud-sql MCP

**TL;DR.** Claude Code preloads all tool schemas into the prompt by default on Vertex AI, costing ~58K tokens per cold start with cloud-sql MCP attached. Gemini CLI lazy-loads tools and pays ~18K regardless of MCP. Setting `ENABLE_TOOL_SEARCH=true` cuts Claude's cold start by ~60% (to ~24K) and 1.4 s of latency.

## Numbers

Single-turn `Respond with exactly the single word: pong` prompt. Run on Vertex AI: `claude-opus-4-8` (region `global`), `gemini-2.5-pro` (`us-central1`). Average of 3 cold runs each except where noted.

| Harness     | MCP        | Tool Search | Cold-start tokens¹     | Latency  | Cost/cold² |
|-------------|------------|-------------|------------------------|----------|-----------|
| Claude Code | none       | default-off | 36,955                 | 4.2 s    | $0.139    |
| Claude Code | cloud-sql  | default-off | **58,487** (+58%)      | 3.3 s    | $0.219    |
| Claude Code | cloud-sql  | **ON**      | **23,894** (−59% vs ↑) | **1.9 s**| $0.090    |
| Gemini CLI  | none       | (lazy)      | 18,450                 | 2.7 s    | —         |
| Gemini CLI  | cloud-sql  | (lazy)      | 18,450 (≈0%)           | 2.9 s    | —         |

¹ Claude: `cache_creation_input_tokens` (the real first-turn prompt cost; the standard `total` field excludes it and undercounts by ~10,000×). Gemini: `input` tokens.
² Cache_creation billed at 1.25× input rate.

## Findings

1. **Claude Code preloads tools eagerly on Vertex AI.** Cloud-sql MCP adds 21,532 tokens of one-time cache_creation cost (~$0.08/cold start) baked into every fresh session.
2. **Gemini CLI lazy-loads tools.** Attaching cloud-sql MCP adds ~0 tokens at startup. The model only fetches MCP schemas if it decides to use them.
3. **Tool Search closes the gap, but is off-by-default on Vertex.** `ENABLE_TOOL_SEARCH=true` makes Claude Code behave like Gemini — withholds *all* tools (native + MCP), shrinks cold start to 23.9K and drops latency by 1.4 s. The Vertex default is `unset`, which falls back to OFF; first-party API default is ON.
4. **The default token_consumption scorer is misleading for cold-start measurements.** It sums `tokens.total`, which for Claude excludes `cache_creation_input_tokens`. The CSV reports 6 tokens for runs that actually moved ~58K. Read `stats.models.*.tokens.cache_creation` for the truth.
5. **First-ever run noise.** First Gemini invocation in a fresh session reported 28,832 tokens (vs 18,397 steady state) — likely first-time npm/auth setup. Discard the first run when measuring.

## Recommendation

If you're using Claude Code with MCP servers on Vertex AI, **set `ENABLE_TOOL_SEARCH=true`** unless you have <10 tools and care about avoiding the one extra round-trip on first tool use. The cold-start savings (~$0.13 + 1.4 s per session) compound across every fresh user session.

## Reproduce

```bash
EVAL_GCP_PROJECT_ID=astana-evaluation EVAL_GCP_PROJECT_REGION=us-central1 \
  EVAL_CONFIG=datasets/startup-ping/run_<variant>.yaml ./evalbench/run.sh
```

Variants: `run_claude_nomcp.yaml`, `run_claude_mcp.yaml`, `run_claude_mcp_toolsearch.yaml`, `run_gemini_nomcp.yaml`, `run_gemini_mcp.yaml`. Per-run JSON stats land in `results/startup-ping/<variant>/<uuid>/evals.csv`.

## Caveats

- N=3 per cell; cold-start tokens were rock-stable (±0.2%) so the signal is real, but quote the 95% CI if pasting into a deck.
- Vertex routes `gemini-2.5-pro` to `auto-gemini-2.5`; the underlying variant could shift. Result was reproducible across our runs.
- Numbers reflect `@anthropic-ai/claude-code@2.1.145` and `@google/gemini-cli@0.25.1`. Different CLI versions ship different system prompts.
- Caching leaks across sequential invocations in the same session (we observed run 2 of ToolSearch hit a 20,741-token cache from run 1). Treat cold-start = `cached == 0`.
