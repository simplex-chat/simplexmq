FROM ubuntu:focal AS final
FROM ubuntu:focal AS build

### Build stage

# Install curl and git and smp-related dependencies
RUN apt-get update && apt-get install -y curl git build-essential libgmp3-dev zlib1g-dev

# Install ghcup
RUN curl https://downloads.haskell.org/~ghcup/x86_64-linux-ghcup -o /usr/bin/ghcup && \
    chmod +x /usr/bin/ghcup

# Install ghc
RUN ghcup install ghc
# Install cabal
RUN ghcup install cabal
# Set both as default
RUN ghcup set ghc && \
    ghcup set cabal

# Clone simplexmq repository
RUN git clone https://github.com/simplex-chat/simplexmq
# and cd to it
WORKDIR ./simplexmq

# Checkout against master
RUN git checkout stable

# Adjust PATH
ENV PATH="/root/.cabal/bin:/root/.ghcup/bin:$PATH"

# Compile smp-server
RUN cabal update
RUN cabal install

### Final stage

FROM final

# Install OpenSSL dependency
RUN apt-get update && apt-get install -y openssl

# Copy compiled smp-server from build stage
COPY --from=build /root/.cabal/bin/smp-server /usr/bin/smp-server

# Copy our helper script
COPY ./entrypoint /usr/bin/entrypoint

# Open smp-server listening port
EXPOSE 5223

# SimpleX requires using SIGINT to correctly preserve undelivered messages and restore them on restart
STOPSIGNAL SIGINT

# Finally, execute helper script
ENTRYPOINT [ "/usr/bin/entrypoint" ]
