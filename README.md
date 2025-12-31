# GitHub Actions Runner Home Assistant Add-on

Runs a GitHub self-hosted runner inside Home Assistant Supervisor by downloading the official `actions/runner` tarball pinned to a version.

## Installation
1. Add this repository to Home Assistant: **Settings → Add-ons → Add-on Store → ⋮ → Repositories → Add** and enter `https://github.com/dan-simms1/GitHub-Actions-Runner`. (Alternatively, copy this repo into `/addon_local/github-actions-runner`.)
2. Open the **GitHub Actions Runner** add-on and press **Install**.
3. Configure the options (at minimum `repo_url` and `github_token`), save, then start the add-on.

## Options
- `repo_url` (required): GitHub repository URL to register the runner with.
- `runner_name` (default `ha-runner-1`): Name reported to GitHub.
- `runner_labels` (default `["ha","self-hosted"]`): Runner labels; comma-joined when registering.
- `github_token` (required, secret): Either (a) the one-time registration token from **GitHub → repo → Settings → Actions → Runners → New self-hosted runner** (or org runners: **Organization settings → Actions → Runners → New self-hosted runner**), or (b) a PAT with `repo` + `workflow` scope (org runners: `admin:org`). Prefer short-lived registration tokens when possible.
- `ephemeral` (default `true`): Register as ephemeral so the runner auto-removes after each job.
- `workdir` (default `/data/_work`): Working directory for jobs.
- `cleanup_on_stop` (default `true`): Deregister the runner on stop/termination.
- `log_level` (default `info`): `debug`, `info`, `warn`, or `error`.
- `runner_version` (optional): Specific Actions runner version; defaults to a pinned version in `run.sh`.

## Behavior
- Uses Home Assistant base images per architecture (`aarch64`, `armv7`, `amd64`, `i386`).
- Downloads the official GitHub Actions runner tarball for the detected arch at startup, verifies checksum when available, and caches it.
- Configures the runner with the provided options, registers as ephemeral when enabled, and starts the runner service. SIGINT/SIGTERM triggers deregistration when `cleanup_on_stop` is `true`.
- Healthcheck watches for the runner process.
- i386 images fall back to the x64 runner tarball; pure 32-bit hosts may not be supported upstream.

## Security Notes
- Do **not** expose SSH; the container is outbound-only. Restrict any SSH access to LAN/VPN if you must enable it.
- Scope PATs narrowly; consider using a short-lived repo registration token from the GitHub API instead of a long-lived PAT.
- Pin `runner_version` to avoid surprise upstream changes; update intentionally when ready.
