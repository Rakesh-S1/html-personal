#!/usr/bin/env bash
# Runs the capstone Task List against the official solutions in the Udacity workspace and packs
# all evidence, the official brief template and the solution sources into one download:
#   /workspace/capstone_evidence.tar.gz
# Usage (in the Udacity terminal, with ANTHROPIC_API_KEY and ANTHROPIC_BASE_URL exported):
#   bash /workspace/collect_evidence.sh
set -u

# ===== PASTE YOUR VALUES HERE (keep the quotes), then save =====
HARDCODED_API_KEY="PASTE-YOUR-KEY-HERE"
HARDCODED_BASE_URL="https://claude.vocareum.com"
# ================================================================
if [ "$HARDCODED_API_KEY" != "PASTE-YOUR-KEY-HERE" ] && [ -n "$HARDCODED_API_KEY" ]; then
  export ANTHROPIC_API_KEY="$HARDCODED_API_KEY"
  export ANTHROPIC_BASE_URL="$HARDCODED_BASE_URL"
fi

WS=/workspace
OUT=$WS/capstone_evidence
rm -rf "$OUT"; mkdir -p "$OUT"/system1 "$OUT"/system2 "$OUT"/system3 "$OUT"/system4 "$OUT"/harness "$OUT"/sources

# Key lookup, first match wins (the key is never printed):
#   1. ANTHROPIC_API_KEY already set in this terminal
#   2. any other environment variable whose value is a voc-/sk-ant- key
#   3. ANTHROPIC_API_KEY=... in /workspace/.env, ~/.env, ~/.bashrc, ~/.profile, ~/.bash_profile
#   4. /workspace/key.txt (one line, just the key)
KEYFILE=$WS/key.txt
KEYSRC="terminal environment"
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  ANTHROPIC_API_KEY=$(env | sed -n 's/^[A-Za-z_][A-Za-z0-9_]*=\(\(voc-\|sk-ant-\)[A-Za-z0-9._-]*\)$/\1/p' | head -1)
  KEYSRC="another environment variable"
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  for f in "$WS/.env" "$HOME/.env" "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    [ -f "$f" ] || continue
    ANTHROPIC_API_KEY=$(sed -n 's/^\(export \)\{0,1\}ANTHROPIC_API_KEY=//p' "$f" | tail -1 | tr -d ' \r\n"'"'")
    if [ -n "$ANTHROPIC_API_KEY" ]; then KEYSRC="$f"; break; fi
  done
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -f "$KEYFILE" ]; then
  ANTHROPIC_API_KEY=$(tr -d ' \r\n"'"'" < "$KEYFILE"); KEYSRC="$KEYFILE"
fi
export ANTHROPIC_API_KEY
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://claude.vocareum.com}"
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "No API key found in the environment, .env, ~/.bashrc or $KEYFILE."
  echo "Open the Vocareum workspace (Cloud Resources tab), run: echo \$ANTHROPIC_API_KEY"
  echo "copy the key into $KEYFILE (one line) and run this script again."; exit 1
fi
echo "API key loaded from $KEYSRC (${#ANTHROPIC_API_KEY} characters), base URL: $ANTHROPIC_BASE_URL"
# Quick check that the key works before spending time on the runs.
python - <<'PY' || { echo "The API rejected this key. Re-copy it from the Vocareum workspace (echo \$ANTHROPIC_API_KEY)."; exit 1; }
import anthropic, sys
try:
    anthropic.Anthropic().models.list(limit=1)
    print("API key check: OK")
except anthropic.AuthenticationError as e:
    print("API key check FAILED:", type(e).__name__); sys.exit(1)
except anthropic.APIStatusError as e:
    if "key" in str(e).lower(): print("API key check FAILED:", e.status_code); sys.exit(1)
    print("API key check: inconclusive (", e.status_code, ") - continuing")
except Exception as e:
    print("API key check: inconclusive (", type(e).__name__, ") - continuing")
PY

find_dir() { find "$WS" -type d -path "*$1" -not -path "*/.venv/*" 2>/dev/null | head -1; }
S1=$(find_dir "03-dynamic-decomposition/solution")
S2=$(find_dir "04-assemble-and-locate/solution")
S3=$(find_dir "04-plan-mode-and-explore-decision-doc/solution")
S4=$(find_dir "04-fork-scratchpad/solution")
H=$(find "$WS" -maxdepth 1 -type d -name "Project-Harness*" | head -1)
printf 'S1=%s\nS2=%s\nS3=%s\nS4=%s\nHARNESS=%s\n' "$S1" "$S2" "$S3" "$S4" "$H" | tee "$OUT/paths.txt"
for d in "$S1" "$S2" "$S3" "$S4"; do
  if [ -z "$d" ]; then echo "Could not find one of the solution folders (see above). Send a screenshot."; exit 1; fi
done

# run <system-folder> <log-name> <title> <cmd...> : runs in the current dir, log gets a header + exit code
run() {
  local sys=$1 log=$2 title=$3; shift 3
  local f="$OUT/$sys/$log"
  { echo "# $title"; echo "# Path: $(pwd)"; echo "# Command: $*"; echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo; } > "$f"
  "$@" >> "$f" 2>&1; local rc=$?
  echo "" >> "$f"; echo "# exit code: $rc" >> "$f"
  echo "[$sys] $log -> exit $rc"
}

python -c "import sys; print(sys.version)" > "$OUT/python_version.txt"

# ---------- System 1: agentic loop (already run live; reuse that run, re-run tests only) ----------
cd "$S1" && {
  run system1 tests.log "System 1 - Agentic loop (claims_intake) - pytest" python -m pytest tests/ -v
  mkdir -p "$OUT/system1/runs"
  if [ -d runs/20261111_163300 ]; then cp -r runs/20261111_163300 "$OUT/system1/runs/"
  else run system1 run.log "System 1 - Agentic loop - run" python -m claims_intake.run --all
       cp -r "$(ls -td runs/*/ | head -1)" "$OUT/system1/runs/"; fi
}

# ---------- System 2: context strategy ----------
cd "$S2" && {
  run system2 tests_before_run.log "System 2 - Context strategy (retail_context) - pytest BEFORE run" python -m pytest tests/ -v
  run system2 run.log "System 2 - Context strategy - run" python -m retail_context.run --all
  mkdir -p "$OUT/system2/runs"; cp -r "$(ls -td runs/*/ | head -1)" "$OUT/system2/runs/"
  run system2 tests.log "System 2 - Context strategy (retail_context) - pytest AFTER run" python -m pytest tests/ -v
}

# ---------- System 3: Claude Code config ----------
cd "$S3" && {
  run system3 tests.log "System 3 - Claude Code config (ecommerce_team_config) - pytest" python -m pytest tests/ -v
  run system3 validator.log "System 3 - Claude Code config - validator" python -m ecommerce_team_config .
  { echo "# System 3 - .claude/ structure and CLAUDE.md files"; echo "# Path: $(pwd)"; echo
    find . -path ./.venv -prune -o \( -name "CLAUDE.md" -o -path "*/.claude/*" \) -type f -print | sort
    echo; echo "## Frontmatter / key lines"
    grep -rn --include=*.md -e "^paths:" -e "^globs:" -e "^context:" -e "^allowed-tools:" -e "^@" .claude CLAUDE.md 2>/dev/null
  } > "$OUT/system3/claude_structure.txt"
  mkdir -p "$OUT/system3/config_snapshot"
  cp -r .claude "$OUT/system3/config_snapshot/" 2>/dev/null; cp CLAUDE.md "$OUT/system3/config_snapshot/" 2>/dev/null
}

# ---------- System 4: orchestrator ----------
cd "$S4" && {
  run system4 tests.log "System 4 - Layer 3 orchestrator (shift_monitor) - pytest" python -m pytest tests/ -v
  if [ -f data/warm.sqlite ]; then echo "# warm tier already seeded; not re-seeding" > "$OUT/system4/seed_warm_tier.log"
  else run system4 seed_warm_tier.log "System 4 - seed warm tier" python -c "import json; from pathlib import Path; from shift_monitor.warm import WarmStore; w=WarmStore(Path('data/warm.sqlite')); w.initialize(); w.insert_many(json.load(open('fixtures/defects.json')))"; fi
  run system4 run_shift.log "System 4 - Layer 3 orchestrator - run-shift" python -m shift_monitor run-shift --shift C --warm-db data/warm.sqlite --since 2026-04-01T00:00:00Z --recorded-response fixtures/recorded_responses/shift_C_2026-04-30.json
  { echo "# System 4 - hot_state.json size after run"; echo "# Path: $(pwd)"; echo; wc -c data/hot_state.json; } > "$OUT/system4/hot_state_size.txt" 2>&1
  run system4 cli_help.log "System 4 - CLI help" python -m shift_monitor --help
  mkdir -p "$OUT/system4/data"
  find data -type f ! -name "*.sqlite*" -exec cp --parents {} "$OUT/system4/" \; 2>/dev/null
  find . -path ./.venv -prune -o -name "shift_scratchpad.jsonl" -type f -print -exec cp {} "$OUT/system4/" \;
}

# ---------- Official capstone materials + solution sources (for accurate file/function names) ----------
[ -n "$H" ] && cp -r "$H"/. "$OUT/harness/"
for pair in "system1:$S1" "system2:$S2" "system3:$S3" "system4:$S4"; do
  name=${pair%%:*}; dir=${pair#*:}
  (cd "$dir" && find . \( -path ./.venv -o -path ./runs -o -path ./data -o -name __pycache__ -o -name node_modules -o -name .pytest_cache \) -prune -o -type f \( -name "*.py" -o -name "*.md" -o -name "*.toml" -o -name "*.json" -o -name "*.tsx" -o -name "*.ts" \) -size -200k -print \
     | tar cf - -T - ) | (mkdir -p "$OUT/sources/$name" && cd "$OUT/sources/$name" && tar xf -)
done

cd "$WS" && tar czf "$WS/capstone_evidence.tar.gz" capstone_evidence
echo; echo "Done. Download: $WS/capstone_evidence.tar.gz ($(wc -c < "$WS/capstone_evidence.tar.gz") bytes)"
grep -h "passed\|failed" "$OUT"/system*/tests*.log | grep "==" ; grep -h "exit code" "$OUT"/system3/validator.log
