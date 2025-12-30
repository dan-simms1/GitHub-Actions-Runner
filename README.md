# GitHub Actions Runner - Home Assistant Add-on

A Home Assistant add-on that runs a self-hosted GitHub Actions runner. This allows you to execute GitHub Actions workflows on your Home Assistant instance.

## About

This add-on enables you to run a GitHub Actions self-hosted runner directly within your Home Assistant environment. Self-hosted runners give you more control over the environment and can access local resources that cloud runners cannot.

## Features

- 🏃 Self-hosted GitHub Actions runner
- 🔄 Automatic runner registration and configuration
- 🏗️ Multi-architecture support (aarch64, armv7, amd64, i386)
- 🔒 Secure token management
- 🧹 Automatic cleanup on shutdown
- 🏷️ Custom runner labels support
- ⚡ Ephemeral runner mode
- 📝 Configurable logging levels

## Installation

1. Add this repository to your Home Assistant add-on store
2. Install the "GitHub Actions Runner" add-on
3. Configure the add-on with your repository details and GitHub token
4. Start the add-on

## Configuration

### Option: `repo_url` (required)

The full URL of your GitHub repository where you want to register the runner.

Example: `https://github.com/owner/repository`

### Option: `github_token` (required)

A GitHub Personal Access Token (PAT) with `repo` scope (for private repositories) or `public_repo` scope (for public repositories). The token needs permissions to manage self-hosted runners.

To create a token:
1. Go to GitHub Settings → Developer settings → Personal access tokens
2. Generate a new token with `repo` or `public_repo` scope
3. Copy the token and paste it in this field

### Option: `runner_name`

The name for your runner as it will appear in GitHub.

Default: `ha-runner`

### Option: `runner_labels`

Comma-separated list of custom labels for the runner. The runner will always have the `self-hosted` label.

Default: `self-hosted`

Example: `self-hosted,home-assistant,local`

### Option: `ephemeral`

When enabled, the runner will only handle one job and then exit. Useful for clean environments on each job.

Default: `false`

### Option: `workdir`

The working directory where the runner will execute jobs.

Default: `/data/work`

### Option: `cleanup_on_stop`

When enabled, the runner will be automatically unregistered from GitHub when the add-on stops.

Default: `true`

### Option: `log_level`

Controls the verbosity of log output.

Options: `debug`, `info`, `warning`, `error`

Default: `info`

### Option: `runner_version`

The version of the GitHub Actions runner to use. Use `latest` to automatically download the latest version.

Default: `latest`

Example: `2.311.0`

## Example Configuration

```yaml
repo_url: https://github.com/myusername/myrepo
github_token: ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
runner_name: homeassistant-runner
runner_labels: self-hosted,home-assistant,raspberry-pi
ephemeral: false
workdir: /data/work
cleanup_on_stop: true
log_level: info
runner_version: latest
```

## Usage

1. Configure the add-on with your repository URL and GitHub token
2. Start the add-on
3. The runner will automatically register with your repository
4. You can now use this runner in your GitHub Actions workflows by specifying:

```yaml
runs-on: self-hosted
```

Or with custom labels:

```yaml
runs-on: [self-hosted, home-assistant]
```

## How It Works

1. The add-on validates your configuration
2. Downloads the appropriate GitHub Actions runner for your architecture
3. Registers the runner with your GitHub repository using the provided token
4. Starts the runner to listen for jobs
5. On shutdown, optionally unregisters the runner from GitHub (if `cleanup_on_stop` is enabled)

## Security Considerations

- The GitHub token is stored securely and marked as a secret
- The runner operates as a non-root user
- All communication with GitHub is over HTTPS
- Be cautious about which repositories can use your runner
- Consider using ephemeral mode for untrusted workflows

## Troubleshooting

### Runner not appearing in GitHub

- Verify your `repo_url` is correct and in the format `https://github.com/owner/repo`
- Ensure your `github_token` has the correct permissions
- Check the add-on logs for error messages

### Runner disconnects frequently

- Check your network connectivity
- Verify Home Assistant system resources are sufficient
- Review the log level output for specific errors

### Jobs fail to start

- Ensure the `workdir` has sufficient space
- Check if required dependencies are available
- Verify the workflow requirements match your environment

## Support

If you encounter issues:
1. Check the add-on logs for error messages
2. Ensure all required configuration options are set correctly
3. Verify your GitHub token has appropriate permissions
4. Open an issue on the GitHub repository

## License

MIT License

## Acknowledgments

This add-on uses the official GitHub Actions Runner from the [actions/runner](https://github.com/actions/runner) repository.