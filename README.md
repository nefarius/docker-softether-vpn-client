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
- Optional split DNS. Names under `SE_DNS_DOMAINS` go to the home DNS servers; every other name keeps the resolver Docker configured for the container.
- Optional fixed adapter MAC address and DHCP hostname, so a home router can reserve an address and publish a name.
- Reports readiness with a Docker health check. The check passes when the VPN session is established, the adapter has an IPv4 address, and, when split DNS is enabled, dnsmasq is forwarding those domains.
- Builds `linux/amd64` and `linux/arm64` from Alpine 3.24.

## Limitations

- One account and one virtual adapter are supported.
- Certificate authentication is unsupported. `SE_TYPE` accepts only `standard` and `radius`.
- Without `SE_DNS_DOMAINS`, DHCP DNS servers are not written to `/etc/resolv.conf`.
- Split DNS forwards to IPv4 home DNS servers. IPv6 addresses in the VPN lease are ignored.
- Split DNS does not change the host resolver. It applies to processes in the VPN container network namespace, including companions started with `network_mode: service:`.
- While split DNS is enabled, dnsmasq binds `127.0.0.1:53` in that namespace. Another DNS server cannot bind the same address.
- Names under `SE_DNS_DOMAINS` fail until the VPN lease provides DNS servers, unless `SE_DNS_SERVERS` is set. Other names continue to use the saved upstream resolvers.
- A restart reuses the upstream resolvers captured the first time split DNS was enabled. Recreate the container after changing Docker's DNS configuration.
- Publishing a container into the home LAN requires a SoftEther hub bridged to that LAN. SecureNAT does not place the client on the LAN.
- Without `SE_MAC_ADDRESS`, dhcpcd keeps identifying the client with a DUID. The adapter MAC is generated again whenever the client profile is recreated, so a DHCP reservation needs the fixed address.
- SoftEther's Linux client does not rewrite the routing table. A route that sends the VPN server itself through the tunnel will black-hole the session.
- The management port is not published. Do not expose it.
- Compose waits for `healthy` only when the stack starts. A tunnel that drops later marks the container `unhealthy` and leaves companion services running. Companions should still retry connections that fail while they are running.
- Kubernetes reads readiness from an exec probe that runs `/usr/local/bin/vpn-ready`. The image health check is a Docker Engine feature.
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
| `SE_DNS_DOMAINS` | no | unset | Comma-separated domains resolved through the home DNS servers, for example `lan,home.arpa,1.168.192.in-addr.arpa`. No spaces. Setting it enables split DNS. |
| `SE_DNS_SERVERS` | no | VPN lease | Comma-separated IPv4 addresses of the home DNS servers. No spaces. When unset, the servers come from DHCP option 6 on the VPN adapter. |
| `SE_DNS_SEARCH` | no | previous search list | Comma-separated search domains written to `/etc/resolv.conf`. No spaces. |
| `SE_MAC_ADDRESS` | no | generated | Locally administered unicast MAC address, with `:` or `-` separators. Multicast and all-zero addresses are rejected. `gen-mac` prints a usable value. |
| `SE_DHCP_HOSTNAME` | no | unset | One DNS label, 1 to 63 characters. Sent as DHCP option 12. |
| `SE_HEALTH_CHECK_TARGET` | no | unset | `host:port` probed through the tunnel before the container is marked healthy. The host is an IPv4 address or a domain name. The port is 1 to 65535. |
| `SE_HEALTH_CHECK_TIMEOUT` | no | `3` | Integer seconds from 0 through 2147483647. `0` disables the `nc` timeout. This image's health check stops the probe after 15 seconds. |

The Linux adapter name is `vpn_` plus the normalized NIC name. The default adapter is `vpn_vpn`.

IPv6 server literals are unsupported. Hub names that contain control characters are rejected.

## Quick start

```shell
docker run --pull=always --name docker-softether-vpn-client \
    --restart unless-stopped \
    --cap-add NET_ADMIN \
    --device /dev/net/tun:/dev/net/tun \
    -e SE_SERVER=vpn.example.net:443 \
    -e SE_HUB=TheHub \
    -e SE_USERNAME=vpnuser \
    -e SE_PASSWORD="${SE_PASSWORD:?Set SE_PASSWORD from your secret store}" \
    -d containinger/docker-softether-vpn-client:latest
```

The examples use `latest`, which tracks the newest stable release. The `docker run` examples pass `--pull=always` so a cached copy is not reused. For production, pin an immutable version tag that includes the features you use; older tags lack options documented here.

### Compose

```yaml
services:
  vpnclient:
    image: containinger/docker-softether-vpn-client:latest
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

`depends_on` with `condition: service_healthy` waits until the health check passes. That form, including `restart: true`, needs Docker Compose 2.17 or newer. `restart: true` restarts the companion when Compose restarts the VPN container, which replaces the shared network namespace. The same `depends_on` block belongs on every companion in the examples below. Inspect a failed check with the VPN container name:

```shell
docker inspect --format '{{json .State.Health}}' guacamole-vpn
```

```yaml
services:
  vpnclient:
    image: containinger/docker-softether-vpn-client:latest
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
      vpnclient:
        condition: service_healthy
        restart: true
    network_mode: service:vpnclient
    volumes:
      - ./config:/config
    restart: unless-stopped
```

### Resolve home LAN names

`SE_DNS_DOMAINS` sends those names to the DNS servers learned from the VPN lease. Include the reverse zone when reverse lookups should take the same path: `1.168.192.in-addr.arpa` is the zone for `192.168.1.0/24`. `SE_DNS_SEARCH` lets a short name such as `ps5-shalltear` resolve as `ps5-shalltear.lan`. Set `SE_DNS_SERVERS` when the lease does not include DNS servers. Queries for every other name still use the resolvers Docker assigned before split DNS was enabled.

```yaml
services:
  vpnclient:
    image: containinger/docker-softether-vpn-client:latest
    container_name: lan-vpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      SE_SERVER: vpn.example.net:443
      SE_HUB: TheHub
      SE_USERNAME: vpnuser
      SE_PASSWORD: ${SE_PASSWORD:?Set SE_PASSWORD from your secret store}
      SE_DNS_DOMAINS: lan,home.arpa,1.168.192.in-addr.arpa
      SE_DNS_SEARCH: lan
    restart: unless-stopped

  app:
    image: alpine:3.24
    container_name: lan-app
    network_mode: service:vpnclient
    depends_on:
      vpnclient:
        condition: service_healthy
        restart: true
    command: ["sleep", "infinity"]
    restart: unless-stopped
```

From `lan-app`, `getent hosts ps5-shalltear.lan` uses the home DNS server. `getent hosts ps5-shalltear` uses it too, because of the search list.

### Publish VPS services to the home LAN

Give the adapter a stable MAC address and a DHCP hostname. The home router can reserve that MAC and register `vps-services.lan` from option 12. Add further names as CNAMEs of that hostname. The service listens on all interfaces in the shared network namespace and does not publish ports on the VPS.

Generate an address and use that output as `SE_MAC_ADDRESS`. Each container on the same LAN needs its own address. The printed value is a locally administered unicast address: the second hexadecimal digit of the first octet is `2`, `6`, `a`, or `e`.

```shell
docker run --pull=always --rm containinger/docker-softether-vpn-client:latest gen-mac
```

From a checkout of this repository, `make mac` prints the same kind of address. The address in the Compose file below is an example. Replace it.

```yaml
services:
  vpnclient:
    image: containinger/docker-softether-vpn-client:latest
    container_name: vps-vpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      SE_SERVER: vpn.example.net:443
      SE_HUB: TheHub
      SE_USERNAME: vpnuser
      SE_PASSWORD: ${SE_PASSWORD:?Set SE_PASSWORD from your secret store}
      SE_MAC_ADDRESS: "02:00:00:00:00:11"
      SE_DHCP_HOSTNAME: vps-services
    restart: unless-stopped

  wiki:
    image: example/wiki:1.0.0
    container_name: vps-wiki
    network_mode: service:vpnclient
    depends_on:
      vpnclient:
        condition: service_healthy
        restart: true
    restart: unless-stopped
```

The SoftEther hub must be bridged to the home LAN. A reservation for `02:00:00:00:00:11` keeps the address stable across `docker compose restart`.

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

Pull requests and pushes to `master` run ShellCheck, Hadolint, and the mocked shell tests. `linux/amd64` is built natively and smoke-tested on `ubuntu-latest`. `linux/arm64` is built natively and smoke-tested on `ubuntu-24.04-arm`.

Pushing a tag that matches `vMAJOR.MINOR.PATCH` publishes the Docker Hub image. Each architecture is built on a native runner, pushed by digest with provenance and an SBOM, then combined into one manifest list. Pre-release suffixes are rejected. Publishing uses the `containinger` account and the `DOCKERHUB_TOKEN` repository secret.

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
- Split DNS: [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html)
- Process supervisor: [Supervisor](http://supervisord.org/)
- Documentation policy: [Nefarius house style](AGENTS.md)
