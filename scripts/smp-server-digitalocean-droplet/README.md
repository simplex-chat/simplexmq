# SMP server image for DigitalOcean

## How to build an image

1. [Create an API token](https://cloud.digitalocean.com/account/api/tokens) in vendor account in DigitalOcean.
2. Install [packer](https://www.packer.io/downloads) downloading binary or with brew (on Mac):

```shell
brew tap hashicorp/tap
brew install hashicorp/tap/packer
```

3. Run `packer build` in the `smp-server-digitalocean-droplet` repository:

```shell
cd ./scripts/smp-server-digitalocean-droplet
DIGITALOCEAN_TOKEN=$YOUR_TOKEN packer build -on-error=ask -color=false ./marketplace-image.json
```

**TODO** (see Linode script)

- Increase file descriptors limit
- Configure Restart for systemd service
