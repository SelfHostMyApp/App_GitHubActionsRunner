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
# - Label-based runner profiles (e.g., :singlethreaded, :multithreaded)
# - Global max_threads limit to prevent system overload
# - Docker and Podman runtimes
# - Multiple orchestrators (uses GitHub API for runner count, not local containers)

# Don't use set -e - we handle errors explicitly to avoid crashes
# set -e

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

# Read global max_threads (0 = unlimited)
MAX_THREADS=$(jq -r '.max_threads // 0' "$CONFIG_FILE")

echo "Default resources: ${DEFAULT_CPUS} CPUs, ${DEFAULT_RAM} RAM"
if [ "$MAX_THREADS" -gt 0 ]; then
    echo "Global thread limit: ${MAX_THREADS}"
else
    echo "Global thread limit: unlimited"
fi
echo "Multi-orchestrator safe: Yes (uses GitHub API for runner counts)"
echo "==========================================="
echo ""

# Function to get current thread usage from running containers
get_current_thread_usage() {
    local total=0
    local cpus_list

    # Get CPU allocation for all running ephemeral runner containers
    cpus_list=$($RUNTIME ps --filter "name=eph-" --format "{{.Names}}" 2>/dev/null)

    for container in $cpus_list; do
        # Get the CPU limit for this container
        local container_cpus
        container_cpus=$($RUNTIME inspect "$container" --format '{{.HostConfig.NanoCpus}}' 2>/dev/null)
        if [ -n "$container_cpus" ] && [ "$container_cpus" != "0" ]; then
            # NanoCpus is in billionths of a CPU, convert to CPUs
            local cpus=$((container_cpus / 1000000000))
            total=$((total + cpus))
        else
            # If no limit set, try to get from CpuQuota/CpuPeriod
            local quota period
            quota=$($RUNTIME inspect "$container" --format '{{.HostConfig.CpuQuota}}' 2>/dev/null)
            period=$($RUNTIME inspect "$container" --format '{{.HostConfig.CpuPeriod}}' 2>/dev/null)
            if [ -n "$quota" ] && [ "$quota" != "0" ] && [ -n "$period" ] && [ "$period" != "0" ]; then
                local cpus=$((quota / period))
                total=$((total + cpus))
            fi
        fi
    done

    echo "$total"
}

# Function to check if we can spawn a runner with given CPUs
can_spawn_with_cpus() {
    local cpus="$1"

    # If max_threads is 0 (unlimited), always allow
    if [ "$MAX_THREADS" -eq 0 ]; then
        return 0
    fi

    local current_usage
    current_usage=$(get_current_thread_usage)
    local new_usage=$((current_usage + cpus))

    if [ "$new_usage" -le "$MAX_THREADS" ]; then
        return 0
    else
        return 1
    fi
}

# Function to parse config key - extracts repo/org name and label
# Input: "User/Repo:label" or "User/Repo"
# Sets: PARSED_NAME and PARSED_LABEL
parse_config_key() {
    local key="$1"

    if [[ "$key" == *":"* ]]; then
        PARSED_NAME="${key%%:*}"
        PARSED_LABEL="${key##*:}"
    else
        PARSED_NAME="$key"
        PARSED_LABEL=""
    fi
}

# Function to get queued jobs for a repository
# Returns: number of queued jobs, or -1 on API error
get_repo_queued_jobs() {
    local owner_repo="$1"
    local response

    response=$(curl -s -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${owner_repo}/actions/runs?status=queued" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "-1"
        return
    fi

    # Check for API errors (rate limit, auth failure, etc.)
    local error_msg
    error_msg=$(echo "$response" | jq -r '.message // empty' 2>/dev/null)
    if [ -n "$error_msg" ]; then
        echo "-1"
        return
    fi

    echo "$response" | jq -r '.total_count // 0'
}

# Function to get queued jobs for an organization (across all repos)
# Returns: number of queued jobs, or -1 on API error
get_org_queued_jobs() {
    local org="$1"
    local response

    # Get queued workflow runs across the org
    response=$(curl -s -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/orgs/${org}/actions/runs?status=queued" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "-1"
        return
    fi

    # Check for API errors (rate limit, auth failure, etc.)
    local error_msg
    error_msg=$(echo "$response" | jq -r '.message // empty' 2>/dev/null)
    if [ -n "$error_msg" ]; then
        echo "-1"
        return
    fi

    echo "$response" | jq -r '.total_count // 0'
}

# Function to get online runner count for a repository (from GitHub API)
# Optionally filter by label
# Special case: "singlethreaded" counts runners WITHOUT "multithreaded" label
get_repo_runner_count() {
    local owner_repo="$1"
    local filter_label="$2"
    local response

    response=$(curl -s -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${owner_repo}/actions/runners" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "0"
        return
    fi

    # Count online runners, optionally filtering by label
    if [ "$filter_label" = "singlethreaded" ]; then
        # singlethreaded = runners WITHOUT the "multithreaded" label (default pool)
        echo "$response" | jq -r \
            '[.runners[] | select(.status == "online") | select(all(.labels[]; .name != "multithreaded"))] | length // 0'
    elif [ -n "$filter_label" ]; then
        # Other labels (like multithreaded) = runners WITH that label
        echo "$response" | jq -r --arg lbl "$filter_label" \
            '[.runners[] | select(.status == "online") | select(any(.labels[]; .name == $lbl))] | length // 0'
    else
        echo "$response" | jq -r '[.runners[] | select(.status == "online")] | length // 0'
    fi
}

# Function to get online runner count for an organization (from GitHub API)
# Optionally filter by label
# Special case: "singlethreaded" counts runners WITHOUT "multithreaded" label
get_org_runner_count() {
    local org="$1"
    local filter_label="$2"
    local response

    response=$(curl -s -H "Authorization: Bearer $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/orgs/${org}/actions/runners" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "0"
        return
    fi

    # Count online runners, optionally filtering by label
    if [ "$filter_label" = "singlethreaded" ]; then
        # singlethreaded = runners WITHOUT the "multithreaded" label (default pool)
        echo "$response" | jq -r \
            '[.runners[] | select(.status == "online") | select(all(.labels[]; .name != "multithreaded"))] | length // 0'
    elif [ -n "$filter_label" ]; then
        # Other labels (like multithreaded) = runners WITH that label
        echo "$response" | jq -r --arg lbl "$filter_label" \
            '[.runners[] | select(.status == "online") | select(any(.labels[]; .name == $lbl))] | length // 0'
    else
        echo "$response" | jq -r '[.runners[] | select(.status == "online")] | length // 0'
    fi
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
    local label="$4"
    local owner="${owner_repo%%/*}"
    local repo="${owner_repo##*/}"
    local repo_slug
    repo_slug=$(echo "$owner_repo" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

    # Check global thread limit
    if ! can_spawn_with_cpus "$cpus"; then
        local current
        current=$(get_current_thread_usage)
        echo "  SKIPPED: Global thread limit reached ($current/$MAX_THREADS threads in use)"
        return 1
    fi

    # Generate unique runner ID (must be <= 64 chars for GitHub)
    # Format: eph-r-{slug (truncated to 45 chars)}-{8 char hex}
    local short_slug="${repo_slug:0:45}"
    local rand_hex=$(head -c 4 /dev/urandom | xxd -p)
    local runner_id="eph-r-${short_slug}-${rand_hex}"

    echo "  Spawning repo runner: $runner_id"
    echo "    Target: $owner_repo"
    echo "    Resources: ${cpus} CPUs, ${ram} RAM"

    # Build labels - always include self-hosted
    # singlethreaded runners get NO extra label (so runs-on: self-hosted jobs go to them)
    # other labels (like multithreaded) are added explicitly
    local runner_labels="${repo}-runner,ephemeral"
    if [ -n "$label" ] && [ "$label" != "singlethreaded" ]; then
        runner_labels="${runner_labels},${label}"
        echo "    Labels: self-hosted, ${label}"
    else
        echo "    Labels: self-hosted (default pool)"
    fi

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
        -e RUNNER_LABELS="$runner_labels" \
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
    local label="$4"
    local org_slug
    org_slug=$(echo "$org" | tr '[:upper:]' '[:lower:]')

    # Check global thread limit
    if ! can_spawn_with_cpus "$cpus"; then
        local current
        current=$(get_current_thread_usage)
        echo "  SKIPPED: Global thread limit reached ($current/$MAX_THREADS threads in use)"
        return 1
    fi

    # Generate unique runner ID (must be <= 64 chars for GitHub)
    # Format: eph-o-{org (truncated to 45 chars)}-{8 char hex}
    local short_slug="${org_slug:0:45}"
    local rand_hex=$(head -c 4 /dev/urandom | xxd -p)
    local runner_id="eph-o-${short_slug}-${rand_hex}"

    echo "  Spawning org runner: $runner_id"
    echo "    Target: $org (organization)"
    echo "    Resources: ${cpus} CPUs, ${ram} RAM"

    # Build labels - always include self-hosted
    # singlethreaded runners get NO extra label (so runs-on: self-hosted jobs go to them)
    # other labels (like multithreaded) are added explicitly
    local runner_labels="${org}-runner,ephemeral,org-runner"
    if [ -n "$label" ] && [ "$label" != "singlethreaded" ]; then
        runner_labels="${runner_labels},${label}"
        echo "    Labels: self-hosted, ${label}"
    else
        echo "    Labels: self-hosted (default pool)"
    fi

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
        -e RUNNER_LABELS="$runner_labels" \
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

    for config_key in $repos; do
        # Parse the config key to extract repo name and optional label
        parse_config_key "$config_key"
        local owner_repo="$PARSED_NAME"
        local label="$PARSED_LABEL"

        local max_count cpus ram
        max_count=$(jq -r ".repos[\"${config_key}\"].max_count // 1" "$CONFIG_FILE")
        cpus=$(jq -r ".repos[\"${config_key}\"].cpus // \"${DEFAULT_CPUS}\"" "$CONFIG_FILE")
        ram=$(jq -r ".repos[\"${config_key}\"].ram // \"${DEFAULT_RAM}\"" "$CONFIG_FILE")

        local queued_jobs
        queued_jobs=$(get_repo_queued_jobs "$owner_repo")

        # Check for API error
        if [ "$queued_jobs" -eq -1 ]; then
            echo "[REPO: $config_key] API ERROR - skipping (rate limit or auth failure?)"
            continue
        fi

        # Only check registered runners if there are queued jobs (reduces API calls)
        if [ "$queued_jobs" -gt 0 ]; then
            # Use GitHub API to get runner count (works across multiple orchestrators)
            # Filter by label if one is specified
            local total_runners
            total_runners=$(get_repo_runner_count "$owner_repo" "$label")

            if [ -n "$label" ]; then
                echo "[REPO: $owner_repo:$label] Queued: $queued_jobs, Runners: $total_runners, Max: $max_count"
            else
                echo "[REPO: $owner_repo] Queued: $queued_jobs, Runners: $total_runners, Max: $max_count"
            fi
        else
            if [ -n "$label" ]; then
                echo "[REPO: $owner_repo:$label] Queued: 0 (idle)"
            else
                echo "[REPO: $owner_repo] Queued: 0 (idle)"
            fi
            continue
        fi

        # Calculate how many runners we need to spawn
        # Each queued job needs a runner (ephemeral = one job per runner)
        if [ "$total_runners" -lt "$max_count" ]; then
            local runners_available=$((max_count - total_runners))
            local runners_to_spawn

            # Spawn enough for queued jobs, but don't exceed the ceiling
            if [ "$queued_jobs" -gt "$runners_available" ]; then
                runners_to_spawn=$runners_available
            else
                runners_to_spawn=$queued_jobs
            fi

            echo "  Spawning $runners_to_spawn runner(s)..."
            for i in $(seq 1 $runners_to_spawn); do
                # Re-check runner count before each spawn (another orchestrator may have spawned)
                local current_runners
                current_runners=$(get_repo_runner_count "$owner_repo" "$label")
                if [ "$current_runners" -ge "$max_count" ]; then
                    echo "  Ceiling reached ($current_runners/$max_count), stopping spawns"
                    break
                fi

                spawn_repo_runner "$owner_repo" "$cpus" "$ram" "$label" || echo "  (continuing despite error)"
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

    for config_key in $orgs; do
        # Parse the config key to extract org name and optional label
        parse_config_key "$config_key"
        local org="$PARSED_NAME"
        local label="$PARSED_LABEL"

        local max_count cpus ram
        max_count=$(jq -r ".orgs[\"${config_key}\"].max_count // 1" "$CONFIG_FILE")
        cpus=$(jq -r ".orgs[\"${config_key}\"].cpus // \"${DEFAULT_CPUS}\"" "$CONFIG_FILE")
        ram=$(jq -r ".orgs[\"${config_key}\"].ram // \"${DEFAULT_RAM}\"" "$CONFIG_FILE")

        local queued_jobs
        queued_jobs=$(get_org_queued_jobs "$org")

        # Check for API error
        if [ "$queued_jobs" -eq -1 ]; then
            echo "[ORG: $config_key] API ERROR - skipping (rate limit or auth failure?)"
            continue
        fi

        # Only check registered runners if there are queued jobs (reduces API calls)
        if [ "$queued_jobs" -gt 0 ]; then
            # Use GitHub API to get runner count (works across multiple orchestrators)
            # Filter by label if one is specified
            local total_runners
            total_runners=$(get_org_runner_count "$org" "$label")

            if [ -n "$label" ]; then
                echo "[ORG: $org:$label] Queued: $queued_jobs, Runners: $total_runners, Max: $max_count"
            else
                echo "[ORG: $org] Queued: $queued_jobs, Runners: $total_runners, Max: $max_count"
            fi
        else
            if [ -n "$label" ]; then
                echo "[ORG: $org:$label] Queued: 0 (idle)"
            else
                echo "[ORG: $org] Queued: 0 (idle)"
            fi
            continue
        fi

        # Calculate how many runners we need to spawn
        # Each queued job needs a runner (ephemeral = one job per runner)
        if [ "$total_runners" -lt "$max_count" ]; then
            local runners_available=$((max_count - total_runners))
            local runners_to_spawn

            # Spawn enough for queued jobs, but don't exceed the ceiling
            if [ "$queued_jobs" -gt "$runners_available" ]; then
                runners_to_spawn=$runners_available
            else
                runners_to_spawn=$queued_jobs
            fi

            echo "  Spawning $runners_to_spawn runner(s)..."
            for i in $(seq 1 $runners_to_spawn); do
                # Re-check runner count before each spawn (another orchestrator may have spawned)
                local current_runners
                current_runners=$(get_org_runner_count "$org" "$label")
                if [ "$current_runners" -ge "$max_count" ]; then
                    echo "  Ceiling reached ($current_runners/$max_count), stopping spawns"
                    break
                fi

                spawn_org_runner "$org" "$cpus" "$ram" "$label" || echo "  (continuing despite error)"
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

    # Show current thread usage if max_threads is set
    if [ "$MAX_THREADS" -gt 0 ]; then
        current_threads=$(get_current_thread_usage)
        echo "Thread usage: $current_threads / $MAX_THREADS"
    fi

    # First, cleanup any exited runners (local containers only)
    cleanup_exited_runners

    # Process repositories (personal repos need individual runners)
    process_repos

    # Process organizations (shared runners across org repos)
    process_orgs

    echo ""
    sleep "$POLL_INTERVAL"
done
