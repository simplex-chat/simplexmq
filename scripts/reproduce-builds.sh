#!/usr/bin/env sh
set -eu

tag="$1"

git clone https://github.com/simplex-chat/simplexmq && cd simplexmq

git checkout "$tag"

for os in 20.04 22.04 24.04; do
	mkdir -p out-${os}-github;

	docker build -f Dockerfile.build --build-arg TAG=${os} -t repro-${os} .
	docker run -t -d --name builder-${os} repro-${os}
	
	apps='smp-server xftp-server ntf-server xftp'
	os_url="$(printf '%s' "$os" | tr '.' '_')"
	
	docker exec -t -e apps="$apps" builder-${os} sh -c 'cabal build && mkdir /out && for i in $apps; do bin=$(find /project/dist-newstyle -name "$i" -type f -executable); strip "$bin"; chmod +x "$bin"; mv "$bin" /out/; done'

	docker cp builder-${os}:/out out-${os}
	
	for app in $apps; do
		curl -L "https://github.com/simplex-chat/simplexmq/releases/download/${tag}/${app}-ubuntu-${os_url}-x86-64" -o out-${os}-github/${app}
	done

	docker stop builder-${os}
	docker rm builder-${os} 
	docker image rm repro-${os}
done
