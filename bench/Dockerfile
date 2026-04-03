FROM haskell:9.6.3 AS build

WORKDIR /src

# Copy cabal file first for dependency caching
COPY simplexmq.cabal cabal.project* ./
RUN cabal update && cabal build --only-dependencies -f server_postgres smp-server-bench || true

# Copy full source
COPY . .
RUN cabal build -f server_postgres smp-server-bench \
  && cp $(cabal list-bin -f server_postgres smp-server-bench) /usr/local/bin/smp-server-bench

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      libgmp10 libpq5 libffi8 zlib1g ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/smp-server-bench /usr/local/bin/smp-server-bench
COPY tests/fixtures /app/tests/fixtures

WORKDIR /app

ENTRYPOINT ["smp-server-bench"]
