#!/bin/bash

echo "========== ENVIRONMENT VARIABLE DEBUG =========="
echo "GITHUB_ACTIONS_USER_NAME: [${GITHUB_ACTIONS_USER_NAME}]"
echo "GITHUB_ACTIONS_REPOSITORIES: [${GITHUB_ACTIONS_REPOSITORIES}]"
echo "GITHUB_ACTIONS_ACTIONS_PAT: [${GITHUB_ACTIONS_ACTIONS_PAT:-NOT SET}]"
echo "GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN: [${GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN:-NOT SET}]"
echo "GITHUB_ACTIONS_ORGANIZATION_NAME: [${GITHUB_ACTIONS_ORGANIZATION_NAME:-NOT SET}]"
echo "=============================================="

# Determine which mode to use
MODE=""

if [ -n "$GITHUB_ACTIONS_USER_NAME" ] && [ -n "$GITHUB_ACTIONS_ACTIONS_PAT" ] && [ -n "$GITHUB_ACTIONS_REPOSITORIES" ]; then
    echo "DETECTED: User-wide runner configuration with repositories: ${GITHUB_ACTIONS_REPOSITORIES}"
    MODE="multi-repo"
elif [ -n "$GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN" ] && [ -n "$GITHUB_ACTIONS_USER_NAME" ] && [ -n "$GITHUB_ACTIONS_REPOSITORIES" ]; then
    echo "DETECTED: Single repository runner configuration"
    MODE="single-repo"
elif [ -n "$GITHUB_ACTIONS_ORGANIZATION_NAME" ] && [ -n "$GITHUB_ACTIONS_ACTIONS_PAT" ]; then
    echo "DETECTED: Organization-wide runner configuration"
    MODE="org-wide"
else
    echo "ERROR: Invalid environment variable configuration."
    echo "Please use one of the following configurations:"
    echo "1. Single repository runner: GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN, GITHUB_ACTIONS_USER_NAME, GITHUB_ACTIONS_REPOSITORIES"
    echo "2. User-wide runner: GITHUB_ACTIONS_USER_NAME, GITHUB_ACTIONS_ACTIONS_PAT, GITHUB_ACTIONS_REPOSITORIES (comma-separated)"
    echo "3. Organization-wide runner: GITHUB_ACTIONS_ORGANIZATION_NAME, GITHUB_ACTIONS_ACTIONS_PAT"
    exit 1
fi

echo "Selected mode: ${MODE}"

# Configure Docker group if needed
if [ -e /var/run/docker.sock ]; then
    HOST_DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    echo "Creating docker group with GID: ${HOST_DOCKER_GID}"
    groupadd -g $HOST_DOCKER_GID docker || echo "Group already exists or cannot be created"

    if id -u runner >/dev/null 2>&1; then
        usermod -aG docker runner
    else
        echo "User 'runner' does not exist, skipping group assignment"
    fi
fi

cd /home/docker/actions-runner

# Show GitHub Runner version
echo "GitHub Runner version: $(./config.sh --version || echo "Could not determine runner version")"

# Simplified token extraction
extract_token_from_json() {
    # Direct extraction based on known format: {"token":"ABCDEF","expires_at":"..."}
    # This was working in previous versions
    echo "$1" | tr -d '\n' | tr -d ' ' | sed 's/.*"token":"//g' | sed 's/".*//g'
}

if [ "$MODE" = "single-repo" ]; then
    # Already have the token, use it directly
    GITHUB_URL="https://github.com/${GITHUB_ACTIONS_USER_NAME}/${GITHUB_ACTIONS_REPOSITORIES}"

    echo "Configuring single repository runner for ${GITHUB_URL}"
    ./config.sh --url ${GITHUB_URL} --token ${GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN} --unattended --name "single-repo-runner"

    cleanup() {
        echo "Removing runner..."
        ./config.sh remove --unattended --token ${GITHUB_ACTIONS_RUNNER_REGISTRATION_TOKEN}
    }

elif [ "$MODE" = "multi-repo" ]; then
    # Convert comma-separated list to array
    IFS=',' read -ra REPOS <<<"$GITHUB_ACTIONS_REPOSITORIES"
    echo "Configuring runner for ${#REPOS[@]} repositories:"

    for repo in "${REPOS[@]}"; do
        echo "- $repo"
    done

    # Track if we successfully configured at least one repository
    SUCCESS=false

    for repo in "${REPOS[@]}"; do
        GITHUB_URL="https://github.com/${GITHUB_ACTIONS_USER_NAME}/${repo}"
        TOKEN_URL="https://api.github.com/repos/${GITHUB_ACTIONS_USER_NAME}/${repo}/actions/runners/registration-token"

        echo "Fetching registration token for ${repo}..."
        echo "Using URL: ${TOKEN_URL}"

        # Exactly match the docs - use the correct API version and bearer auth
        JSON_RESPONSE=$(curl -s -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_ACTIONS_ACTIONS_PAT}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            ${TOKEN_URL})

        echo "API Response: ${JSON_RESPONSE}"

        # Extract the token
        REG_TOKEN=$(extract_token_from_json "$JSON_RESPONSE")

        if [ -z "$REG_TOKEN" ]; then
            echo "ERROR: Failed to get registration token for ${repo}"
            continue
        fi

        echo "Successfully obtained token: ${REG_TOKEN}"
        echo "Configuring runner for ${repo}..."

        # Add repo name as a label
        REPO_LABEL="${repo}-runner"
        LABEL_ARG="--labels ${REPO_LABEL}"

        # Add custom labels if provided
        if [ -n "$RUNNER_LABELS" ]; then
            LABEL_ARG="${LABEL_ARG},${RUNNER_LABELS}"
        fi

        # Configure the runner
        echo "Running config.sh with: --url ${GITHUB_URL} --token [REDACTED] --unattended --name multi-repo-runner --replace ${LABEL_ARG}"
        ./config.sh --url ${GITHUB_URL} --token ${REG_TOKEN} --unattended --name "multi-repo-runner" --replace ${LABEL_ARG}

        if [ $? -eq 0 ]; then
            echo "Runner successfully configured for ${repo}"
            SUCCESS=true
            break # Successfully configured one repo, no need to try others
        else
            echo "Failed to configure runner for ${repo}"
        fi
    done

    if [ "$SUCCESS" = false ]; then
        echo "ERROR: Failed to configure runner for any repository"
        exit 1
    fi

    cleanup() {
        echo "Cleanup function called for multi-repo runner"
    }

elif [ "$MODE" = "org-wide" ]; then
    # Organization runner setup
    GITHUB_URL="https://github.com/${GITHUB_ACTIONS_ORGANIZATION_NAME}"
    TOKEN_URL="https://api.github.com/orgs/${GITHUB_ACTIONS_ORGANIZATION_NAME}/actions/runners/registration-token"

    echo "Fetching registration token for organization ${GITHUB_ACTIONS_ORGANIZATION_NAME}..."
    echo "Using URL: ${TOKEN_URL}"

    # Exactly match the docs - use the correct API version and bearer auth
    JSON_RESPONSE=$(curl -s -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_ACTIONS_ACTIONS_PAT}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        ${TOKEN_URL})

    echo "API Response: ${JSON_RESPONSE}"

    # Extract the token
    REG_TOKEN=$(extract_token_from_json "$JSON_RESPONSE")

    if [ -z "$REG_TOKEN" ]; then
        echo "ERROR: Failed to get registration token for organization"
        exit 1
    fi

    echo "Successfully obtained token: ${REG_TOKEN}"
    echo "Configuring organization runner for ${GITHUB_URL}"

    # Configure the runner
    ./config.sh --url ${GITHUB_URL} --token ${REG_TOKEN} --unattended --name "org-runner"

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to configure organization runner"
        exit 1
    fi

    cleanup() {
        echo "Removing runner..."
        ./config.sh remove --unattended --token ${REG_TOKEN}
    }
fi

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

echo "Starting runner..."
./run.sh &
wait $!
