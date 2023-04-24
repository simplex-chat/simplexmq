FROM ubuntu:23.04 AS final
FROM ubuntu:23.04 AS build

### Build stage

# Install curl and git and smp-related dependencies
RUN apt-get update && apt-get install -y curl git build-essential libgmp3-dev zlib1g-dev llvm llvm-dev libnuma-dev

# Install ghcup
RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=8.10.7 BOOTSTRAP_HASKELL_CABAL_VERSION=3.6.2.0 sh

# Adjust PATH
ENV PATH="/root/.cabal/bin:/root/.ghcup/bin:$PATH"

# Set both as default
RUN ghcup set ghc 8.10.7 && \
    ghcup set cabal

COPY . /project
WORKDIR /project

# Compile smp-server
RUN cabal update
RUN cabal build exe:smp-server

# Strip the binary from debug symbols to reduce size
RUN smp=$(find ./dist-newstyle -name "smp-server" -type f -executable) && \
    mv "$smp" ./ && \
    strip ./smp-server

### Final stage

FROM final

# Install OpenSSL dependency
RUN apt-get update && apt-get install -y openssl libnuma-dev

# Copy compiled smp-server from build stage
COPY --from=build /project/smp-server /usr/bin/smp-server

# Copy our helper script
COPY ./scripts/docker/entrypoint /usr/bin/entrypoint

# Open smp-server listening port
EXPOSE 5223

# SimpleX requires using SIGINT to correctly preserve undelivered messages and restore them on restart
STOPSIGNAL SIGINT

# Finally, execute helper script
ENTRYPOINT [ "/usr/bin/entrypoint" ]
