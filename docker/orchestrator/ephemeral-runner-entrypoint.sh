#!/bin/bash
# ephemeral-runner-entrypoint.sh - Runs a single GitHub Actions job then exits
#
# This script:
# 1. Registers as an ephemeral runner (--ephemeral flag)
# 2. Runs exactly ONE job
# 3. Deregisters and exits
#
# Supports:
# - Repository-level runners (RUNNER_TYPE=repo)
# - Organization-level runners (RUNNER_TYPE=org)
#
# The container should be removed after exit to ensure no cache pollution.

set -e

cd /home/docker/actions-runner

echo "==========================================="
echo "  Ephemeral GitHub Actions Runner"
echo "==========================================="
echo "Runner Type: ${RUNNER_TYPE:-repo}"
echo "Runner Name: ${RUNNER_NAME:-auto}"
echo "Labels: ${RUNNER_LABELS:-default}"

# Determine registration based on runner type
RUNNER_TYPE="${RUNNER_TYPE:-repo}"

if [ "$RUNNER_TYPE" = "org" ]; then
    # Organization-level runner
    if [ -z "$GITHUB_ACTIONS_ORGANIZATION_NAME" ]; then
        echo "ERROR: GITHUB_ACTIONS_ORGANIZATION_NAME is required for org runners"
        exit 1
    fi
    GITHUB_URL="https://github.com/${GITHUB_ACTIONS_ORGANIZATION_NAME}"
    echo "Organization: ${GITHUB_ACTIONS_ORGANIZATION_NAME}"
else
    # Repository-level runner
    if [ -z "$GITHUB_ACTIONS_USER_NAME" ] || [ -z "$GITHUB_ACTIONS_REPOSITORIES" ]; then
        echo "ERROR: GITHUB_ACTIONS_USER_NAME and GITHUB_ACTIONS_REPOSITORIES are required for repo runners"
        exit 1
    fi
    GITHUB_URL="https://github.com/${GITHUB_ACTIONS_USER_NAME}/${GITHUB_ACTIONS_REPOSITORIES}"
    echo "User: ${GITHUB_ACTIONS_USER_NAME}"
    echo "Repo: ${GITHUB_ACTIONS_REPOSITORIES}"
fi

echo "==========================================="

# Use provided runner name or generate one
RUNNER_NAME="${RUNNER_NAME:-ephemeral-$(hostname)-$(date +%s)}"

echo "Configuring ephemeral runner..."
echo "  URL: ${GITHUB_URL}"
echo "  Name: ${RUNNER_NAME}"

# Build label argument
LABEL_ARG=""
if [ -n "$RUNNER_LABELS" ]; then
    LABEL_ARG="--labels ${RUNNER_LABELS}"
fi

# Configure the runner with --ephemeral flag
# This is the key - ephemeral runners:
# - Accept only ONE job
# - Automatically deregister after the job completes
# - Perfect for cache-free execution
./config.sh \
    --url "${GITHUB_URL}" \
    --token "${GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --unattended \
    --ephemeral \
    --disableupdate \
    "${LABEL_ARG}"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to configure the runner"
    exit 1
fi

# Cleanup function for graceful shutdown
cleanup() {
    echo "Cleaning up runner registration..."
    ./config.sh remove --unattended --token "${GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN}" 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM

echo ""
echo "Starting ephemeral runner - will process ONE job then exit..."
echo "Idle timeout: 60 seconds (if no job picked up)"
echo ""

# Start idle timeout watchdog
# If the runner doesn't pick up a job within 3 minutes, kill it
IDLE_TIMEOUT="${RUNNER_IDLE_TIMEOUT:-60}"
(
    sleep "$IDLE_TIMEOUT"
    # Check if we're still in the initial state (no job started)
    # The _diag directory gets Worker_*.log files when a job starts
    if ! ls /home/docker/actions-runner/_diag/Worker_*.log 1>/dev/null 2>&1; then
        echo ""
        echo "TIMEOUT: No job picked up within ${IDLE_TIMEOUT} seconds. Exiting..."
        # Kill the runner process
        pkill -f "Runner.Listener" 2>/dev/null || true
        exit 1
    fi
) &
WATCHDOG_PID=$!

# Run the runner - it will exit after completing one job due to --ephemeral
./run.sh &
RUNNER_PID=$!

# Wait for runner to finish
wait $RUNNER_PID
EXIT_CODE=$?

# Kill watchdog if still running
kill $WATCHDOG_PID 2>/dev/null || true

echo ""
echo "Job completed with exit code: $EXIT_CODE"
echo "Ephemeral runner shutting down..."

# The runner automatically deregisters with --ephemeral, but call cleanup just in case
cleanup

exit "$EXIT_CODE"
