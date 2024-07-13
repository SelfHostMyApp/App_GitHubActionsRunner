#!/bin/bash

REPO=$REPO
ACCESS_TOKEN=$TOKEN

REG_TOKEN=$(curl -X POST -H "Authorization: token ${ACCESS_TOKEN}" -H "Accept: application/vnd.github+json" https://api.github.com/orgs/Web-Development-UAlberta/actions/runners/registration-token | jq .token --raw-output)

echo "REG TOKEN"
echo ${REG_TOKEN}

cd /app/actions-runner

./config.sh --url https://github.com/Web-Development-UAlberta --token ${REG_TOKEN}

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${REG_TOKEN}
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh &
wait $!
