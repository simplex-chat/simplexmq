ARG TAG=22.04

FROM ubuntu:${TAG} AS build

### Build stage

# Install curl and git and simplexmq dependencies
RUN apt-get update && apt-get install -y curl git build-essential libgmp3-dev zlib1g-dev llvm-12 llvm-12-dev libnuma-dev

# Specify bootstrap Haskell versions
ENV BOOTSTRAP_HASKELL_GHC_VERSION=9.6.3
ENV BOOTSTRAP_HASKELL_CABAL_VERSION=3.10.1.0

# Install ghcup
RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 sh

# Adjust PATH
ENV PATH="/root/.cabal/bin:/root/.ghcup/bin:$PATH"

# Set both as default
RUN ghcup set ghc "${BOOTSTRAP_HASKELL_GHC_VERSION}" && \
    ghcup set cabal "${BOOTSTRAP_HASKELL_CABAL_VERSION}"

COPY . /project
WORKDIR /project

ARG APP
ARG APP_PORT
RUN if [ -z "$APP" ] || [ -z "$APP_PORT" ]; then printf "Please spcify \$APP and \$APP_PORT build-arg.\n"; exit 1; fi

# Compile app
RUN cabal update
RUN cabal build exe:$APP

# Create new path containing all files needed
RUN mkdir /final
WORKDIR /final

# Strip the binary from debug symbols to reduce size
RUN bin=$(find /project/dist-newstyle -name "$APP" -type f -executable) && \
    mv "$bin" ./ && \
    strip ./"$APP" &&\
    mv /project/scripts/docker/entrypoint-"$APP" ./entrypoint

### Final stage
FROM ubuntu:${TAG}

# Install OpenSSL dependency
RUN apt-get update && apt-get install -y openssl libnuma-dev

# Copy compiled app from build stage
COPY --from=build /final /usr/local/bin/

# Open app listening port
ARG APP_PORT
EXPOSE $APP_PORT

# simplexmq requires using SIGINT to correctly preserve undelivered messages and restore them on restart
STOPSIGNAL SIGINT

# Finally, execute helper script
ENTRYPOINT [ "/usr/local/bin/entrypoint" ]
