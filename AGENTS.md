# AGENTS.md

## Project overview
- Home Assistant add-on that installs and runs a GitHub Actions self-hosted runner.
- Entrypoint logic lives in `run.sh`; container build is in `Dockerfile`.

## Key files
- `run.sh`: downloads, verifies (when available), configures, and runs the Actions runner.
- `Dockerfile`: base image selection and OS dependencies.
- `config.yaml` / `repository.yaml`: Home Assistant add-on metadata.

## Conventions
- Keep scripts POSIX-ish sh compatible; avoid bash-only features unless already used.
- Prefer clear, explicit logging (`[INFO]`, `[WARN]`, `[ERROR]`) to match existing output.
- Default to ASCII in edits; avoid changing pinned versions unless requested.

## Testing
- No automated tests. Validate changes by building the add-on and running the container in Home Assistant.

## Safety notes
- Do not log secrets (`github_token`, registration tokens).
- If adding downloads, verify checksums or document why verification is not possible.
