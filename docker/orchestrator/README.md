# Orchestrator - Ephemeral GitHub Actions Runners

A single orchestrator container that manages ephemeral GitHub Actions runners. Each job gets a fresh container with no cache pollution.

## Features

- **Single controller** - One orchestrator manages all runners
- **Per-repo and per-org support** - Configure personal repos individually, share runners across orgs
- **Customizable resources** - Set CPU and RAM limits per repo/org
- **Label-based runner profiles** - Different resource pools for different job types (e.g., singlethreaded vs multithreaded)
- **Global thread limit** - Prevent system overload with max_threads setting
- **No cache pollution** - Each job gets a fresh container
- **Auto-scaling** - Spawns runners on demand up to your ceiling
- **Multi-orchestrator safe** - Multiple orchestrators on different hosts coordinate via GitHub API
- **Docker & Podman compatible** - Works with both container runtimes

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      HOST MACHINE                           │
│                                                             │
│  ┌─────────────────────┐     ┌─────────────────────────┐   │
│  │    Orchestrator     │────▶│  Docker/Podman Socket   │   │
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
# 1. Navigate to orchestrator directory
cd docker/orchestrator

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
    "max_threads": 16,
    "defaults": {
        "cpus": 2,
        "ram": "2g"
    },
    "repos": {
        "YourUser/RepoA:singlethreaded": {
            "max_count": 4,
            "cpus": 1,
            "ram": "1g"
        },
        "YourUser/RepoA:multithreaded": {
            "max_count": 2,
            "cpus": 8,
            "ram": "8g"
        },
        "YourUser/RepoB": {
            "max_count": 1
        }
    },
    "orgs": {
        "YourOrg:singlethreaded": {
            "max_count": 4,
            "cpus": 1,
            "ram": "1g"
        },
        "YourOrg:multithreaded": {
            "max_count": 2,
            "cpus": 4,
            "ram": "4g"
        }
    }
}
```

| Field | Description |
|-------|-------------|
| `max_threads` | Global CPU limit across all runners (0 = unlimited) |
| `defaults.cpus` | Default CPU limit for runners |
| `defaults.ram` | Default memory limit for runners |
| `repos.<owner/repo>.max_count` | Maximum concurrent runners for this repo |
| `repos.<owner/repo>.cpus` | CPU limit (overrides default) |
| `repos.<owner/repo>.ram` | Memory limit (overrides default) |
| `orgs.<org>.max_count` | Maximum concurrent runners for this org |
| `orgs.<org>.cpus` | CPU limit for org runners |
| `orgs.<org>.ram` | Memory limit for org runners |

### Label-Based Runner Profiles

You can create different runner pools with different resources by adding a label suffix to the config key:

```json
{
    "repos": {
        "User/Repo:singlethreaded": { "max_count": 4, "cpus": 1, "ram": "1g" },
        "User/Repo:multithreaded": { "max_count": 2, "cpus": 8, "ram": "8g" }
    }
}
```

Then in your workflow, specify which runner type you need:

```yaml
jobs:
  lint:
    runs-on: [self-hosted, singlethreaded]  # Uses 1 CPU runner
    steps:
      - run: npm run lint

  test:
    runs-on: [self-hosted, multithreaded]   # Uses 8 CPU runner
    steps:
      - run: npm test

  build:
    runs-on: [self-hosted]                   # Uses either pool
    steps:
      - run: npm run build
```

- Jobs with `runs-on: [self-hosted, singlethreaded]` only run on singlethreaded runners
- Jobs with `runs-on: [self-hosted, multithreaded]` only run on multithreaded runners
- Jobs with just `runs-on: [self-hosted]` can run on either type

### Global Thread Limit

The `max_threads` setting prevents system overload by limiting total CPU allocation across all runners:

```json
{
    "max_threads": 16,
    ...
}
```

If spawning a new runner would exceed this limit, it will be skipped with a message:
```
SKIPPED: Global thread limit reached (14/16 threads in use)
```

Set to `0` for unlimited (not recommended for shared systems).

### Repos vs Orgs

- **repos**: For personal repositories. Each repo gets its own runner pool.
- **orgs**: For organization repositories. Runners are shared across all repos in the org.

GitHub doesn't allow sharing runners between personal repos and organizations, which is why they're configured separately.

## Commands

```bash
./setup.sh build   # Build container images
./setup.sh start   # Build and start orchestrator
./setup.sh stop    # Stop orchestrator and cleanup runners
./setup.sh logs    # View orchestrator logs (follow mode)
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

1. **Orchestrator** polls GitHub API every N seconds (configurable)
2. For each repo/org in config, it checks for queued workflow runs
3. Compares queued jobs vs registered runners vs max_count ceiling
4. Checks global thread limit before spawning
5. Spawns new ephemeral runners if needed (up to ceiling)
6. Each runner:
   - Registers with `--ephemeral` flag and configured labels
   - Runs exactly ONE job
   - Exits automatically after job completes
7. Orchestrator cleans up exited containers on next poll

## Troubleshooting

### Runners not spawning

Check logs: `./setup.sh logs`

Common issues:
- Invalid GitHub PAT (check permissions)
- Repo/org not in config.json
- Already at max_count ceiling
- Global max_threads limit reached
- API rate limiting (increase POLL_INTERVAL)

### Jobs not matching runners

If jobs stay queued but runners are available, check the labels:
- Workflow `runs-on` must match runner labels exactly
- `runs-on: [self-hosted, singlethreaded]` needs a runner with `singlethreaded` label
- Check runner labels in GitHub Settings → Actions → Runners

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
