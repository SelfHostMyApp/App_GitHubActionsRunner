#!/bin/bash

# Error checking for environment variables
if [[ -n "$GH_ORG_NAME" && -n "$GH_USER_NAME" ]]; then
    echo "ERROR: Both GH_ORG_NAME and GH_USER_NAME are set. Please set only one."
    exit 1
fi

if [[ -z "$GH_ORG_NAME" && -z "$GH_USER_NAME" ]]; then
    echo "ERROR: Neither GH_ORG_NAME nor GH_USER_NAME is set. Please set one."
    exit 1
fi

# Create docker group with host's GID and add runner to it
if [ -e /var/run/docker.sock ]; then
    HOST_DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    sudo groupadd -g $HOST_DOCKER_GID docker
    sudo usermod -aG docker runner
    # Ensure the current shell has the updated group membership
fi

# Set up the correct URL and token endpoint based on whether we're using org or user
if [ -n "$GH_ORG_NAME" ]; then
    # Organization runner setup
    GITHUB_URL="https://github.com/${GH_ORG_NAME}"
    TOKEN_URL="https://api.github.com/orgs/${GH_ORG_NAME}/actions/runners/registration-token"
    REG_TOKEN=$(curl -X POST -H "Authorization: token ${GH_ACTIONS_TOKEN}" -H "Accept: application/vnd.github+json" ${TOKEN_URL} | jq .token --raw-output)
else
    # User repository runner setup
    if [ -z "$GH_REPO" ]; then
        echo "ERROR: GH_REPO must be set when using GH_USER_NAME"
        exit 1
    fi
    GITHUB_URL="https://github.com/${GH_USER_NAME}/${GH_REPO}"
    TOKEN_URL="https://api.github.com/repos/${GH_USER_NAME}/${GH_REPO}/actions/runners/registration-token"
    REG_TOKEN=$GH_ACTIONS_TOKEN
fi

echo "REG TOKEN"
echo ${REG_TOKEN}

cd /home/docker/actions-runner

./config.sh --url ${GITHUB_URL} --token ${REG_TOKEN}

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${REG_TOKEN}
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh &
wait $!
