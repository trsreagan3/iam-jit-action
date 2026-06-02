# Changelog

## v1.0.0 (unreleased)

Initial release of `trsreagan3/iam-jit-action`.

### Features

- Composite action with 8-step pipeline: OS detect → Python/Go setup → pip install iam-jit → Go install bouncers → iam-jit init → start bouncers → export env → health verify
- Inputs: `version`, `bouncers`, `harness`, `mode`, `audit-log-path`
- Outputs: `bouncer-port`, `audit-log-path`, `decisions-count-baseline`
- Exports `AWS_ENDPOINT_URL`, `HTTPS_PROXY`, `IAM_JIT_AUDIT_LOG` to `$GITHUB_ENV`
- Fail-loud per [[ibounce-honest-positioning]]: non-zero exit + `::error::` on install failure
- Linux + macOS support; Windows documented as v1.1 gap

### Self-test workflow

- `self-test.yml` exercises ubuntu-latest + macos-latest
- Sends real `aws sts get-caller-identity` through ibounce (invalid creds, auth error expected)
- Asserts `decisions_count Δ > 0` after traffic per [[uat-tests-setup-end-to-end]]
