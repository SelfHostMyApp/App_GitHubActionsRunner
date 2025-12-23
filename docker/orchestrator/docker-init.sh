#!/bin/bash
# docker-init.sh - Container initialization script
# Handles Docker/Podman socket permissions and starts the runner

set -e

# Handle container socket permissions (Docker or Podman)
SOCKET_PATH="/var/run/docker.sock"

if [ -e "$SOCKET_PATH" ]; then
    HOST_SOCKET_GID=$(stat -c "%g" "$SOCKET_PATH")

    # Create group with matching GID if needed
    if ! getent group "$HOST_SOCKET_GID" >/dev/null 2>&1; then
        groupadd -g "$HOST_SOCKET_GID" container-socket 2>/dev/null || true
    fi

    # Add docker user to the group
    usermod -aG "$HOST_SOCKET_GID" docker 2>/dev/null || true

    # Ensure socket is accessible (may fail if read-only, that's ok)
    chmod 666 "$SOCKET_PATH" 2>/dev/null || true
fi

# Switch to docker user and run the entrypoint
exec gosu docker /home/docker/ephemeral-runner-entrypoint.sh
