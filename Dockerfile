FROM ubuntu:20.04
ARG RUNNER_VERSION="2.318.0"
ARG DEBIAN_FRONTEND=noninteractive
ARG REPO
ARG TOKEN
ENV REPO=${REPO}
ENV TOKEN=${TOKEN}

RUN apt-get update && apt-get -y install --no-install-recommends \
    sudo bash curl jq build-essential libssl-dev libffi-dev \
    python3 python3-venv python3-dev python3-pip \
    apt-transport-https ca-certificates gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/* && useradd -m runner
WORKDIR /home/runner
COPY scripts/ /home/runner/scripts/
# Download and extract the runner as the non-root user
RUN echo 'runner:yes' | sudo chpasswd && curl -O -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz && ./bin/installdependencies.sh \
    && chmod +x /home/runner/scripts/start.sh \
    && chown -R runner:runner /home/runner && usermod -aG sudo runner

# Switch to the non-root user
USER runner

ENTRYPOINT ["/home/runner/scripts/start.sh"]