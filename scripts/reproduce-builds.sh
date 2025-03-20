#!/usr/bin/env sh
set -eu

TAG="$1"

tempdir="$(mktemp -d)"
init_dir="$PWD"

mkdir -p "$init_dir/$TAG/from-source" "$init_dir/$TAG/prebuilt"

git -C "$tempdir" clone https://github.com/simplex-chat/simplexmq.git &&\
	cd "$tempdir/simplexmq" &&\
	git checkout "$TAG"

for os in 20.04 22.04 24.04; do
	os_url="$(printf '%s' "$os" | tr '.' '_')"
	mkdir -p "$init_dir/cache/cabal/builder-${os}" "$init_dir/cache/dist-newstyle/builder-${os}"
	chmod g+wX "$init_dir/cache"

		#--no-cache \
	docker build \
		-f "$tempdir/simplexmq/Dockerfile.build" \
		--build-arg TAG=${os} \
		-t repro-${os} \
		.

	docker run \
		-t \
		-d \
		-v "$init_dir/cache/cabal/builder-${os}:/root/.cabal" \
		-v "$init_dir/cache/dist-newstyle/builder-${os}:/dist-newstyle" \
		-v "$tempdir/simplexmq:/project" \
		--name builder-${os} \
		repro-${os}
	
	
	apps='smp-server xftp-server ntf-server xftp'
	# Regular build
	docker exec \
		-t \
		-e apps="$apps" \
		builder-${os} \
		sh -c 'ln -s /dist-newstyle ./dist-newstyle && cabal update && cabal build && mkdir -p /out && for i in $apps; do bin=$(find /dist-newstyle -name "$i" -type f -executable); strip "$bin"; chmod +x "$bin"; mv "$bin" /out/; done'

	docker cp \
		builder-${os}:/out \
		out-${os}

	# PostgreSQL build (only smp-server)
	docker exec \
		-t \
		-e apps="$apps" \
		builder-${os} \
		sh -c 'ln -s /dist-newstyle ./dist-newstyle && cabal update && cabal build -fserver_postgres exe:smp-server && mkdir -p /out && for i in $apps; do bin=$(find /dist-newstyle -name "$i" -type f -executable); strip "$bin"; chmod +x "$bin"; mv "$bin" /out/; done'

	docker cp \
		builder-${os}:/out/smp-server \
		"$init_dir/$TAG/from-source/smp-server-postgres-ubuntu-${os_url}-x86-64"
	
	for app in $apps; do
		curl -L \
			--output-dir "$init_dir/$TAG/prebuilt/" \
			-O \
		       	"https://github.com/simplex-chat/simplexmq/releases/download/${TAG}/${app}-ubuntu-${os_url}-x86-64"

		mv "./out-${os}/$app" "$init_dir/$TAG/from-source/${app}-ubuntu-${os_url}-x86-64"
	done

	docker stop builder-${os}
	docker rm builder-${os} 
	docker image rm repro-${os}
done

# Cleanup
cd "$init_dir"
rm -rf "$tempdir"
