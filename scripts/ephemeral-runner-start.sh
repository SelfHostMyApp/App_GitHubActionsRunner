#!/bin/bash

# ephemeral-start.sh - Configure a GitHub runner, run one job, then exit

cd /home/docker/actions-runner

echo "========== EPHEMERAL RUNNER CONFIG =========="
echo "GITHUB_ACTIONS_USER_NAME: [${GITHUB_ACTIONS_USER_NAME}]"
echo "GITHUB_ACTIONS_REPOSITORIES: [${GITHUB_ACTIONS_REPOSITORIES}]"
echo "RUNNER_EPHEMERAL: [${RUNNER_EPHEMERAL:-false}]"
echo "RUNNER_LABELS: [${RUNNER_LABELS:-default}]"
echo "=============================================="

# Generate a unique runner name with hostname
RUNNER_NAME="ephemeral-$(hostname)-$(date +%s)"
echo "Runner name: ${RUNNER_NAME}"

# Set up runner with provided token
GITHUB_URL="https://github.com/${GITHUB_ACTIONS_USER_NAME}/${GITHUB_ACTIONS_REPOSITORIES}"
echo "Configuring runner for ${GITHUB_URL}"

# Add ephemeral label if specified
LABEL_ARG=""
if [ -n "$RUNNER_LABELS" ]; then
    LABEL_ARG="--labels ${RUNNER_LABELS}"
fi

# Configure the runner
./config.sh --url ${GITHUB_URL} \
    --token ${GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN} \
    --unattended \
    --ephemeral \
    --name "${RUNNER_NAME}" \
    ${LABEL_ARG}

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to configure the runner"
    exit 1
fi

# Trap signals to ensure proper cleanup
cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN}
    exit 0
}

trap cleanup INT TERM

echo "Starting ephemeral runner..."
./run.sh

# Will only reach here after the job completes
echo "Job completed - removing runner..."
cleanup
