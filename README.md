# iam-jit-action

One-step GitHub Actions install of [iam-jit](https://github.com/trsreagan3/iam-roles)
plus the Bounce-suite bouncers (ibounce, kbouncer, dbounce, gbounce).

After this action runs:
- `AWS_ENDPOINT_URL` routes all AWS SDK/CLI calls through **ibounce** (audit + gate)
- `HTTPS_PROXY` routes generic HTTPS through **gbounce** (when enabled)
- An audit JSONL log accumulates every decision
- `decisions-count-baseline` output lets you assert bouncers audited real traffic

## Quick start

```yaml
# .github/workflows/agent-ci.yml
name: Agent CI with IAM JIT

on: [push, pull_request]

jobs:
  run-agent:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install iam-jit + wire bouncers
        id: iam-jit
        uses: trsreagan3/iam-jit-action@v1
        with:
          bouncers: 'ibounce'
          mode: 'cooperative'
          harness: 'none'

      - name: Run agent (all AWS calls audited by ibounce)
        env:
          # AWS_ENDPOINT_URL already exported by the action
          MY_AWS_REGION: us-east-1
        run: |
          python my_agent.py

      - name: Assert ibounce audited traffic
        run: |
          port="${{ steps.iam-jit.outputs.bouncer-port }}"
          baseline="${{ steps.iam-jit.outputs.decisions-count-baseline }}"
          after=$(curl -sf "http://127.0.0.1:${port}/healthz" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('decisions_count',0))")
          echo "decisions_count delta: $((after - baseline))"
          [ "$((after - baseline))" -gt 0 ] || exit 1
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | `latest` | iam-jit version to install via pip. Pin with `1.0.3`. |
| `bouncers` | `ibounce,kbouncer,dbounce,gbounce` | Comma-separated bouncer list. Set `none` to skip. |
| `harness` | `claude-code` | Agent harness: `claude-code`, `cursor`, `codex`, `none`. |
| `mode` | `cooperative` | Enforcement mode: `discovery`, `cooperative`, `strict`. |
| `audit-log-path` | `$RUNNER_TEMP/iam-jit-audit.jsonl` | Audit JSONL path. |

## Outputs

| Output | Description |
|---|---|
| `bouncer-port` | ibounce listen port (default 8767). |
| `audit-log-path` | Resolved audit log path (matches `$IAM_JIT_AUDIT_LOG`). |
| `decisions-count-baseline` | `decisions_count` at bouncer start. Compare post-run to prove traffic was audited. |

## Exported env vars

The action writes to `$GITHUB_ENV` so subsequent steps automatically inherit:

| Var | Value | Purpose |
|---|---|---|
| `AWS_ENDPOINT_URL` | `http://127.0.0.1:8767` | Routes AWS SDK/CLI through ibounce |
| `HTTPS_PROXY` | `http://127.0.0.1:8080` | Routes HTTPS through gbounce (when enabled) |
| `IAM_JIT_AUDIT_LOG` | `<audit-log-path>` | Path to the JSONL audit log |
| `IBOUNCE_PORT` | `8767` | ibounce management port |
| `GBOUNCE_PORT` | `8769` | gbounce management port |

## Modes

| Mode | Behavior |
|---|---|
| `discovery` | Observe + log only. No deny. Safe default for initial CI runs. |
| `cooperative` | Agent sees deny rationale; may retry with narrower scope. |
| `strict` | Maximalist deny + alert. No retry. |

Start with `discovery` to observe what your agent calls, then move to `cooperative`
or `strict` once you've reviewed the audit log.

## Proving traffic was audited

```yaml
- name: Assert decisions_count ticked
  run: |
    port="${{ steps.iam-jit.outputs.bouncer-port }}"
    baseline="${{ steps.iam-jit.outputs.decisions-count-baseline }}"
    after=$(curl -sf "http://127.0.0.1:${port}/healthz" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('decisions_count',0))")
    delta=$((after - baseline))
    echo "decisions_count Δ=$delta"
    [ "$delta" -gt 0 ] || { echo "::error::No traffic routed through ibounce"; exit 1; }
```

## Bouncer port reference

| Bouncer | Default port | Purpose |
|---|---|---|
| ibounce | 8767 | AWS API gating (primary) |
| kbouncer | 8766 | Kubernetes API gating |
| dbounce | 8768 | SQL query gating (mgmt port) |
| gbounce | 8769 (mgmt) / 8080 (proxy) | Generic HTTPS gating |

## Runner compatibility

| Runner | Support |
|---|---|
| `ubuntu-latest` | Supported |
| `ubuntu-22.04` | Supported |
| `macos-latest` | Supported |
| `windows-latest` | v1.1 (not yet — shell script dependency) |

## Requirements

The action internally depends on:
- `actions/setup-python@v5` (Python 3.12)
- `actions/setup-go@v5` (Go 1.22, for Go-backed bouncers)

Both are invoked automatically. Do not add them separately before this action
unless you need to pin different versions.

## Installing ibounce only (faster CI)

For most CI pipelines, only ibounce (AWS gating) is relevant:

```yaml
- uses: trsreagan3/iam-jit-action@v1
  with:
    bouncers: 'ibounce'
    mode: 'discovery'
    harness: 'none'
```

## Self-hosted runners

Works out of the box on Linux self-hosted runners with Python + Go available.
Set `IAM_JIT_DATA_DIR` to a writable path if `~/.iam-jit/` is not accessible:

```yaml
env:
  IAM_JIT_DATA_DIR: /tmp/iam-jit-ci
```

## Security

- No AWS credentials required by the action itself — it only routes traffic.
- Bouncers run on loopback (`127.0.0.1`) only.
- Audit logs are written to `$RUNNER_TEMP` (ephemeral runner storage).
- ibounce never caches credentials; it proxies + logs, then forwards.
