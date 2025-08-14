#!/bin/bash
# runner-controller.sh - Manages ephemeral GitHub Actions runners

# Configuration variables - set these or use environment variables
GITHUB_OWNER=${GITHUB_OWNER:-"YourOrgOrUsername"}
REPO_NAME=${REPO_NAME:-"YourRepo"}
GITHUB_PAT=${GITHUB_PAT:-""}
RUNNER_LABEL=${RUNNER_LABEL:-"ephemeral"}
MAX_RUNNERS=${MAX_RUNNERS:-5}
POLL_INTERVAL=${POLL_INTERVAL:-30}
DOCKER_NETWORK=${DOCKER_NETWORK:-"github-runner-network"}

# Create Docker network if it doesn't exist
docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$DOCKER_NETWORK"

# Function to get the number of queued workflow jobs
get_queued_jobs() {
    curl -s -H "Authorization: token $GITHUB_PAT" \
        "https://api.github.com/repos/$GITHUB_OWNER/$REPO_NAME/actions/runs?status=queued" |
        jq '.total_count'
}

# Function to check active runners
get_active_runners() {
    docker ps --filter "name=ephemeral-runner-" --format "{{.Names}}" | wc -l
}

# Function to generate a unique runner ID
generate_runner_id() {
    echo "ephemeral-runner-$(date +%s)-$(openssl rand -hex 6)"
}

# Function to start a new runner
start_runner() {
    RUNNER_ID=$(generate_runner_id)

    echo "Starting ephemeral runner: $RUNNER_ID"

    # Generate a registration token
    REG_TOKEN=$(curl -s -X POST \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$GITHUB_OWNER/$REPO_NAME/actions/runners/registration-token" |
        jq -r .token)

    # Start the ephemeral runner container
    docker run -d --name "$RUNNER_ID" \
        --privileged \
        --network "$DOCKER_NETWORK" \
        -e GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN="$REG_TOKEN" \
        -e GITHUB_ACTIONS_USER_NAME="$GITHUB_OWNER" \
        -e GITHUB_ACTIONS_REPOSITORIES="$REPO_NAME" \
        -e RUNNER_EPHEMERAL="true" \
        -e RUNNER_LABELS="$RUNNER_LABEL" \
        -v /var/lib/docker \
        your-runner-image:latest
}

echo "GitHub Actions Runner Controller started"
echo "Monitoring for queued jobs in $GITHUB_OWNER/$REPO_NAME"

# Main loop
while true; do
    QUEUED_JOBS=$(get_queued_jobs)
    ACTIVE_RUNNERS=$(get_active_runners)

    echo "$(date): Queued jobs: $QUEUED_JOBS, Active runners: $ACTIVE_RUNNERS"

    # Start new runners if needed
    if [ "$QUEUED_JOBS" -gt "$ACTIVE_RUNNERS" ] && [ "$ACTIVE_RUNNERS" -lt "$MAX_RUNNERS" ]; then
        RUNNERS_TO_START=$((QUEUED_JOBS - ACTIVE_RUNNERS))
        # Don't exceed MAX_RUNNERS
        if [ $((ACTIVE_RUNNERS + RUNNERS_TO_START)) -gt "$MAX_RUNNERS" ]; then
            RUNNERS_TO_START=$((MAX_RUNNERS - ACTIVE_RUNNERS))
        fi

        echo "Starting $RUNNERS_TO_START new runner(s)"
        for i in $(seq 1 $RUNNERS_TO_START); do
            start_runner
        done
    fi

    # Check for completed runners and clean them up
    for CONTAINER in $(docker ps --filter "name=ephemeral-runner-" --filter "status=exited" --format "{{.Names}}"); do
        echo "Cleaning up finished runner: $CONTAINER"
        docker rm "$CONTAINER"
    done

    sleep "$POLL_INTERVAL"
done
