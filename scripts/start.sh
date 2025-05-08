#!/bin/bash

REPO=$REPO
ACCESS_TOKEN=$TOKEN
ORG_NAME=$ORG_NAME
USER_NAME=$USER_NAME

# Error checking for environment variables
if [[ -n "$ORG_NAME" && -n "$USER_NAME" ]]; then
    echo "ERROR: Both ORG_NAME and USER_NAME are set. Please set only one."
    exit 1
fi

if [[ -z "$ORG_NAME" && -z "$USER_NAME" ]]; then
    echo "ERROR: Neither ORG_NAME nor USER_NAME is set. Please set one."
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
if [ -n "$ORG_NAME" ]; then
    # Organization runner setup
    GITHUB_URL="https://github.com/${ORG_NAME}"
    TOKEN_URL="https://api.github.com/orgs/${ORG_NAME}/actions/runners/registration-token"
else
    # User repository runner setup
    if [ -z "$REPO" ]; then
        echo "ERROR: REPO must be set when using USER_NAME"
        exit 1
    fi
    GITHUB_URL="https://github.com/${USER_NAME}/${REPO}"
    TOKEN_URL="https://api.github.com/repos/${USER_NAME}/${REPO}/actions/runners/registration-token"
fi

REG_TOKEN=$(curl -X POST -H "Authorization: token ${ACCESS_TOKEN}" -H "Accept: application/vnd.github+json" ${TOKEN_URL} | jq .token --raw-output)

echo "REG TOKEN"
echo ${REG_TOKEN}

cd /home/runner

./config.sh --url ${GITHUB_URL} --token ${REG_TOKEN}

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${REG_TOKEN}
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh &
wait $!
