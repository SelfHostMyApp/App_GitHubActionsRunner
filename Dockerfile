FROM ubuntu:20.04
ARG RUNNER_VERSION="2.323.0"
ARG DEBIAN_FRONTEND=noninteractive
ARG REPO
ARG TOKEN
ARG ORG_NAME
ARG USER_NAME
ENV REPO=${REPO}
ENV TOKEN=${TOKEN}
ENV ORG_NAME=${ORG_NAME}
ENV USER_NAME=${USER_NAME}

RUN apt-get update && apt-get -y install --no-install-recommends \
    sudo bash curl jq build-essential libssl-dev libffi-dev \
    python3 python3-venv python3-dev python3-pip \
    apt-transport-https ca-certificates gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && apt-get install -y docker-ce-cli && \
    useradd -m runner
WORKDIR /home/runner
COPY scripts/ /home/runner/scripts/
RUN echo 'runner:yes' | sudo chpasswd && curl -O -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz && ./bin/installdependencies.sh \
    && chmod +x /home/runner/scripts/start.sh \
    && chown -R runner:runner /home/runner && usermod -aG sudo runner && \
    echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    echo "export PATH=$PATH:/usr/bin" >> /etc/bash.bashrc

# Switch to the non-root user
USER runner

ENTRYPOINT ["/home/runner/scripts/start.sh"]