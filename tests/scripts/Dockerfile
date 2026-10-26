# Test host for server scripts: a stock Ubuntu image booted with systemd (ADR-038), with sshd as on any VPS.
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
	&& apt-get install -y --no-install-recommends systemd systemd-sysv openssh-server \
	&& rm -rf /var/lib/apt/lists/*

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
