#!/bin/sh

# launch-runners.sh - Launch GitHub Actions runners based on count.json

# ==================== CONFIGURATION ====================
CONTAINER_CPU_COUNT="4"           # Number of CPUs per container
CONTAINER_MEMORY="4g"             # Memory limit per container (e.g., "2g", "512m")
IMAGE_NAME="github-actions-runner-dind:latest"
NETWORK_NAME="github-runners"
GITHUB_ACTIONS_USER_NAME="JamesonRGrieve"
# =======================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COUNT_FILE="$SCRIPT_DIR/count.json"
ENV_FILE="$SCRIPT_DIR/scripts/.env"

# Parse command line arguments
RECREATE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --recreate)
            RECREATE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--recreate]"
            exit 1
            ;;
    esac
done

# Check if count.json exists
if [ ! -f "$COUNT_FILE" ]; then
    echo "ERROR: count.json not found at $COUNT_FILE"
    exit 1
fi

# Check if .env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed"
    exit 1
fi

# Check if docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required but not installed"
    exit 1
fi

# Extract variables from .env file
GITHUB_ACTIONS_ACTIONS_PAT=$(grep "^GITHUB_ACTIONS_ACTIONS_PAT=" "$ENV_FILE" | cut -d'=' -f2)
GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN=$(grep "^GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN=" "$ENV_FILE" | cut -d'=' -f2)

echo "========== GITHUB ACTIONS RUNNER LAUNCHER =========="
echo "Repository counts from: $COUNT_FILE"
echo "GitHub user: $GITHUB_ACTIONS_USER_NAME"
echo "Container resources: ${CONTAINER_CPU_COUNT} CPUs, ${CONTAINER_MEMORY} RAM"
echo "Recreate mode: $RECREATE"
echo "====================================================="

# Validate required environment variables
if [ -z "$GITHUB_ACTIONS_USER_NAME" ] || [ -z "$GITHUB_ACTIONS_ACTIONS_PAT" ]; then
    echo "ERROR: Required environment variables not set:"
    echo "GITHUB_ACTIONS_USER_NAME: [${GITHUB_ACTIONS_USER_NAME:-NOT SET}]"
    echo "GITHUB_ACTIONS_ACTIONS_PAT: [${GITHUB_ACTIONS_ACTIONS_PAT:-NOT SET}]"
    exit 1
fi

# Create Docker network if it doesn't exist
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "Creating Docker network: $NETWORK_NAME"
    docker network create "$NETWORK_NAME"
fi

# Function to destroy a container
destroy_container() {
    local container_name="$1"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Destroying container: $container_name"
        docker stop "$container_name" >/dev/null 2>&1
        docker rm "$container_name" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "✓ Destroyed $container_name"
            return 0
        else
            echo "✗ Failed to destroy $container_name"
            return 1
        fi
    fi
    return 0
}

# Function to start a runner container
start_runner() {
    local repo="$1"
    local instance="$2"

    # Convert repo name to valid container name format
    local repo_name=$(echo "$repo" | sed 's/.*\///g' | tr '[:upper:]' '[:lower:]')
    local container_name="gh-actions-${repo_name}-${instance}"
    local runner_name="runner-${repo}-${instance}"

    # Check if container already exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        if [ "$RECREATE" = true ]; then
            destroy_container "$container_name"
        else
            echo "✓ Container $container_name already exists (use --recreate to replace)"
            return 0
        fi
    fi

    echo "Starting container: $container_name"

    # Start the container with environment variables and resource limits
    docker run -d \
        --name "$container_name" \
        --network "$NETWORK_NAME" \
        --privileged \
        --cpus="$CONTAINER_CPU_COUNT" \
        --memory="$CONTAINER_MEMORY" \
        -e "GITHUB_ACTIONS_USER_NAME=$GITHUB_ACTIONS_USER_NAME" \
        -e "GITHUB_ACTIONS_ACTIONS_PAT=$GITHUB_ACTIONS_ACTIONS_PAT" \
        -e "GITHUB_ACTIONS_REPOSITORIES=$repo_name" \
        -e "GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN=$GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN" \
        -e "GITHUB_ACTIONS_ORGANIZATION_NAME=" \
        -e "RUNNER_LABELS=${repo}-runner,instance-${instance}" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "$IMAGE_NAME"

    if [ $? -eq 0 ]; then
        echo "✓ Started $container_name"
        return 0
    else
        echo "✗ Failed to start $container_name"
        return 1
    fi
}

# Read count.json and process each repository
echo "Processing repositories from count.json..."
echo ""

# Get all repository entries from count.json
repositories=$(jq -r 'to_entries[] | "\(.key) \(.value)"' "$COUNT_FILE")

total_containers=0
successful_containers=0

echo "$repositories" | while read -r line; do
    repo=$(echo "$line" | cut -d' ' -f1)
    count=$(echo "$line" | cut -d' ' -f2 | tr -d '\r\n')
    echo "----------------------------------------"
    echo "Repository: $repo"
    echo "Instances to create: $count"
    echo "----------------------------------------"

    # Validate count is a number
    if ! [ "$count" -eq "$count" ] 2>/dev/null; then
        echo "ERROR: Invalid count '$count' for repository $repo"
        continue
    fi

    # Start the specified number of containers for this repo
    i=1
    while [ $i -le "$count" ]; do
        start_runner "$repo" "$i"
        if [ $? -eq 0 ]; then
            successful_containers=$((successful_containers + 1))
        fi
        total_containers=$((total_containers + 1))
        i=$((i + 1))
    done

    echo ""
done

echo "========== LAUNCH SUMMARY =========="
echo "Total containers attempted: $total_containers"
echo "Successful containers: $successful_containers"
echo "Failed containers: $((total_containers - successful_containers))"
echo "====================================="

# Show running containers
echo ""
echo "Currently running GitHub Actions containers:"
docker ps --filter "name=gh-actions-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"