#!/bin/bash
# puppet-master.sh - Orchestrates ephemeral GitHub Actions runners
#
# Architecture:
# - Single container with Docker socket access
# - Reads count.json for per-repo runner ceilings
# - Spawns ephemeral runners that handle ONE job then die
# - No cache pollution - each job gets a fresh container

set -e

# Configuration
CONFIG_FILE="${CONFIG_FILE:-/config/count.json}"
GITHUB_PAT="${GITHUB_PAT:?GITHUB_PAT is required}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/selfhostmyapp/ephemeral-runner:latest}"
DOCKER_NETWORK="${DOCKER_NETWORK:-github-runners}"
CONTAINER_CPU="${CONTAINER_CPU:-2}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-2g}"

# Prefix for all spawned runner containers
RUNNER_PREFIX="ephemeral-runner"

echo "==========================================="
echo "  GitHub Actions Puppet Master Controller"
echo "==========================================="
echo "Config file: ${CONFIG_FILE}"
echo "Runner image: ${RUNNER_IMAGE}"
echo "Poll interval: ${POLL_INTERVAL}s"
echo "Container limits: ${CONTAINER_CPU} CPU, ${CONTAINER_MEMORY} memory"
echo "==========================================="

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Create a count.json with format: {\"owner/repo\": max_runners, ...}"
    exit 1
fi

# Create Docker network if it doesn't exist
docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || {
    echo "Creating Docker network: $DOCKER_NETWORK"
    docker network create "$DOCKER_NETWORK"
}

# Function to get queued jobs for a repository
get_queued_jobs() {
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

# Function to get active runners for a repository
get_active_runners() {
    local owner_repo="$1"
    local repo_slug
    repo_slug=$(echo "$owner_repo" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

    docker ps --filter "name=${RUNNER_PREFIX}-${repo_slug}" --format "{{.Names}}" 2>/dev/null | wc -l
}

# Function to get a registration token for a repository
get_registration_token() {
    local owner_repo="$1"

    curl -s -X POST \
        -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${owner_repo}/actions/runners/registration-token" | jq -r '.token // empty'
}

# Function to spawn an ephemeral runner
spawn_runner() {
    local owner_repo="$1"
    local owner="${owner_repo%%/*}"
    local repo="${owner_repo##*/}"
    local repo_slug
    repo_slug=$(echo "$owner_repo" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

    # Generate unique runner ID
    local runner_id="${RUNNER_PREFIX}-${repo_slug}-$(date +%s)-$(head -c 4 /dev/urandom | xxd -p)"

    echo "  Spawning runner: $runner_id for $owner_repo"

    # Get registration token
    local reg_token
    reg_token=$(get_registration_token "$owner_repo")

    if [ -z "$reg_token" ]; then
        echo "  ERROR: Failed to get registration token for $owner_repo"
        return 1
    fi

    # Spawn the ephemeral runner container
    # Key points:
    # - Uses host Docker socket (NOT docker-in-docker)
    # - --ephemeral flag means it runs ONE job then exits
    # - Container is removed after exit (--rm would auto-remove, but we want to see exit status)
    docker run -d \
        --name "$runner_id" \
        --network "$DOCKER_NETWORK" \
        --cpus="$CONTAINER_CPU" \
        --memory="$CONTAINER_MEMORY" \
        -v /var/run/docker.sock:/var/run/docker.sock \
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

# Function to cleanup exited runner containers
cleanup_exited_runners() {
    local exited_containers
    exited_containers=$(docker ps -a --filter "name=${RUNNER_PREFIX}" --filter "status=exited" --format "{{.Names}}" 2>/dev/null)

    for container in $exited_containers; do
        echo "  Cleaning up exited runner: $container"
        docker rm "$container" >/dev/null 2>&1 || true
    done
}

# Function to process a single repository
process_repo() {
    local owner_repo="$1"
    local max_runners="$2"

    local queued_jobs
    local active_runners

    queued_jobs=$(get_queued_jobs "$owner_repo")
    active_runners=$(get_active_runners "$owner_repo")

    echo "[$owner_repo] Queued: $queued_jobs, Active: $active_runners, Max: $max_runners"

    # Calculate how many runners we need to spawn
    if [ "$queued_jobs" -gt "$active_runners" ] && [ "$active_runners" -lt "$max_runners" ]; then
        local runners_needed=$((queued_jobs - active_runners))
        local runners_available=$((max_runners - active_runners))
        local runners_to_spawn

        # Don't exceed the ceiling
        if [ "$runners_needed" -gt "$runners_available" ]; then
            runners_to_spawn=$runners_available
        else
            runners_to_spawn=$runners_needed
        fi

        echo "  Spawning $runners_to_spawn runner(s)..."
        for i in $(seq 1 $runners_to_spawn); do
            spawn_runner "$owner_repo"
            # Small delay between spawns to avoid rate limiting
            sleep 1
        done
    fi
}

# Graceful shutdown handler
shutdown() {
    echo ""
    echo "Shutting down puppet master..."
    echo "Note: Running ephemeral runners will complete their jobs."
    exit 0
}

trap shutdown INT TERM

echo ""
echo "Starting main control loop..."
echo ""

# Main loop
while true; do
    echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---"

    # First, cleanup any exited runners
    cleanup_exited_runners

    # Read config and process each repository
    # Format: {"owner/repo": max_runners, ...}
    while IFS="=" read -r owner_repo max_runners; do
        # Skip empty lines
        [ -z "$owner_repo" ] && continue
        process_repo "$owner_repo" "$max_runners"
    done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE")

    echo ""
    sleep "$POLL_INTERVAL"
done
