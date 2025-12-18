# Puppet Master - Ephemeral GitHub Actions Runners

A single "puppet master" container that orchestrates ephemeral GitHub Actions runners. Each job gets a fresh container with no cache pollution.

## Features

- **Single controller** - One puppet master manages all runners
- **Per-repo and per-org support** - Configure personal repos individually, share runners across orgs
- **Customizable resources** - Set CPU and RAM limits per repo/org
- **No cache pollution** - Each job gets a fresh container
- **Auto-scaling** - Spawns runners on demand up to your ceiling
- **Docker & Podman compatible** - Works with both container runtimes

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      HOST MACHINE                           │
│                                                             │
│  ┌─────────────────────┐     ┌─────────────────────────┐   │
│  │   Puppet Master     │────▶│  Docker/Podman Socket   │   │
│  │                     │     └───────────┬─────────────┘   │
│  │  - Reads config.json│                 │                  │
│  │  - Polls GitHub API │                 ▼                  │
│  │  - Spawns runners   │     ┌─────────────────────────┐   │
│  │  - Cleans up        │     │   Ephemeral Runners     │   │
│  └─────────────────────┘     │                         │   │
│                              │  ┌───┐ ┌───┐ ┌───┐      │   │
│  config.json:                │  │J1 │ │J2 │ │J3 │ ...  │   │
│  {                           │  └─┬─┘ └─┬─┘ └─┬─┘      │   │
│    "repos": {...},           │    ↓     ↓     ↓        │   │
│    "orgs": {...}             │  exit  exit  exit       │   │
│  }                           │  (auto cleanup)         │   │
│                              └─────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# 1. Navigate to puppet-master directory
cd docker/puppet-master

# 2. Create configuration files
cp .env.example .env
cp config.json.example config.json

# 3. Edit .env - set your GitHub PAT
nano .env

# 4. Edit config.json - configure your repos and/or orgs
nano config.json

# 5. Build and start
./setup.sh start

# 6. View logs
./setup.sh logs
```

## Configuration

### .env

```bash
# Required: GitHub PAT with repo and workflow permissions
GITHUB_PAT=ghp_xxxxxxxxxxxx

# Optional settings
POLL_INTERVAL=30                        # How often to check for jobs
RUNNER_IMAGE=gh-ephemeral-runner:latest # Image for runners
CONTAINER_NETWORK=github-runners        # Network name
```

### config.json

```json
{
    "defaults": {
        "cpus": 2,
        "ram": "2g"
    },
    "repos": {
        "YourUser/RepoA": {
            "max_count": 4,
            "cpus": 4,
            "ram": "4g"
        },
        "YourUser/RepoB": {
            "max_count": 1
        }
    },
    "orgs": {
        "YourOrg": {
            "max_count": 5,
            "cpus": 2,
            "ram": "2g"
        }
    }
}
```

| Field | Description |
|-------|-------------|
| `defaults.cpus` | Default CPU limit for runners |
| `defaults.ram` | Default memory limit for runners |
| `repos.<owner/repo>.max_count` | Maximum concurrent runners for this repo |
| `repos.<owner/repo>.cpus` | CPU limit (overrides default) |
| `repos.<owner/repo>.ram` | Memory limit (overrides default) |
| `orgs.<org>.max_count` | Maximum concurrent runners for this org |
| `orgs.<org>.cpus` | CPU limit for org runners |
| `orgs.<org>.ram` | Memory limit for org runners |

### Repos vs Orgs

- **repos**: For personal repositories. Each repo gets its own runner pool.
- **orgs**: For organization repositories. Runners are shared across all repos in the org.

GitHub doesn't allow sharing runners between personal repos and organizations, which is why they're configured separately.

## Commands

```bash
./setup.sh build   # Build container images
./setup.sh start   # Build and start puppet master
./setup.sh stop    # Stop puppet master and cleanup runners
./setup.sh logs    # View puppet master logs (follow mode)
./setup.sh status  # Show status of all containers
./setup.sh help    # Show help
```

## Podman Support

The setup script auto-detects whether you're using Docker or Podman. For Podman:

### Rootful Podman
```bash
# Ensure the Podman socket is enabled
sudo systemctl enable --now podman.socket

# The socket will be at /var/run/podman/podman.sock
./setup.sh start
```

### Rootless Podman
```bash
# Enable the user socket
systemctl --user enable --now podman.socket

# The socket will be at $XDG_RUNTIME_DIR/podman/podman.sock
./setup.sh start
```

If using docker-compose with Podman, you may need to edit `docker-compose.yml` to point to your Podman socket.

## GitHub PAT Requirements

Your Personal Access Token needs these scopes:
- `repo` - Full repository access
- `workflow` - Workflow access (for registration tokens)

For organization runners, you also need:
- `admin:org` - Organization administration (for org runner registration)

## How It Works

1. **Puppet Master** polls GitHub API every N seconds (configurable)
2. For each repo/org in config, it checks for queued workflow runs
3. Compares queued jobs vs active runners vs max_count ceiling
4. Spawns new ephemeral runners if needed (up to ceiling)
5. Each runner:
   - Registers with `--ephemeral` flag
   - Runs exactly ONE job
   - Exits automatically after job completes
6. Puppet Master cleans up exited containers on next poll

## Troubleshooting

### Runners not spawning

Check logs: `./setup.sh logs`

Common issues:
- Invalid GitHub PAT (check permissions)
- Repo/org not in config.json
- Already at max_count ceiling
- API rate limiting (increase POLL_INTERVAL)

### Permission errors with container socket

```bash
# Docker
sudo chmod 666 /var/run/docker.sock

# Podman (rootful)
sudo chmod 666 /var/run/podman/podman.sock
```

### Podman socket not found

```bash
# Check if socket exists
ls -la /var/run/podman/podman.sock  # rootful
ls -la $XDG_RUNTIME_DIR/podman/podman.sock  # rootless

# Enable socket if needed
sudo systemctl start podman.socket  # rootful
systemctl --user start podman.socket  # rootless
```

### Rate limiting

If you have many repos/orgs, you might hit GitHub API rate limits. Solutions:
- Increase `POLL_INTERVAL` in .env
- Use a GitHub App instead of PAT (higher rate limits)
