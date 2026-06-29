#!/usr/bin/env bash
# End-to-end orchestrator for the horizontal_experiment.
#
# Does two jobs in one script:
#   1) Skill setup. Clones the helloeve/cloud-sql-postgresql `main` and
#      `toolbox-cli` branches into _skills/<branch>/ and drops a
#      .claude-plugin/marketplace.json into each clone so Claude Code can
#      auto-register them as local plugin marketplaces. Re-run safe.
#   2) Eval runs. For each requested variant: wipe Claude Code's fake
#      home (so cached MCP responses / plugin marketplaces / session
#      history from a prior variant don't shrink the next run's
#      cache_creation_input_tokens to ~0), then invoke evalbench via
#      ./evalbench/run.sh.
#
# Usage (from the evalbench repo root):
#   horizontal_experiment/run.sh                # all four variants
#   horizontal_experiment/run.sh gcloud         # one variant
#   horizontal_experiment/run.sh onemcp toolbox_cli_skill   # any subset
#
# Required env (export before invoking):
#   CLOUD_SQL_POSTGRES_PROJECT, _REGION, _INSTANCE, _DATABASE, _USER,
#   _PASSWORD, _IP_TYPE   -- inherited by Claude Code from the shell
# Optional env (defaults shown):
#   EVAL_GCP_PROJECT_ID=astana-evaluation
#   EVAL_GCP_PROJECT_REGION=us-central1

set -euo pipefail

ALL_VARIANTS=(gcloud onemcp toolbox_agent_skill toolbox_cli_skill)
SKILL_VARIANTS=(toolbox_agent_skill toolbox_cli_skill)

REPO_URL="https://github.com/helloeve/cloud-sql-postgresql.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${SCRIPT_DIR}/_skills"
FAKE_HOME="${REPO_ROOT}/.venv/fake_home_claude"

EVAL_GCP_PROJECT_ID="${EVAL_GCP_PROJECT_ID:-astana-evaluation}"
EVAL_GCP_PROJECT_REGION="${EVAL_GCP_PROJECT_REGION:-us-central1}"

# Tool Search ON for every variant. Off-by-default on Vertex; with it on,
# Claude Code lazy-loads tool definitions instead of preloading them into
# the system prompt, which keeps cold-start token_consumption comparable
# across variants regardless of how many tools each one ships. (See
# datasets/startup-ping/FINDINGS.md.)
export ENABLE_TOOL_SEARCH="${ENABLE_TOOL_SEARCH:-false}"

# Prompt caching OFF for every variant. With caching on, the same
# conversation can spread tokens across `cache_creation` (cache writes)
# and `cached` (cache hits) in run-to-run-varying proportions, making
# apples-to-apples comparison of "tokens processed by the model"
# unstable. Disabling caching collapses every turn to fresh
# `input + output` and produces a stable, deterministic count.
# Costs dollars more per run; that's the right trade for a research
# comparison.
export DISABLE_PROMPT_CACHING="${DISABLE_PROMPT_CACHING:-0}"

# CLOUD_SQL_POSTGRES_* are intentionally NOT listed under env: in any
# variant's claude_code_model.yaml -- the generator inherits the parent
# shell's environment, so exporting here propagates to Claude Code, the
# helloeve per-domain skill scripts, and the toolbox CLI alike. Override
# any of these from your shell before invoking run.sh.
export CLOUD_SQL_POSTGRES_PROJECT="${CLOUD_SQL_POSTGRES_PROJECT:-whaoyu-playground}"
export CLOUD_SQL_POSTGRES_REGION="${CLOUD_SQL_POSTGRES_REGION:-us-central1}"
export CLOUD_SQL_POSTGRES_INSTANCE="${CLOUD_SQL_POSTGRES_INSTANCE:-whaoyupg}"
export CLOUD_SQL_POSTGRES_DATABASE="${CLOUD_SQL_POSTGRES_DATABASE:-financial}"
export CLOUD_SQL_POSTGRES_IP_TYPE="${CLOUD_SQL_POSTGRES_IP_TYPE:-PUBLIC}"

############################################################
# Arg parsing
############################################################
if [[ $# -eq 0 ]]; then
  variants=("${ALL_VARIANTS[@]}")
else
  variants=("$@")
fi

variant_needs_skills() {
  local v="$1"
  for s in "${SKILL_VARIANTS[@]}"; do
    [[ "$s" == "$v" ]] && return 0
  done
  return 1
}

for v in "${variants[@]}"; do
  if [[ ! -f "${SCRIPT_DIR}/${v}/run_config.yaml" ]]; then
    echo "Unknown variant: ${v}" >&2
    echo "  available: ${ALL_VARIANTS[*]}" >&2
    exit 2
  fi
done

############################################################
# Skill setup (idempotent; only if any selected variant needs skills)
############################################################
clone_or_pull() {
  local branch="$1"
  local dest="${SKILLS_DIR}/${branch}"
  if [[ -d "${dest}/.git" ]]; then
    echo "Updating ${branch} at ${dest}"
    git -C "${dest}" fetch --depth 1 origin "${branch}"
    git -C "${dest}" reset --hard "origin/${branch}"
  else
    echo "Cloning ${branch} into ${dest}"
    git clone --depth 1 --branch "${branch}" "${REPO_URL}" "${dest}"
  fi
}

write_marketplace_manifest() {
  local branch="$1"
  local plugin_name="$2"
  local description="$3"
  local dest="${SKILLS_DIR}/${branch}/.claude-plugin"
  mkdir -p "${dest}"
  cat > "${dest}/marketplace.json" <<JSON
{
  "name": "cloud-sql-postgresql-${branch}",
  "owner": {
    "name": "helloeve",
    "email": "ops@example.com"
  },
  "metadata": {
    "description": "${description}"
  },
  "plugins": [
    {
      "name": "${plugin_name}",
      "source": "./"
    }
  ]
}
JSON
  echo "Wrote ${dest}/marketplace.json"
}

needs_setup=0
for v in "${variants[@]}"; do
  if variant_needs_skills "$v"; then
    needs_setup=1
    break
  fi
done

if [[ "${needs_setup}" -eq 1 ]]; then
  mkdir -p "${SKILLS_DIR}"
  clone_or_pull main
  write_marketplace_manifest main \
    "cloud-sql-postgresql-agent-skill" \
    "Per-domain Cloud SQL Postgres skills (Node.js scripts)."
  clone_or_pull toolbox-cli
  write_marketplace_manifest toolbox-cli \
    "cloud-sql-postgresql-toolbox-cli-skill" \
    "Unified Cloud SQL Postgres skill driving MCP Toolbox CLI."
  echo
fi

############################################################
# Eval runs
############################################################
cd "${REPO_ROOT}"

for v in "${variants[@]}"; do
  echo "==> ${v}"
  if [[ -d "${FAKE_HOME}" ]]; then
    echo "Wiping ${FAKE_HOME}"
    rm -rf "${FAKE_HOME}"
  fi
  EVAL_GCP_PROJECT_ID="${EVAL_GCP_PROJECT_ID}" \
    EVAL_GCP_PROJECT_REGION="${EVAL_GCP_PROJECT_REGION}" \
    EVAL_CONFIG="horizontal_experiment/${v}/run_config.yaml" \
    ./evalbench/run.sh
  echo
done

echo "Done. Results under results/horizontal_experiment/<variant>/"
