FROM ubuntu:20.04
ARG DEBIAN_FRONTEND=noninteractive

# Install required packages including Docker CLI
RUN apt update -y && apt upgrade -y && \
    apt install -y curl git gosu apt-transport-https ca-certificates gnupg lsb-release

# Set up Docker repository and install Docker CLI
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt update -y && \
    apt install -y docker-ce-cli

# Create a docker user for running the actions
RUN useradd -m docker

# Copy download script and ensure it has proper permissions
COPY scripts/download.sh /home/docker/
RUN chmod +x /home/docker/download.sh && \
    bash /home/docker/download.sh && \
    chown -R docker:docker /home/docker

# Install runner dependencies
RUN /home/docker/actions-runner/bin/installdependencies.sh

# Add start script with correct permissions
COPY scripts/start.sh /home/docker/
RUN chmod +x /home/docker/start.sh && \
    chown docker:docker /home/docker/start.sh

# Ensure the docker user owns ALL runner files
RUN chown -R docker:docker /home/docker/actions-runner

# Create a robust initialization script to fix docker socket permissions
RUN echo '#!/bin/bash\n\
    set -e\n\
    \n\
    echo "=== Docker Socket Permission Debugging ==="\n\
    \n\
    if [ -e /var/run/docker.sock ]; then\n\
    echo "Docker socket exists at /var/run/docker.sock"\n\
    ls -la /var/run/docker.sock\n\
    \n\
    HOST_DOCKER_GID=$(stat -c "%g" /var/run/docker.sock)\n\
    echo "Host Docker socket GID: ${HOST_DOCKER_GID}"\n\
    \n\
    # Create docker group with correct GID\n\
    if getent group ${HOST_DOCKER_GID} > /dev/null 2>&1; then\n\
    echo "Group with GID ${HOST_DOCKER_GID} already exists, removing it"\n\
    groupdel $(getent group ${HOST_DOCKER_GID} | cut -d: -f1) || echo "Could not remove group"\n\
    fi\n\
    \n\
    echo "Creating docker-access group with GID ${HOST_DOCKER_GID}"\n\
    groupadd -g ${HOST_DOCKER_GID} docker-access || echo "Failed to create group"\n\
    \n\
    echo "Adding docker user to docker-access group"\n\
    usermod -aG docker-access docker || echo "Failed to add user to group"\n\
    \n\
    # Verify group membership\n\
    echo "Verifying group membership:"\n\
    id docker\n\
    \n\
    # Fix permissions on the socket to be sure\n\
    echo "Ensuring socket is group-writable"\n\
    chmod 666 /var/run/docker.sock || echo "Could not change socket permissions"\n\
    \n\
    echo "Socket permissions after change:"\n\
    ls -la /var/run/docker.sock\n\
    \n\
    echo "Docker CLI version:"\n\
    docker --version || echo "Docker CLI not working"\n\
    \n\
    echo "Testing docker command access:"\n\
    gosu docker docker version > /dev/null 2>&1 && echo "Success: Docker CLI working" || echo "Failure: Docker CLI not working"\n\
    else\n\
    echo "Docker socket not found at /var/run/docker.sock"\n\
    fi\n\
    \n\
    echo "=== End Docker Socket Debugging ==="\n\
    \n\
    # Switch to the docker user and execute the original command\n\
    echo "Switching to docker user and executing: $@"\n\
    exec gosu docker "$@"' > /docker-init.sh && \
    chmod +x /docker-init.sh

# Use the init script as entrypoint
ENTRYPOINT ["/docker-init.sh", "/home/docker/start.sh"]