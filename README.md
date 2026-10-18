# docker-softether-vpn-client

Alpine Linux container that connects to one SoftEther VPN server and exposes that network to other containers.

[![CI](https://github.com/nefarius/docker-softether-vpn-client/actions/workflows/ci.yml/badge.svg)](https://github.com/nefarius/docker-softether-vpn-client/actions/workflows/ci.yml)
[![Docker Hub](https://img.shields.io/docker/v/containinger/docker-softether-vpn-client?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/containinger/docker-softether-vpn-client/tags)

## About

The container builds [SoftEther VPN Client 4.44 Build 9807 RTM](https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/tag/v4.44-9807-rtm) and configures one password-authenticated account at startup. It creates a `vpn_<name>` TAP adapter, requests an address with `dhcpcd`, and leaves that network namespace available to companion containers.

Published images are `containinger/docker-softether-vpn-client`. A stable tag `vMAJOR.MINOR.PATCH` publishes the immutable tag `MAJOR.MINOR.PATCH`. The moving tags `MAJOR.MINOR`, `MAJOR`, and `latest` are updated only when that release is the newest stable release in the corresponding series. The image currently on Docker Hub predates this build; use a SemVer tag published from this repository after its first release.

## Features

- Connects to one hub with `SE_SERVER`, `SE_HUB`, `SE_USERNAME`, and `SE_PASSWORD`.
- Recreates the client profile on every start, so changed credentials take effect after a restart.
- Marks the account for automatic connection.
- Runs the client and DHCP client under Supervisor, with both logging to container stdout.
- Builds `linux/amd64` and `linux/arm64` from Alpine 3.24.

## Limitations

- One account and one virtual adapter are supported.
- Certificate authentication is unsupported. `SE_TYPE` accepts only `standard` and `radius`.
- DHCP responses do not replace `/etc/resolv.conf`. VPN DNS servers are not applied automatically.
- SoftEther's Linux client does not rewrite the routing table. A route that sends the VPN server itself through the tunnel will black-hole the session.
- The management port is not published. Do not expose it.
- There is no image health check. A running Supervisor process does not prove that the VPN session is up.
- CI does not connect to a live VPN server.

## Supported systems

| Component | Supported |
| --- | --- |
| Host | Linux with Docker Engine 25.0 or newer and `/dev/net/tun` |
| Image OS | Alpine Linux 3.24 |
| Image architecture | `linux/amd64`, `linux/arm64` |
| SoftEther client | 4.44 Build 9807 RTM (`v4.44-9807-rtm`, commit `ed17437af9719ac66acab30faa29e375d613c35f`) |
| Docker mode | Rooted Docker Engine. Rootless Docker is unsupported |
| Docker Desktop | Unsupported |

The container runs as root. Creating the TAP adapter and configuring its address requires `CAP_NET_ADMIN` and `/dev/net/tun`. `--privileged` is not required and is not part of the supported configuration. `CAP_NET_ADMIN` still lets the container change its own network configuration; treat the container as privileged networking code.

## Configuration

| Variable | Required | Default | Accepted values |
| --- | --- | --- | --- |
| `SE_SERVER` | yes | none | Hostname or IPv4 address, with an optional `:port`. No spaces. |
| `SE_HUB` | yes | none | Hub name. Spaces are preserved. No control characters. |
| `SE_USERNAME` | yes | none | Username. No control characters. |
| `SE_PASSWORD` | yes | none | Password. No control characters. Visible to `docker inspect` and the process environment. |
| `SE_ACCOUNT_NAME` | no | `default` | Profile name. No control characters. |
| `SE_NICNAME` | no | `vpn` | Letters, digits, `_`, and `-`. At most 11 characters. Normalized to lowercase. |
| `SE_TYPE` | no | `standard` | `standard` or `radius`. |

The Linux adapter name is `vpn_` plus the normalized NIC name. The default adapter is `vpn_vpn`.

IPv6 server literals are unsupported. Hub names that contain control characters are rejected.

## Quick start

```shell
docker run --name docker-softether-vpn-client \
    --restart unless-stopped \
    --cap-add NET_ADMIN \
    --device /dev/net/tun:/dev/net/tun \
    -e SE_SERVER=vpn.example.net:443 \
    -e SE_HUB=TheHub \
    -e SE_USERNAME=vpnuser \
    -e SE_PASSWORD="${SE_PASSWORD:?Set SE_PASSWORD from your secret store}" \
    -d containinger/docker-softether-vpn-client:1.0.0
```

Replace `1.0.0` with the immutable tag you intend to run. `latest` moves only for the newest stable release.

### Compose

```yaml
services:
  vpnclient:
    image: containinger/docker-softether-vpn-client:1.0.0
    container_name: docker-softether-vpn-client
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      SE_SERVER: vpn.example.net:443
      SE_HUB: TheHub
      SE_USERNAME: vpnuser
      SE_PASSWORD: ${SE_PASSWORD:?Set SE_PASSWORD from your secret store}
    restart: unless-stopped
```

### Companion container

This Compose file runs Apache Guacamole in the VPN container's network namespace. Publish application ports on the VPN service. The Guacamole image and its configuration are outside the support scope of this repository.

```yaml
services:
  vpnclient:
    image: containinger/docker-softether-vpn-client:1.0.0
    container_name: guacamole-vpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      SE_SERVER: vpn.example.net:443
      SE_HUB: TheHub
      SE_USERNAME: vpnuser
      SE_PASSWORD: ${SE_PASSWORD:?Set SE_PASSWORD from your secret store}
    ports:
      - "8080:8080"
    restart: unless-stopped

  guacamole:
    image: oznu/guacamole
    container_name: guacamole-app
    depends_on:
      - vpnclient
    network_mode: service:vpnclient
    volumes:
      - ./config:/config
    restart: unless-stopped
```

## Build and validation

Prerequisites:

- Docker Engine 25.0 or newer, with BuildKit enabled
- Docker Buildx 0.13 or newer for the multi-architecture command below
- GNU Make 4.3 or newer
- Git 2.40 or newer, used by the release workflow when comparing tags

`make lint` runs ShellCheck 0.10.0 and Hadolint 2.15.1 from their container images.

Local checks:

```shell
git clone https://github.com/nefarius/docker-softether-vpn-client.git
cd docker-softether-vpn-client
make lint
make test
make build
make smoke
```

`make check` runs `make lint` and `make test`. `make build` creates `docker-softether-vpn-client:local` for the host architecture. `make smoke` checks that image; it does not open a VPN session.

Multi-architecture build, without loading both images into the local Docker engine:

```shell
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --tag docker-softether-vpn-client:local \
    .
```

The image build clones SoftEther tag `v4.44-9807-rtm` and checks that the checkout is commit `ed17437af9719ac66acab30faa29e375d613c35f`.

## Continuous integration

Pull requests and pushes to `master` run ShellCheck, Hadolint, the mocked shell tests, and a Buildx build for `linux/amd64` and `linux/arm64`. The amd64 image is then smoke-tested.

Pushing a tag that matches `vMAJOR.MINOR.PATCH` publishes the Docker Hub image for both architectures, including provenance and an SBOM. Pre-release suffixes are rejected. Publishing uses the `containinger` account and the `DOCKERHUB_TOKEN` repository secret.

Dependabot opens weekly pull requests for Dockerfile base-image updates and GitHub Actions updates.

## Support policy

The issue tracker is for defects and concrete changes in this image. Read this README before opening an issue. A useful report includes the image tag, host architecture, Docker Engine version, and redacted container logs.

Issues that ask for SoftEther server administration, account provisioning, routing design, or an unsupported host configuration may be closed. This repository does not provide a general VPN help desk.

## Licensing and legal

The packaging in this repository is released under the MIT License. Copyright (c) 2017 Antoine Mary. See [LICENSE](LICENSE).

SoftEther VPN is developed by the SoftEther VPN Project at the University of Tsukuba and is distributed under the Apache License 2.0. SoftEther names and marks belong to their respective owners. This repository is an independent packaging project and is not affiliated with the SoftEther VPN Project.

`SE_PASSWORD` and the other connection settings are container environment variables. They are available to anyone who can inspect the container.

## Sources and credits

- Original container: Antoine Mary, with contributions from Dimitri G.
- Upstream client: [SoftEtherVPN/SoftEtherVPN_Stable v4.44-9807-rtm](https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/tag/v4.44-9807-rtm)
- Base system: [Alpine Linux 3.24](https://alpinelinux.org/releases/)
- DHCP client: [dhcpcd](https://roy.marples.name/projects/dhcpcd)
- Process supervisor: [Supervisor](http://supervisord.org/)
- Documentation policy: [Nefarius house style](AGENTS.md)
