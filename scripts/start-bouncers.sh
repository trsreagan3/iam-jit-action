#!/usr/bin/env bash
# start-bouncers.sh — Start requested iam-jit Bounce-suite bouncers,
# export env vars to $GITHUB_ENV + $GITHUB_OUTPUT.
#
# Called by iam-jit-action step 7. Receives configuration via env vars:
#   IAM_JIT_BOUNCERS       — comma-separated bouncer list (or "none")
#   IAM_JIT_MODE           — discovery | cooperative | strict
#   IAM_JIT_AUDIT_LOG_INPUT — explicit audit log path (or empty → default)
#   RUNNER_TEMP            — GitHub Actions runner temp dir
#
# Per [[ibounce-honest-positioning]]: fail LOUD (non-zero + ::error::)
# if ibounce is in the list but fails to start. For Go bouncers that
# aren't on PATH, emit a ::warning:: and continue — only ibounce is
# load-bearing for AWS gating.

set -euo pipefail

BOUNCERS="${IAM_JIT_BOUNCERS:-ibounce}"
MODE="${IAM_JIT_MODE:-cooperative}"
LOG_INPUT="${IAM_JIT_AUDIT_LOG_INPUT:-}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

# Default port map — matches canonical iam-jit port assignments.
IBOUNCE_PORT="${IBOUNCE_PORT_OVERRIDE:-8767}"
KBOUNCER_PORT="${KBOUNCER_PORT_OVERRIDE:-8766}"
DBOUNCE_PORT="${DBOUNCE_PORT_OVERRIDE:-8768}"
GBOUNCE_PORT="${GBOUNCE_PORT_OVERRIDE:-8769}"
GBOUNCE_PROXY_PORT="${GBOUNCE_PROXY_PORT_OVERRIDE:-8080}"

# Audit log path.
if [ -n "$LOG_INPUT" ]; then
  AUDIT_LOG="$LOG_INPUT"
else
  AUDIT_LOG="${RUNNER_TEMP}/iam-jit-audit.jsonl"
fi
touch "$AUDIT_LOG"

echo "Bounce-suite start: bouncers=$BOUNCERS mode=$MODE audit_log=$AUDIT_LOG"

if [ "$BOUNCERS" = "none" ]; then
  echo "Bouncer start skipped (bouncers=none)."
  # Still export empty env defaults so downstream steps don't fail on unbound vars.
  {
    echo "IAM_JIT_AUDIT_LOG=${AUDIT_LOG}"
    echo "IBOUNCE_PORT=${IBOUNCE_PORT}"
  } >> "$GITHUB_ENV"
  {
    echo "bouncer_port=${IBOUNCE_PORT}"
    echo "audit_log_path=${AUDIT_LOG}"
    echo "decisions_count_baseline=0"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

IFS=',' read -ra BOUNCER_LIST <<< "$BOUNCERS"

# ── ibounce (Python / pip — in iam-jit package) ──────────────────────────────
start_ibounce() {
  if ! command -v ibounce &>/dev/null; then
    echo "::error::ibounce binary not found on PATH after install. " \
         "iam-jit pip install may have failed or the package does not ship " \
         "an ibounce entry-point yet. Check iam-jit version."
    exit 1
  fi

  local log="${RUNNER_TEMP}/ibounce.log"
  echo "Starting ibounce on :${IBOUNCE_PORT} (mode=${MODE}) ..."
  ibounce run \
    --port "${IBOUNCE_PORT}" \
    --mode "${MODE}" \
    --audit-log "${AUDIT_LOG}" \
    --no-prompt \
    >"${log}" 2>&1 &
  echo "  ibounce PID=$! log=${log}"
}

# ── kbouncer (Go) ─────────────────────────────────────────────────────────────
start_kbouncer() {
  if ! command -v kbouncer &>/dev/null; then
    echo "::warning::kbouncer not found on PATH; skipping."
    return 0
  fi
  local log="${RUNNER_TEMP}/kbouncer.log"
  echo "Starting kbouncer on :${KBOUNCER_PORT} (mode=${MODE}) ..."
  kbouncer run \
    --port "${KBOUNCER_PORT}" \
    --mode "${MODE}" \
    --audit-log "${AUDIT_LOG}" \
    --no-prompt \
    >"${log}" 2>&1 &
  echo "  kbouncer PID=$! log=${log}"
}

# ── dbounce (Go) ──────────────────────────────────────────────────────────────
start_dbounce() {
  if ! command -v dbounce &>/dev/null; then
    echo "::warning::dbounce not found on PATH; skipping."
    return 0
  fi
  local log="${RUNNER_TEMP}/dbounce.log"
  echo "Starting dbounce mgmt on :${DBOUNCE_PORT} (mode=${MODE}) ..."
  dbounce run \
    --mgmt-port "${DBOUNCE_PORT}" \
    --mode "${MODE}" \
    --audit-log "${AUDIT_LOG}" \
    --no-prompt \
    >"${log}" 2>&1 &
  echo "  dbounce PID=$! log=${log}"
}

# ── gbounce (Go) ──────────────────────────────────────────────────────────────
start_gbounce() {
  if ! command -v gbounce &>/dev/null; then
    echo "::warning::gbounce not found on PATH; skipping."
    return 0
  fi
  local log="${RUNNER_TEMP}/gbounce.log"
  echo "Starting gbounce on :${GBOUNCE_PROXY_PORT} mgmt :${GBOUNCE_PORT} (mode=${MODE}) ..."
  gbounce run \
    --port "${GBOUNCE_PROXY_PORT}" \
    --mgmt-port "${GBOUNCE_PORT}" \
    --mode "${MODE}" \
    --audit-log "${AUDIT_LOG}" \
    --allow-connect \
    --no-prompt \
    >"${log}" 2>&1 &
  echo "  gbounce PID=$! log=${log}"
}

# ── Start requested bouncers ─────────────────────────────────────────────────
ibounce_started=false
for bouncer in "${BOUNCER_LIST[@]}"; do
  bouncer="$(echo "$bouncer" | tr -d ' ')"
  case "$bouncer" in
    ibounce)   start_ibounce;  ibounce_started=true ;;
    kbouncer)  start_kbouncer ;;
    dbounce)   start_dbounce  ;;
    gbounce)   start_gbounce  ;;
    *)
      echo "::warning::Unknown bouncer '$bouncer' in bouncers list. Skipping."
      ;;
  esac
done

# ── Wait for ibounce to be ready (it's the primary gating bouncer) ───────────
decisions_baseline=0
if $ibounce_started; then
  max_wait=20
  waited=0
  while [ $waited -lt $max_wait ]; do
    if curl -sf "http://127.0.0.1:${IBOUNCE_PORT}/healthz" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if [ $waited -ge $max_wait ]; then
    echo "::error::ibounce did not come up within ${max_wait}s on :${IBOUNCE_PORT}. " \
         "Install is considered FAILED — not protecting CI traffic."
    cat "${RUNNER_TEMP}/ibounce.log" 2>/dev/null || true
    exit 1
  fi

  echo "ibounce healthy on :${IBOUNCE_PORT} (waited ${waited}s)."

  # Capture baseline decisions_count before any traffic.
  decisions_baseline="$(
    curl -sf "http://127.0.0.1:${IBOUNCE_PORT}/healthz" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('decisions_count',0))" \
    2>/dev/null || echo 0
  )"
  echo "decisions_count baseline: ${decisions_baseline}"
fi

# ── Export env vars for subsequent steps via $GITHUB_ENV ────────────────────
{
  echo "IAM_JIT_AUDIT_LOG=${AUDIT_LOG}"
  echo "IBOUNCE_PORT=${IBOUNCE_PORT}"
  echo "KBOUNCER_PORT=${KBOUNCER_PORT}"
  echo "DBOUNCE_PORT=${DBOUNCE_PORT}"
  echo "GBOUNCE_PORT=${GBOUNCE_PORT}"
  echo "GBOUNCE_PROXY_PORT=${GBOUNCE_PROXY_PORT}"
} >> "$GITHUB_ENV"

# AWS SDK/CLI endpoint URL — routes all AWS API calls through ibounce.
if $ibounce_started; then
  echo "AWS_ENDPOINT_URL=http://127.0.0.1:${IBOUNCE_PORT}" >> "$GITHUB_ENV"
fi

# HTTPS proxy — routes generic HTTPS through gbounce (if started).
if echo "$BOUNCERS" | grep -qw "gbounce" && command -v gbounce &>/dev/null; then
  echo "HTTPS_PROXY=http://127.0.0.1:${GBOUNCE_PROXY_PORT}" >> "$GITHUB_ENV"
  echo "https_proxy=http://127.0.0.1:${GBOUNCE_PROXY_PORT}" >> "$GITHUB_ENV"
fi

# ── Write outputs ─────────────────────────────────────────────────────────────
{
  echo "bouncer_port=${IBOUNCE_PORT}"
  echo "audit_log_path=${AUDIT_LOG}"
  echo "decisions_count_baseline=${decisions_baseline}"
} >> "$GITHUB_OUTPUT"

echo "Bounce-suite start complete."
echo "  AWS_ENDPOINT_URL=http://127.0.0.1:${IBOUNCE_PORT}"
echo "  IAM_JIT_AUDIT_LOG=${AUDIT_LOG}"
echo "  decisions_count baseline=${decisions_baseline}"
