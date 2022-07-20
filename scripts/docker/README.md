# smp-server docker container
0. Install `docker` to your host.

1. Build your `smp-server` image:
```sh
DOCKER_BUILDKIT=1 docker build -t smp-server .
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
