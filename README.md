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
- `github_token` (optional for restarts, secret): Either a **registration token** from **GitHub → repo → Settings → Actions → Runners → New self-hosted runner**, or a **PAT** with access to manage runners. Registration tokens are short-lived and intended for one-time registration; PATs let the add-on request fresh registration/removal tokens on startup.
- `ephemeral` (default `false`): Register as ephemeral so the runner auto-removes after each job. Set to `true` if you want single-use runners.
- `workdir` (default `/data/_work`): Working directory for jobs.
- `cleanup_on_stop` (default `true`): Deregister the runner on stop/termination.
- `log_level` (default `info`): `debug`, `info`, `warn`, or `error`.
- `runner_version` (optional): Specific Actions runner version; defaults to `latest`.

## Behavior
- Uses Debian base image with necessary dependencies including OpenSSH client.
- Downloads the official GitHub Actions runner tarball for the detected arch at startup, verifies checksum when available, and caches it.
- **Initial Setup**: Requires `github_token` to register the runner. Use a registration token from **GitHub → Settings → Actions → Runners → New runner**, or a PAT to auto-request one.
- **Restarts**: After initial registration, the runner preserves its credentials and can restart without requiring a new token. Simply restart the add-on and it will reconnect automatically.
- **Re-registration**: If you need to re-register (e.g., after removing runner on GitHub), provide a PAT or a fresh registration token and the runner will re-register.
- **Token handling**: If a registration token is present but a valid local config already exists, the add-on will reuse the existing config instead of forcing re-registration.
- Configures the runner with the provided options. SIGINT/SIGTERM triggers deregistration when `cleanup_on_stop` is `true`.
- i386 images fall back to the x64 runner tarball; pure 32-bit hosts may not be supported upstream.

## Restart-Friendly Design
This add-on is designed to restart without requiring new tokens:
1. **First run**: Provide `github_token` to register
2. **Subsequent restarts**: Leave `github_token` empty to reconnect automatically, or provide a PAT to force re-registration
3. **Token expiry**: Registration tokens expire after 1 hour, but once registered, the runner maintains its own credentials

## Security Notes
- Do **not** expose SSH; the container is outbound-only. Restrict any SSH access to LAN/VPN if you must enable it.
- Scope PATs narrowly; prefer fine-grained PATs with the minimum permissions required to manage repo runners.
- Pin `runner_version` to avoid surprise upstream changes; update intentionally when ready.
