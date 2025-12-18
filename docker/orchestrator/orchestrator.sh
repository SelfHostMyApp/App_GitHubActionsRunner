#!/bin/bash
# orchestrator.sh - Orchestrates ephemeral GitHub Actions runners
#
# Architecture:
# - Single container with Docker/Podman socket access
# - Reads config.json for per-repo/org runner settings
# - Spawns ephemeral runners that handle ONE job then die
# - No cache pollution - each job gets a fresh container
#
# Supports:
# - Repository-level runners (for personal repos)
# - Organization-level runners (shared across org repos)
# - Per-entry resource limits (cpus, ram)
# - Docker and Podman runtimes
# - Multiple orchestrators (uses GitHub API for runner count, not local containers)

set -e

# Configuration
CONFIG_FILE="${CONFIG_FILE:-/config/config.json}"
GITHUB_PAT="${GITHUB_PAT:?GITHUB_PAT is required}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/selfhostmyapp/ephemeral-runner:latest}"
CONTAINER_NETWORK="${CONTAINER_NETWORK:-github-runners}"

# Detect container runtime (Docker or Podman)
detect_runtime() {
    if command -v docker &> /dev/null && docker info &> /dev/null 2>&1; then
        echo "docker"
    elif command -v podman &> /dev/null && podman info &> /dev/null 2>&1; then
        echo "podman"
    else
        echo ""
    fi
}

RUNTIME=$(detect_runtime)
if [ -z "$RUNTIME" ]; then
    echo "ERROR: Neither Docker nor Podman is available"
    exit 1
fi

# Detect socket path
detect_socket() {
    if [ -e "/var/run/docker.sock" ]; then
        echo "/var/run/docker.sock"
    elif [ -e "/var/run/podman/podman.sock" ]; then
        echo "/var/run/podman/podman.sock"
    elif [ -e "/run/podman/podman.sock" ]; then
        echo "/run/podman/podman.sock"
    elif [ -e "$XDG_RUNTIME_DIR/podman/podman.sock" ]; then
        echo "$XDG_RUNTIME_DIR/podman/podman.sock"
    else
        echo ""
    fi
}

CONTAINER_SOCKET=$(detect_socket)

echo "==========================================="
echo "  GitHub Actions Runner Orchestrator"
echo "==========================================="
echo "Runtime: ${RUNTIME}"
echo "Socket: ${CONTAINER_SOCKET:-not mounted (using default)}"
echo "Config file: ${CONFIG_FILE}"
echo "Runner image: ${RUNNER_IMAGE}"
echo "Poll interval: ${POLL_INTERVAL}s"
echo "==========================================="

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Create a config.json - see config.json.example"
    exit 1
fi

# Create container network if it doesn't exist
$RUNTIME network inspect "$CONTAINER_NETWORK" >/dev/null 2>&1 || {
    echo "Creating container network: $CONTAINER_NETWORK"
    $RUNTIME network create "$CONTAINER_NETWORK"
}

# Read default settings from config
get_default() {
    local key="$1"
    local fallback="$2"
    jq -r ".defaults.${key} // \"${fallback}\"" "$CONFIG_FILE"
}

DEFAULT_CPUS=$(get_default "cpus" "2")
DEFAULT_RAM=$(get_default "ram" "2g")

echo "Default resources: ${DEFAULT_CPUS} CPUs, ${DEFAULT_RAM} RAM"
echo "Multi-orchestrator safe: Yes (uses GitHub API for runner counts)"
echo "==========================================="
echo ""

# Function to get queued jobs for a repository
get_repo_queued_jobs() {
    local owner_repo="$1"
    local response

    response=$(curl -s -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${owner_repo}/actions/runs?status=queued" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "0"
        return
    fi

    echo "$response" | jq -r '.total_count // 0'
}

# Function to get queued jobs for an organization (across all repos)
get_org_queued_jobs() {
    local org="$1"
    local response
    local total=0

    # Get queued workflow runs across the org
    response=$(curl -s -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/orgs/${org}/actions/runs?status=queued" 2>/dev/null)

    if [ $? -eq 0 ]; then
        total=$(echo "$response" | jq -r '.total_count // 0')
    fi

    echo "$total"
}

# Function to get REGISTERED runners for a repository (from GitHub API)
# This allows multiple orchestrators to coordinate - they all see the same count
get_repo_registered_runners() {
    local owner_repo="$1"
    local response

    response=$(curl -s -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${owner_repo}/actions/runners" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "0"
        return
    fi

    # Count online runners only (busy or idle, not offline)
    echo "$response" | jq -r '[.runners[] | select(.status == "online")] | length // 0'
}

# Function to get REGISTERED runners for an organization (from GitHub API)
get_org_registered_runners() {
    local org="$1"
    local response

    response=$(curl -s -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/orgs/${org}/actions/runners" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "0"
        return
    fi

    # Count online runners only
    echo "$response" | jq -r '[.runners[] | select(.status == "online")] | length // 0'
}

# Function to get a registration token for a repository
get_repo_registration_token() {
    local owner_repo="$1"

    curl -s -X POST \
        -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${owner_repo}/actions/runners/registration-token" | jq -r '.token // empty'
}

# Function to get a registration token for an organization
get_org_registration_token() {
    local org="$1"

    curl -s -X POST \
        -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/orgs/${org}/actions/runners/registration-token" | jq -r '.token // empty'
}

# Function to spawn a repository-level ephemeral runner
spawn_repo_runner() {
    local owner_repo="$1"
    local cpus="$2"
    local ram="$3"
    local owner="${owner_repo%%/*}"
    local repo="${owner_repo##*/}"
    local repo_slug
    repo_slug=$(echo "$owner_repo" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

    # Generate unique runner ID (must be <= 64 chars for GitHub)
    # Format: eph-r-{slug (truncated to 45 chars)}-{8 char hex}
    local short_slug="${repo_slug:0:45}"
    local rand_hex=$(head -c 4 /dev/urandom | xxd -p)
    local runner_id="eph-r-${short_slug}-${rand_hex}"

    echo "  Spawning repo runner: $runner_id"
    echo "    Target: $owner_repo"
    echo "    Resources: ${cpus} CPUs, ${ram} RAM"

    # Get registration token
    local reg_token
    reg_token=$(get_repo_registration_token "$owner_repo")

    if [ -z "$reg_token" ]; then
        echo "  ERROR: Failed to get registration token for $owner_repo"
        return 1
    fi

    # Build volume mount for container socket
    local socket_mount=""
    if [ -n "$CONTAINER_SOCKET" ]; then
        socket_mount="-v ${CONTAINER_SOCKET}:/var/run/docker.sock"
    fi

    # Spawn the ephemeral runner container
    $RUNTIME run -d \
        --name "$runner_id" \
        --network "$CONTAINER_NETWORK" \
        --cpus="$cpus" \
        --memory="$ram" \
        $socket_mount \
        -e RUNNER_TYPE="repo" \
        -e GITHUB_ACTIONS_USER_NAME="$owner" \
        -e GITHUB_ACTIONS_REPOSITORIES="$repo" \
        -e GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN="$reg_token" \
        -e RUNNER_NAME="$runner_id" \
        -e RUNNER_LABELS="${repo}-runner,ephemeral" \
        "$RUNNER_IMAGE" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "  Started: $runner_id"
        return 0
    else
        echo "  ERROR: Failed to start runner $runner_id"
        return 1
    fi
}

# Function to spawn an organization-level ephemeral runner
spawn_org_runner() {
    local org="$1"
    local cpus="$2"
    local ram="$3"
    local org_slug
    org_slug=$(echo "$org" | tr '[:upper:]' '[:lower:]')

    # Generate unique runner ID (must be <= 64 chars for GitHub)
    # Format: eph-o-{org (truncated to 45 chars)}-{8 char hex}
    local short_slug="${org_slug:0:45}"
    local rand_hex=$(head -c 4 /dev/urandom | xxd -p)
    local runner_id="eph-o-${short_slug}-${rand_hex}"

    echo "  Spawning org runner: $runner_id"
    echo "    Target: $org (organization)"
    echo "    Resources: ${cpus} CPUs, ${ram} RAM"

    # Get registration token
    local reg_token
    reg_token=$(get_org_registration_token "$org")

    if [ -z "$reg_token" ]; then
        echo "  ERROR: Failed to get registration token for org $org"
        return 1
    fi

    # Build volume mount for container socket
    local socket_mount=""
    if [ -n "$CONTAINER_SOCKET" ]; then
        socket_mount="-v ${CONTAINER_SOCKET}:/var/run/docker.sock"
    fi

    # Spawn the ephemeral runner container
    $RUNTIME run -d \
        --name "$runner_id" \
        --network "$CONTAINER_NETWORK" \
        --cpus="$cpus" \
        --memory="$ram" \
        $socket_mount \
        -e RUNNER_TYPE="org" \
        -e GITHUB_ACTIONS_ORGANIZATION_NAME="$org" \
        -e GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN="$reg_token" \
        -e RUNNER_NAME="$runner_id" \
        -e RUNNER_LABELS="${org}-runner,ephemeral,org-runner" \
        "$RUNNER_IMAGE" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "  Started: $runner_id"
        return 0
    else
        echo "  ERROR: Failed to start runner $runner_id"
        return 1
    fi
}

# Function to cleanup exited runner containers (local only)
cleanup_exited_runners() {
    local exited_containers
    # Match both eph-r- (repo) and eph-o- (org) prefixes
    exited_containers=$($RUNTIME ps -a --filter "name=eph-" --filter "status=exited" --format "{{.Names}}" 2>/dev/null)

    for container in $exited_containers; do
        echo "  Cleaning up exited runner: $container"
        $RUNTIME rm "$container" >/dev/null 2>&1 || true
    done
}

# Function to process repositories from config
process_repos() {
    local repos
    repos=$(jq -r '.repos // {} | keys[]' "$CONFIG_FILE" 2>/dev/null)

    for owner_repo in $repos; do
        local max_count cpus ram
        max_count=$(jq -r ".repos[\"${owner_repo}\"].max_count // 1" "$CONFIG_FILE")
        cpus=$(jq -r ".repos[\"${owner_repo}\"].cpus // \"${DEFAULT_CPUS}\"" "$CONFIG_FILE")
        ram=$(jq -r ".repos[\"${owner_repo}\"].ram // \"${DEFAULT_RAM}\"" "$CONFIG_FILE")

        local queued_jobs registered_runners
        queued_jobs=$(get_repo_queued_jobs "$owner_repo")

        # Only check registered runners if there are queued jobs (reduces API calls)
        if [ "$queued_jobs" -gt 0 ]; then
            # Use GitHub API to get runner count (works across multiple orchestrators)
            registered_runners=$(get_repo_registered_runners "$owner_repo")
            echo "[REPO: $owner_repo] Queued: $queued_jobs, Registered: $registered_runners, Max: $max_count"
        else
            echo "[REPO: $owner_repo] Queued: 0 (idle)"
            continue
        fi

        # Calculate how many runners we need to spawn
        if [ "$queued_jobs" -gt "$registered_runners" ] && [ "$registered_runners" -lt "$max_count" ]; then
            local runners_needed=$((queued_jobs - registered_runners))
            local runners_available=$((max_count - registered_runners))
            local runners_to_spawn

            # Don't exceed the ceiling
            if [ "$runners_needed" -gt "$runners_available" ]; then
                runners_to_spawn=$runners_available
            else
                runners_to_spawn=$runners_needed
            fi

            echo "  Spawning $runners_to_spawn runner(s)..."
            for i in $(seq 1 $runners_to_spawn); do
                spawn_repo_runner "$owner_repo" "$cpus" "$ram"
                # Small delay between spawns to avoid rate limiting
                sleep 2
            done
        fi
    done
}

# Function to process organizations from config
process_orgs() {
    local orgs
    orgs=$(jq -r '.orgs // {} | keys[]' "$CONFIG_FILE" 2>/dev/null)

    for org in $orgs; do
        local max_count cpus ram
        max_count=$(jq -r ".orgs[\"${org}\"].max_count // 1" "$CONFIG_FILE")
        cpus=$(jq -r ".orgs[\"${org}\"].cpus // \"${DEFAULT_CPUS}\"" "$CONFIG_FILE")
        ram=$(jq -r ".orgs[\"${org}\"].ram // \"${DEFAULT_RAM}\"" "$CONFIG_FILE")

        local queued_jobs registered_runners
        queued_jobs=$(get_org_queued_jobs "$org")

        # Only check registered runners if there are queued jobs (reduces API calls)
        if [ "$queued_jobs" -gt 0 ]; then
            # Use GitHub API to get runner count (works across multiple orchestrators)
            registered_runners=$(get_org_registered_runners "$org")
            echo "[ORG: $org] Queued: $queued_jobs, Registered: $registered_runners, Max: $max_count"
        else
            echo "[ORG: $org] Queued: 0 (idle)"
            continue
        fi

        # Calculate how many runners we need to spawn
        if [ "$queued_jobs" -gt "$registered_runners" ] && [ "$registered_runners" -lt "$max_count" ]; then
            local runners_needed=$((queued_jobs - registered_runners))
            local runners_available=$((max_count - registered_runners))
            local runners_to_spawn

            # Don't exceed the ceiling
            if [ "$runners_needed" -gt "$runners_available" ]; then
                runners_to_spawn=$runners_available
            else
                runners_to_spawn=$runners_needed
            fi

            echo "  Spawning $runners_to_spawn runner(s)..."
            for i in $(seq 1 $runners_to_spawn); do
                spawn_org_runner "$org" "$cpus" "$ram"
                # Small delay between spawns to avoid rate limiting
                sleep 2
            done
        fi
    done
}

# Graceful shutdown handler
shutdown() {
    echo ""
    echo "Shutting down orchestrator..."
    echo "Note: Running ephemeral runners will complete their jobs."
    exit 0
}

trap shutdown INT TERM

echo "Starting main control loop..."
echo ""

# Main loop
while true; do
    echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---"

    # First, cleanup any exited runners (local containers only)
    cleanup_exited_runners

    # Process repositories (personal repos need individual runners)
    process_repos

    # Process organizations (shared runners across org repos)
    process_orgs

    echo ""
    sleep "$POLL_INTERVAL"
done
