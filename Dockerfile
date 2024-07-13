FROM ubuntu:20.04
ARG RUNNER_VERSION="2.317.0"
ARG DEBIAN_FRONTEND=noninteractive
ARG REPO
ARG TOKEN
ENV REPO=$REPO
ENV TOKEN=$TOKEN

RUN apt-get update && apt-get -y install --no-install-recommends \
    sudo bash curl jq build-essential libssl-dev libffi-dev \
    python3 python3-venv python3-dev python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://get.docker.com/ | sh

# Create a non-root user
RUN useradd -m runner

WORKDIR /home/runner

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

# Switch to the non-root user
USER runner

ENTRYPOINT ["/home/runner/scripts/start.sh"]