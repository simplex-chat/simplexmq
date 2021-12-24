# Server image for DigitalOcean

<!-- TODO tested on a fresh DO droplet and this seems to be wrong - we have to update the image to behave as described.

The current image used for 1-click deployment on DigitalOcean does not contain the source or binary of SMP Server - it downloads the compiled binary of the latest release (rather than a particular release) from GitHub.

The upside is that the new image does not have to be created and approved by DigitalOcean every time when the new release is created. -->

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
