#!/bin/bash

REPO=$REPO
ACCESS_TOKEN=$TOKEN

# Create docker group with host's GID and add runner to it
if [ -e /var/run/docker.sock ]; then
    HOST_DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    sudo groupadd -g $HOST_DOCKER_GID docker
    sudo usermod -aG docker runner
    # Ensure the current shell has the updated group membership
    exec sudo su -l $USER
fi

REG_TOKEN=$(curl -X POST -H "Authorization: token ${ACCESS_TOKEN}" -H "Accept: application/vnd.github+json" https://api.github.com/orgs/Web-Development-UAlberta/actions/runners/registration-token | jq .token --raw-output)

echo "REG TOKEN"
echo ${REG_TOKEN}

cd /home/runner

./config.sh --url https://github.com/Web-Development-UAlberta --token ${REG_TOKEN}

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${REG_TOKEN}
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh &
wait $!
