#!/usr/bin/env bash
# start-bouncers.sh — Start requested iam-jit Bounce-suite bouncers,
# export env vars to $GITHUB_ENV + $GITHUB_OUTPUT.
#
# Called by iam-jit-action step 7. Receives configuration via env vars:
#   IAM_JIT_BOUNCERS        — comma-separated bouncer list (or "none")
#   IAM_JIT_MODE            — discovery | cooperative | strict (iam-jit-level)
#   IAM_JIT_AUDIT_LOG_INPUT — explicit audit log path (or empty -> default)
#   RUNNER_TEMP             — GitHub Actions runner temp dir
#
# Per [[ibounce-honest-positioning]]: fail LOUD (non-zero + ::error::)
# if ibounce is in the list but fails to start. For Go bouncers not
# on PATH, emit ::warning:: and continue — only ibounce is load-bearing.

set -euo pipefail

BOUNCERS="${IAM_JIT_BOUNCERS:-ibounce}"
IAM_JIT_MODE_INPUT="${IAM_JIT_MODE:-cooperative}"
LOG_INPUT="${IAM_JIT_AUDIT_LOG_INPUT:-}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

# Translate iam-jit-level mode names to ibounce's native mode names.
# ibounce run accepts: cooperative | transparent | plan-capture
# iam-jit-action inputs accept: discovery | cooperative | strict
translate_ibounce_mode() {
  case "$1" in
    discovery)              echo "cooperative"  ;;  # observe + log, no deny
    cooperative)            echo "cooperative"  ;;  # same name in ibounce
    strict)                 echo "transparent"  ;;  # enforcement (403 on deny)
    transparent|plan-capture) echo "$1"         ;;  # pass through native names
    *)                      echo "cooperative"  ;;  # safe default
  esac
}

IBOUNCE_MODE="$(translate_ibounce_mode "$IAM_JIT_MODE_INPUT")"
GO_BOUNCER_MODE="$IBOUNCE_MODE"  # kbouncer/dbounce/gbounce use same names

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

echo "Bounce-suite start: bouncers=$BOUNCERS mode_input=$IAM_JIT_MODE_INPUT ibounce_mode=$IBOUNCE_MODE"
echo "  audit_log=$AUDIT_LOG"

if [ "$BOUNCERS" = "none" ]; then
  echo "Bouncer start skipped (bouncers=none)."
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

# ── ibounce (Python entry-point shipped inside iam-jit pip package) ───────────
start_ibounce() {
  if ! command -v ibounce &>/dev/null; then
    echo "::error::ibounce binary not found on PATH after install. " \
         "The iam-jit pip package ships ibounce as an entry-point — " \
         "check that pip install succeeded and pip's scripts dir is on PATH."
    exit 1
  fi

  local log="${RUNNER_TEMP}/ibounce.log"
  echo "Starting ibounce on :${IBOUNCE_PORT} (mode=${IBOUNCE_MODE}) ..."
  # ibounce run flags:
  #   --port              TCP port (loopback only)
  #   --mode              cooperative | transparent | plan-capture
  #   --audit-log-path    JSONL destination (one JSON object per decision)
  ibounce run \
    --port "${IBOUNCE_PORT}" \
    --mode "${IBOUNCE_MODE}" \
    --audit-log-path "${AUDIT_LOG}" \
    >"${log}" 2>&1 &
  echo "  ibounce PID=$! log=${log}"
}

# ── kbouncer (Go binary via go install) ───────────────────────────────────────
start_kbouncer() {
  if ! command -v kbouncer &>/dev/null; then
    echo "::warning::kbouncer not found on PATH; skipping. " \
         "go install may have failed for github.com/trsreagan3/kbouncer."
    return 0
  fi
  local log="${RUNNER_TEMP}/kbouncer.log"
  echo "Starting kbouncer on :${KBOUNCER_PORT} (mode=${GO_BOUNCER_MODE}) ..."
  kbouncer run \
    --port "${KBOUNCER_PORT}" \
    --mode "${GO_BOUNCER_MODE}" \
    --audit-log "${AUDIT_LOG}" \
    >"${log}" 2>&1 &
  echo "  kbouncer PID=$! log=${log}"
}

# ── dbounce (Go binary via go install) ────────────────────────────────────────
start_dbounce() {
  if ! command -v dbounce &>/dev/null; then
    echo "::warning::dbounce not found on PATH; skipping. " \
         "go install may have failed for github.com/trsreagan3/dbounce."
    return 0
  fi
  local log="${RUNNER_TEMP}/dbounce.log"
  echo "Starting dbounce mgmt on :${DBOUNCE_PORT} (mode=${GO_BOUNCER_MODE}) ..."
  dbounce run \
    --mgmt-port "${DBOUNCE_PORT}" \
    --mode "${GO_BOUNCER_MODE}" \
    --audit-log "${AUDIT_LOG}" \
    >"${log}" 2>&1 &
  echo "  dbounce PID=$! log=${log}"
}

# ── gbounce (Go binary via go install) ────────────────────────────────────────
start_gbounce() {
  if ! command -v gbounce &>/dev/null; then
    echo "::warning::gbounce not found on PATH; skipping. " \
         "go install may have failed for github.com/trsreagan3/gbounce."
    return 0
  fi
  local log="${RUNNER_TEMP}/gbounce.log"
  echo "Starting gbounce on :${GBOUNCE_PROXY_PORT} mgmt :${GBOUNCE_PORT} (mode=${GO_BOUNCER_MODE}) ..."
  gbounce run \
    --port "${GBOUNCE_PROXY_PORT}" \
    --mgmt-port "${GBOUNCE_PORT}" \
    --mode "${GO_BOUNCER_MODE}" \
    --audit-log "${AUDIT_LOG}" \
    --allow-connect \
    >"${log}" 2>&1 &
  echo "  gbounce PID=$! log=${log}"
}

# ── Start requested bouncers ──────────────────────────────────────────────────
ibounce_started=false
for bouncer in "${BOUNCER_LIST[@]}"; do
  bouncer="$(echo "$bouncer" | tr -d ' ')"
  case "$bouncer" in
    ibounce)   start_ibounce;  ibounce_started=true ;;
    kbouncer)  start_kbouncer ;;
    dbounce)   start_dbounce  ;;
    gbounce)   start_gbounce  ;;
    *)
      echo "::warning::Unknown bouncer '$bouncer' in bouncers list. " \
           "Valid: ibounce, kbouncer, dbounce, gbounce. Skipping."
      ;;
  esac
done

# ── Wait for ibounce to be healthy ────────────────────────────────────────────
decisions_baseline=0
if $ibounce_started; then
  max_wait=30
  waited=0
  while [ $waited -lt $max_wait ]; do
    if curl -sf "http://127.0.0.1:${IBOUNCE_PORT}/healthz" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if [ $waited -ge $max_wait ]; then
    echo "::error::ibounce did not respond on :${IBOUNCE_PORT} within ${max_wait}s. " \
         "Install FAILED — not protecting CI traffic."
    echo "ibounce log:"
    cat "${RUNNER_TEMP}/ibounce.log" 2>/dev/null || echo "(log not found)"
    exit 1
  fi

  echo "ibounce healthy on :${IBOUNCE_PORT} (waited ${waited}s)."

  # Capture baseline decisions_count before any agent traffic.
  decisions_baseline="$(
    curl -sf "http://127.0.0.1:${IBOUNCE_PORT}/healthz" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('decisions_count',0))" \
    2>/dev/null || echo 0
  )"
  echo "decisions_count baseline: ${decisions_baseline}"
fi

# ── Export env vars to $GITHUB_ENV for subsequent steps ──────────────────────
{
  echo "IAM_JIT_AUDIT_LOG=${AUDIT_LOG}"
  echo "IBOUNCE_PORT=${IBOUNCE_PORT}"
  echo "KBOUNCER_PORT=${KBOUNCER_PORT}"
  echo "DBOUNCE_PORT=${DBOUNCE_PORT}"
  echo "GBOUNCE_PORT=${GBOUNCE_PORT}"
  echo "GBOUNCE_PROXY_PORT=${GBOUNCE_PROXY_PORT}"
} >> "$GITHUB_ENV"

# AWS SDK/CLI endpoint: routes every boto3 / aws CLI call through ibounce.
if $ibounce_started; then
  echo "AWS_ENDPOINT_URL=http://127.0.0.1:${IBOUNCE_PORT}" >> "$GITHUB_ENV"
fi

# HTTPS proxy: routes generic HTTPS through gbounce (when enabled + on PATH).
if echo "$BOUNCERS" | grep -qw "gbounce" && command -v gbounce &>/dev/null; then
  echo "HTTPS_PROXY=http://127.0.0.1:${GBOUNCE_PROXY_PORT}" >> "$GITHUB_ENV"
  echo "https_proxy=http://127.0.0.1:${GBOUNCE_PROXY_PORT}" >> "$GITHUB_ENV"
fi

# ── Write action outputs ──────────────────────────────────────────────────────
{
  echo "bouncer_port=${IBOUNCE_PORT}"
  echo "audit_log_path=${AUDIT_LOG}"
  echo "decisions_count_baseline=${decisions_baseline}"
} >> "$GITHUB_OUTPUT"

echo ""
echo "Bounce-suite start complete."
echo "  AWS_ENDPOINT_URL=http://127.0.0.1:${IBOUNCE_PORT}"
echo "  IAM_JIT_AUDIT_LOG=${AUDIT_LOG}"
echo "  decisions_count baseline=${decisions_baseline}"
