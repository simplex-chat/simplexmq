# SimpleX Routers — Deployment and Configuration

SimpleX routers are the network infrastructure of the [SimpleX Network](../protocol/overview-tjr.md). They accept, buffer, and deliver data packets between endpoints. Each router operates independently and can be run by any party on standard computing hardware.

This document covers deployment and advanced configuration. For an overview of the router architecture and trust model, see the [SimpleX Network overview](../protocol/overview-tjr.md). For internal architecture diagrams (thread topology, command processing flows), see [`spec/routers.md`](../spec/routers.md).

## SMP Router

The SMP router provides messaging queues — unidirectional, ordered sequences of fixed-size packets (16,384 bytes each). It implements the [SimpleX Messaging Protocol](../protocol/simplex-messaging.md). For architecture and module specs, see [SMP Router](../spec/routers.md#smp-router).

### Advanced configuration

`smp-server.ini` is created during initialization and controls all runtime behavior.

**Message persistence**: when store log is enabled (`enable: on`), the server saves undelivered messages on exit and restores them on start. This only works with SIGINT (keyboard interrupt); SIGTERM does not trigger message saving. The `restore_messages` setting can be used to override this behavior independently of the store log setting.

**Tor onion addresses**: the server can have both a public hostname and an onion hostname, allowing two users to connect when only one is using Tor. Configure as: `smp://<fingerprint>@<public_hostname>,<onion_hostname>`. See [`scripts/tor/`](../scripts/tor/) for setup instructions.

### Running on MacOS

SMP server requires OpenSSL for initialization. MacOS may ship LibreSSL instead, which doesn't support the required algorithms.

```sh
openssl version
```

If it says "LibreSSL", install OpenSSL:

```sh
brew update
brew install openssl
echo 'PATH="/opt/homebrew/opt/openssl@3/bin:$PATH"' >> ~/.zprofile
. ~/.zprofile
```

## XFTP Router

The XFTP router accepts and delivers data packets over HTTP/2 — individually addressed blocks in fixed sizes (64KB, 256KB, 1MB, 4MB). It implements the [XFTP protocol](../protocol/xftp.md). Data packets are used for larger payload delivery (files, media) where SMP queue packet sizes would be inefficient. The use of HTTP/2 simplifies browser integration. For architecture and module specs, see [XFTP Router](../spec/routers.md#xftp-router).

Initialize with `xftp-server init` and configure storage quota in `xftp-server.ini`.

## NTF Router

The NTF router bridges SimpleX Network to platform push notification services (APNS). It implements the [Push Notifications protocol](../protocol/push-notifications.md). Mobile clients register push tokens with the NTF router, which subscribes to their SMP queues and sends push notifications when messages arrive. The push notification contains only a notification ID, not message content. For architecture and module specs, see [NTF Router](../spec/routers.md#ntf-router).

Initialize with `ntf-server init` and configure APNS credentials in `ntf-server.ini`.

## Deployment methods

All routers require `openssl` as a runtime dependency for certificate generation during initialization:

```sh
# Ubuntu
apt update && apt install openssl
```

### Docker (prebuilt images)

Prebuilt images are available from [Docker Hub](https://hub.docker.com/r/simplexchat).

1. Create directories for persistent configuration:

   ```sh
   mkdir -p $HOME/simplex/{xftp,smp}/{config,logs} && mkdir -p $HOME/simplex/xftp/files
   ```

2. Run:

   **SMP router** — change `your_ip_or_domain`; `-e "PASS=password"` is optional:
   ```sh
   docker run -d \
       -e "ADDR=your_ip_or_domain" \
       -e "PASS=password" \
       -p 5223:5223 \
       -v $HOME/simplex/smp/config:/etc/opt/simplex:z \
       -v $HOME/simplex/smp/logs:/var/opt/simplex:z \
       simplexchat/smp-server:latest
   ```

   **XFTP router** — change `your_ip_or_domain` and `maximum_storage`:
   ```sh
   docker run -d \
       -e "ADDR=your_ip_or_domain" \
       -e "QUOTA=maximum_storage" \
       -p 443:443 \
       -v $HOME/simplex/xftp/config:/etc/opt/simplex-xftp:z \
       -v $HOME/simplex/xftp/logs:/var/opt/simplex-xftp:z \
       -v $HOME/simplex/xftp/files:/srv/xftp:z \
       simplexchat/xftp-server:latest
   ```

### Installation script (Ubuntu)

```sh
curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/install.sh -o simplex-server-install.sh &&\
if echo '53fcdb4ceab324316e2c4cda7e84dbbb344f32550a65975a7895425e5a1be757 simplex-server-install.sh' | sha256sum -c; then
  chmod +x ./simplex-server-install.sh
  ./simplex-server-install.sh
  rm ./simplex-server-install.sh
else
  echo "SHA-256 checksum is incorrect!"
  rm ./simplex-server-install.sh
fi
```

### Build from source

#### Using Docker

Build from the [stable branch](https://github.com/simplex-chat/simplexmq/tree/stable):

```sh
git clone https://github.com/simplex-chat/simplexmq
cd simplexmq
git checkout stable
DOCKER_BUILDKIT=1 docker build -t local/smp-server --build-arg APP="smp-server" --build-arg APP_PORT="5223" .
DOCKER_BUILDKIT=1 docker build -t local/xftp-server --build-arg APP="xftp-server" --build-arg APP_PORT="443" .
```

Then run with the same Docker commands as above, replacing `simplexchat/smp-server:latest` with `local/smp-server` (and similarly for XFTP).

#### Native build

1. Install dependencies:

   ```sh
   # Ubuntu
   sudo apt-get update && apt-get install -y build-essential curl libffi-dev libffi7 libgmp3-dev libgmp10 libncurses-dev libncurses5 libtinfo5 pkg-config zlib1g-dev libnuma-dev libssl-dev
   export BOOTSTRAP_HASKELL_GHC_VERSION=9.6.3
   export BOOTSTRAP_HASKELL_CABAL_VERSION=3.10.3.0
   curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 sh
   ghcup set ghc "${BOOTSTRAP_HASKELL_GHC_VERSION}"
   ghcup set cabal "${BOOTSTRAP_HASKELL_CABAL_VERSION}"
   source ~/.ghcup/env
   ```

2. Build:

   ```sh
   git clone https://github.com/simplex-chat/simplexmq
   cd simplexmq
   git checkout stable
   cabal update
   cabal build exe:smp-server exe:xftp-server
   ```

3. Find binaries:

   ```sh
   cabal list-bin exe:smp-server
   cabal list-bin exe:xftp-server
   ```

4. Initialize and run:

   ```sh
   smp-server init [-l] -n <fqdn>   # or --ip <ip>
   smp-server start
   ```

### Linode StackScript

[Deploy via Linode StackScript](https://cloud.linode.com/stackscripts/748014) — Shared CPU Nanode with 1GB is sufficient.

Configuration options:
- SMP Server store log flag for queue persistence (recommended)
- [Linode API token](https://www.linode.com/docs/guides/getting-started-with-the-linode-api#get-an-access-token) for automatic DNS and tagging (scopes: read/write for "linodes" and "domains")
- Domain name (e.g., `smp1.example.com`) — the [domain must exist](https://cloud.linode.com/domains/create) in your Linode account

After deployment (up to 5 minutes), get the server address from Linode tags or SSH: `smp://<fingerprint>@<fqdn>`.

### DigitalOcean 1-click

[SimpleX Server 1-click app](https://marketplace.digitalocean.com/apps/simplex-server) from DigitalOcean marketplace.

After deployment, get the fingerprint from the Droplet console (`/etc/opt/simplex/fingerprint`). Server address: `smp://<fingerprint>@<ip_address>`.

To use FQDN instead of IP:

```sh
smp-server delete
smp-server init [-l] -n <fqdn>
```

## Monitoring

SMP and XFTP routers expose Prometheus metrics via a control port. The control port also supports commands for runtime inspection (queue counts, client counts, statistics). See module specs linked from each router section in [`spec/routers.md`](../spec/routers.md) (Control, Prometheus, Stats).

## Protocol references

- [SimpleX Messaging Protocol](../protocol/simplex-messaging.md) — SMP wire format and security properties
- [XFTP Protocol](../protocol/xftp.md) — data packet protocol
- [Push Notifications Protocol](../protocol/push-notifications.md) — NTF protocol
- [SimpleX Network overview](../protocol/overview-tjr.md) — architecture and trust model
