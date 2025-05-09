FROM ubuntu:20.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt update -y && apt upgrade -y && apt install curl -y && useradd -m docker && apt install -f -y
ADD --chown=docker:docker scripts/download.sh /home/docker/
RUN ./home/docker/download.sh
RUN ./home/docker/actions-runner/bin/installdependencies.sh
ADD --chown=docker:docker scripts/start.sh /home/docker/
RUN chown -R $(id -u docker):$(id -g docker) /home/docker
USER docker
ENTRYPOINT ["/home/docker/start.sh"]