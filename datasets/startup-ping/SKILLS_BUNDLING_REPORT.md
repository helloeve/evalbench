# Don't bundle every plugin's skills into a single mega-plugin

**TL;DR.** Merging skills from across many plugins into one combined plugin sounds tidy, but it makes every user's first turn pay for skills they'll never use. Either you pay for the descriptions and inflate the prompt by **~7,800 tokens** (~$0.03/cold-start at Opus rates), or you let Claude trim them and the model loses the ability to reliably pick the right skill. Plugin boundaries are a better fit for what users actually install.

## What this is about

There's a proposal to consolidate skills currently scattered across multiple plugins (`alloydb`, `cloud-sql-postgresql`, `bigquery-data-analytics`, `dataform-bigquery`, etc.) into a single bundled plugin that users would install once. The argument is convenience: one install, all skills available.

The measurements below — taken on Claude Code (`claude-opus-4-8`, Vertex) with a `ping → pong` prompt and the cloud-sql MCP server *not* attached — show why this is the wrong default.

## Point 1: Bundling adds real upfront token cost

I built a synthetic plugin (`data-agent-kit-all-skills`) that bundles all **67 skills** from data-agent-kit's plugins into a single installable plugin, and measured the cold-start system-prompt size on a trivial `ping → pong` request:

| Configuration                            | First-turn prompt size |
|------------------------------------------|------------------------|
| No plugin installed (baseline)           | 22,304 tokens          |
| 67-skill bundled plugin installed        | **30,116 tokens**      |
| **Difference**                           | **+7,812 tokens (+35%)** |

Every cold session pays this cost, regardless of whether the user ever invokes a skill. At Opus pricing (cache-creation rate) that's roughly **$0.03 extra per fresh session**, before the user has done anything.

This is the upper bound — see Point 2 for what happens if you don't pay it.

## Point 2: The "free" alternative breaks skill selection

The +7,812-token number above is from a configuration where every skill's full SKILL.md description is loaded into the prompt — the model sees both the name and what each skill does, so it can pick the right one. The numeric configuration that produced it was `skillListingBudgetFraction: 1.0`.

If you don't set that explicitly, Claude Code applies its **default budget** for plugin-marketplace skills: it registers the names but **silently drops the descriptions** to keep the prompt small. The cost shrinks dramatically:

| Configuration                                | First-turn prompt size | Δ vs baseline |
|----------------------------------------------|------------------------|---------------|
| No plugin installed                          | 22,304 tokens          | —             |
| 67-skill bundled plugin, **names only**      | 23,959 tokens          | **+1,655**    |
| 67-skill bundled plugin, **full descriptions** | 30,116 tokens          | +7,812        |

But "names only" is not actually free — it's a hidden quality regression. We verified this by asking the model directly:

> *"the `data-agent-kit-all-skills:*` skills are listed by **name only** — no description text accompanies them."*

That means the model is choosing between 67 cryptic identifiers like `cloud-sql-postgres-vectorassist`, `alloydb-omni-replication`, `gcp-pipeline-resource-provisioning` — with no information about what each does, when to use it, or how they differ. The model has to guess from the name alone, or perform an extra `Skill`-tool round-trip to read each candidate's description before deciding.

For 5–10 skills with self-explanatory names this is fine. For a 67-skill mega-plugin where the names overlap (six `alloydb-omni-*` skills, eight `cloud-sql-postgres-*` skills, fifteen `*-data` skills across products), the model can't reliably distinguish them without the descriptions — leading to wrong-skill invocations, slower task completion, and user frustration.

## The bind

The two settings give you a forced choice that neither setting wins:

- **Full descriptions** → +35% prompt overhead on every fresh session, paid by every user even when they only ever touch 1–2 skills.
- **Default budget** → token-efficient but the model is flying blind, and picks the wrong skill or has to discover descriptions one at a time.

Neither is a good default for a 67-skill bundle. They're both fine for a 5–10-skill plugin.

## Recommendation

Keep skills inside their natural plugin boundaries (`alloydb`, `cloud-sql-postgresql`, `bigquery-data-analytics`, etc.). A user who only works with BigQuery installs the BigQuery plugin and pays for ~3 skills, not 67. A user who works across the stack composes the plugins they actually use.

The convenience win of "one install" is real but small — and it's paid for by every fresh session of every user, forever. The token cost compounds; the convenience doesn't.

If the goal is discoverability ("how do I install the right plugins?"), the answer is a starter pack / curated marketplace listing, not a mega-plugin. Discovery is a UX problem at install time, not a context-window problem at every cold start.

---

*Numbers: Claude Code 2.1.145, `claude-opus-4-8`, Vertex AI (`us-central1`). `ping → pong` single-turn prompt. Cold-start `cache_creation_input_tokens`. Average of 3 runs per cell; cell-to-cell variance < 1%. Skill bundle: all 67 SKILL.md files under [github.com/GoogleCloudPlatform/data-agent-kit/plugins/*/skills/](https://github.com/GoogleCloudPlatform/data-agent-kit).*
