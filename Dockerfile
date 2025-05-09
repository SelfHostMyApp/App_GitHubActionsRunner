FROM ubuntu:20.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt update -y && apt upgrade -y && apt install curl -y && useradd -m docker && apt install -f -y
ADD --chown=docker:docker download.sh /home/docker/
RUN ./home/docker/download.sh
RUN ./home/docker/actions-runner/bin/installdependencies.sh
RUN chown -R $(id -u docker):$(id -g docker) /home/docker
USER docker
RUN /home/docker/actions-runner/config.sh --url https://github.com/austinleblanc/traefik --token ${GH_ACTIONS_TOKEN}
ENTRYPOINT ["/home/docker/actions-runner/run.sh"]