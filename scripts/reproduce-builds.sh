#!/usr/bin/env sh
set -eu

TAG="$1"

tempdir="$(mktemp -d)"
init_dir="$PWD"

repo="https://github.com/simplex-chat/simplexmq"
export DOCKER_BUILDKIT=1

cleanup() {
	docker exec -t builder sh -c 'rm -rf ./dist-newstyle'
	rm -rf -- "$tempdir"
	docker rm --force builder
	docker image rm local
	cd "$init_dir"
}
trap 'cleanup' EXIT INT

mkdir -p "$init_dir/$TAG/from-source" "$init_dir/$TAG/prebuilt"

git -C "$tempdir" clone "$repo.git" &&\
	cd "$tempdir/simplexmq" &&\
	git checkout "$TAG"

for os in 22.04 24.04; do
	os_url="$(printf '%s' "$os" | tr '.' '_')"

	# Build image
	docker build \
		--no-cache \
		--build-arg TAG=${os} \
		--build-arg GHC=9.6.3 \
		-f "$tempdir/simplexmq/Dockerfile.build" \
		-t local \
		.

	# Run container in background
	docker run -t -d \
		--name builder \
		-v "$tempdir/simplexmq:/project" \
		local

	# PostgreSQL build (only smp-server)
	docker exec \
		-t \
		builder \
		sh -c 'cabal update && cabal build --enable-tests -fserver_postgres && mkdir -p /out && for i in smp-server simplexmq-test; do bin=$(find /project/dist-newstyle -name "$i" -type f -executable) && chmod +x "$bin" && mv "$bin" /out/; done && strip /out/smp-server'

	# Copy smp-server postgresql binary and prepare it
	docker cp \
		builder:/out/smp-server \
		"$init_dir/$TAG/from-source/smp-server-postgres-ubuntu-${os_url}-x86-64"

	# Download prebuilt postgresql binary
	curl -L \
		--output-dir "$init_dir/$TAG/prebuilt/" \
		-O \
		"$repo/releases/download/${TAG}/smp-server-postgres-ubuntu-${os_url}-x86-64"
	
	# Regular build (all)
	apps='smp-server xftp-server ntf-server xftp'

	docker exec \
		-t \
		-e apps="$apps" \
		builder \
		sh -c 'cabal build && mkdir -p /out && for i in $apps; do bin=$(find /project/dist-newstyle -name "$i" -type f -executable) && strip "$bin" && chmod +x "$bin" && mv "$bin" /out/; done'

	# Copy regular binaries
	docker cp \
		builder:/out \
		out-${os}
	
	# Prepare regular binaries and download the prebuilt ones
	for app in $apps; do
		curl -L \
			--output-dir "$init_dir/$TAG/prebuilt/" \
			-O \
		       	"$repo/releases/download/${TAG}/${app}-ubuntu-${os_url}-x86-64"

		mv "./out-${os}/$app" "$init_dir/$TAG/from-source/${app}-ubuntu-${os_url}-x86-64"
	done

	# Important! Remove dist-newstyle for the next interation
	docker exec \
		-t \
		builder \
		sh -c 'rm -rf ./dist-newstyle'

	# Also restore git to previous state 
	git reset --hard && git clean -dfx

	# Stop containers, delete images
	docker stop builder
	docker rm --force builder
	docker image rm local
done

# Cleanup
rm -rf -- "$tempdir"
cd "$init_dir"
