#!/bin/bash
# ephemeral-runner-entrypoint.sh - Runs a single GitHub Actions job then exits
#
# This script:
# 1. Registers as an ephemeral runner (--ephemeral flag)
# 2. Runs exactly ONE job
# 3. Deregisters and exits
#
# The container should be removed after exit to ensure no cache pollution.

set -e

cd /home/docker/actions-runner

echo "==========================================="
echo "  Ephemeral GitHub Actions Runner"
echo "==========================================="
echo "User: ${GITHUB_ACTIONS_USER_NAME}"
echo "Repo: ${GITHUB_ACTIONS_REPOSITORIES}"
echo "Runner Name: ${RUNNER_NAME:-auto}"
echo "Labels: ${RUNNER_LABELS:-default}"
echo "==========================================="

# Use provided runner name or generate one
RUNNER_NAME="${RUNNER_NAME:-ephemeral-$(hostname)-$(date +%s)}"

# Construct the GitHub URL
GITHUB_URL="https://github.com/${GITHUB_ACTIONS_USER_NAME}/${GITHUB_ACTIONS_REPOSITORIES}"

echo "Configuring ephemeral runner for: ${GITHUB_URL}"

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
    ${LABEL_ARG}

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to configure the runner"
    exit 1
fi

# Cleanup function for graceful shutdown
cleanup() {
    echo "Cleaning up runner registration..."
    ./config.sh remove --unattended --token "${GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN}" || true
    exit 0
}

trap cleanup INT TERM

echo "Starting ephemeral runner - will process ONE job then exit..."
echo ""

# Run the runner - it will exit after completing one job due to --ephemeral
./run.sh

EXIT_CODE=$?

echo ""
echo "Job completed with exit code: $EXIT_CODE"
echo "Ephemeral runner shutting down..."

# The runner automatically deregisters with --ephemeral, but call cleanup just in case
cleanup

exit $EXIT_CODE
