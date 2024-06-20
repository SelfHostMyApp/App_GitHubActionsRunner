FROM ubuntu:20.04

ARG RUNNER_VERSION="2.317.0"

ARG DEBIAN_FRONTEND=noninteractive

ARG REPO
ARG TOKEN

ENV REPO=$REPO
ENV TOKEN=$TOKEN

RUN apt-get update && apt-get -y install sudo
RUN apt install -y --no-install-recommends curl jq build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip dotnet-sdk-8.0 aspnetcore-runtime-8.0
RUN curl -sSL https://get.docker.com/ | sudo sh 
RUN useradd -m docker 
RUN rm -rf /var/lib/apt/lists/*
RUN cd /home/docker && mkdir actions-runner && cd actions-runner 
RUN curl -O -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz 
RUN tar xzf ./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz 

RUN sudo chown -R docker ~docker && /home/docker/actions-runner/bin/installdependencies.sh

COPY /scripts/ /home/docker/scripts/

RUN chmod +x /home/docker/scripts/start.sh

USER docker

ENTRYPOINT ["/home/docker/scripts/start.sh"]