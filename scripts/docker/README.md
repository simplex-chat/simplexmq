# smp-server docker container
0. Install `docker` to your host.

1. Build your `smp-server` image:
    - **Option 1** - Compile `smp-server` from source (stable branch):
    ```sh
    DOCKER_BUILDKIT=1 docker build -t smp-server -f smp-server-build.Dockerfile .
    ```
    - **Option 2** - Download latest `smp-server` from [latest Github release](https://github.com/simplex-chat/simplexmq/releases/latest):
    ```sh
    DOCKER_BUILDKIT=1 docker build -t smp-server -f smp-server-download.Dockerfile .
    ```

2. Run new docker container:
```sh
docker run -d \
	--name smp-server \
	-e addr="your_ip_or_domain" \
	-p 5223:5223 \
	-v ${PWD}/config:/etc/opt/simplex \
	-v ${PWD}/logs:/var/opt/simplex \
	smp-server
```

Configuration files and logs will be written to [`config`](./config) and [`logs`](./logs) folders respectively.
