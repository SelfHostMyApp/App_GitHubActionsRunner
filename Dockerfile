FROM ubuntu:20.04
ARG RUNNER_VERSION="2.317.0"
ARG DEBIAN_FRONTEND=noninteractive
ARG REPO
ARG TOKEN
ENV REPO=${REPO}
ENV TOKEN=${TOKEN}

RUN apt-get update && apt-get -y install --no-install-recommends \
    sudo bash curl jq build-essential libssl-dev libffi-dev \
    python3 python3-venv python3-dev python3-pip \
    apt-transport-https ca-certificates gnupg lsb-release systemctl \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
RUN apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Create a non-root user
RUN useradd -m runner
WORKDIR /home/runner
RUN echo 'runner:yes' | sudo chpasswd

# Download and extract the runner as the non-root user
RUN curl -O -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz

# Install dependencies as root
RUN ./bin/installdependencies.sh

# Copy scripts and set permissions
COPY scripts/ /home/runner/scripts/
RUN chmod +x /home/runner/scripts/start.sh \
    && chown -R runner:runner /home/runner

RUN groupadd -f docker
RUN usermod -aG docker runner
RUN usermod -aG sudo runner

RUN sudo systemctl enable docker.service 
RUN sudo systemctl enable containerd.service 

# Switch to the non-root user
USER runner

ENTRYPOINT ["/home/runner/scripts/start.sh"]