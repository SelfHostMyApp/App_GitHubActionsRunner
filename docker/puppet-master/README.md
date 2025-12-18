# Puppet Master - Ephemeral GitHub Actions Runners

A single "puppet master" container that orchestrates ephemeral GitHub Actions runners. Each job gets a fresh container with no cache pollution.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     HOST MACHINE                            │
│                                                             │
│  ┌─────────────────────┐     ┌─────────────────────────┐   │
│  │   Puppet Master     │     │    Docker Socket        │   │
│  │                     │────▶│  /var/run/docker.sock   │   │
│  │  - Reads count.json │     └─────────────────────────┘   │
│  │  - Polls GitHub API │                │                  │
│  │  - Spawns runners   │                │                  │
│  │  - Cleans up        │                ▼                  │
│  └─────────────────────┘     ┌─────────────────────────┐   │
│                              │  Ephemeral Runners       │   │
│                              │                          │   │
│  count.json:                 │  ┌──────┐ ┌──────┐      │   │
│  {                           │  │Job 1 │ │Job 2 │ ...  │   │
│    "user/repo": 4  (ceiling) │  └──────┘ └──────┘      │   │
│  }                           │     │          │         │   │
│                              │     ▼          ▼         │   │
│                              │  Exits     Exits        │   │
│                              │  (cleaned up)           │   │
│                              └─────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## How It Works

1. **Puppet Master** polls GitHub API every 30s (configurable)
2. For each repo in `count.json`, it checks for queued jobs
3. Spawns ephemeral runners up to the ceiling limit
4. Each runner:
   - Registers with `--ephemeral` flag
   - Runs exactly ONE job
   - Exits automatically
5. Puppet Master cleans up exited containers

## Benefits

- **No Cache Pollution**: Each job gets a fresh container
- **Resource Efficient**: Uses host Docker socket (not docker-in-docker)
- **Simple Configuration**: Just edit `count.json`
- **Auto-scaling**: Spawns runners based on demand (up to ceiling)
- **Self-cleaning**: Automatically removes completed runners

## Quick Start

```bash
# 1. Navigate to puppet-master directory
cd docker/puppet-master

# 2. Create configuration
cp .env.example .env
cp count.json.example count.json

# 3. Edit .env with your GitHub PAT
nano .env

# 4. Edit count.json with your repos and ceilings
nano count.json

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
POLL_INTERVAL=30        # How often to check for jobs
CONTAINER_CPU=2         # CPU limit per runner
CONTAINER_MEMORY=2g     # Memory limit per runner
```

### count.json

Defines the maximum concurrent runners (ceiling) per repository:

```json
{
    "JamesonRGrieve/ServerFramework": 4,
    "JamesonRGrieve/ClientFramework": 1,
    "YourOrg/YourRepo": 2
}
```

The puppet master will never spawn more runners than the ceiling, even if there are more jobs queued.

## Commands

```bash
./setup.sh build   # Build images
./setup.sh start   # Build and start puppet master
./setup.sh stop    # Stop puppet master and cleanup runners
./setup.sh logs    # View puppet master logs
./setup.sh status  # Show running containers
```

## GitHub PAT Requirements

Your Personal Access Token needs these permissions:
- `repo` - Full repository access
- `workflow` - Workflow access (for registration tokens)

## Troubleshooting

### Runners not spawning

Check logs: `./setup.sh logs`

Common issues:
- Invalid GitHub PAT
- Repo not in count.json
- Already at ceiling limit

### Docker socket permission errors

The puppet master needs access to the Docker socket. Ensure:
- `/var/run/docker.sock` exists
- Current user can access Docker

### Rate limiting

If you have many repos, you might hit GitHub API rate limits. Increase `POLL_INTERVAL` to reduce API calls.
