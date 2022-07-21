FROM ubuntu:focal AS final
FROM ubuntu:focal AS build

### Build stage

# Install curl and git
RUN apt-get update && apt-get install -y curl git

# Install stack
RUN curl -sSL https://get.haskellstack.org/ | sh

# Clone simplexmq repository
RUN git clone https://github.com/simplex-chat/simplexmq
# and cd to it
WORKDIR ./simplexmq

# Checkout against master
RUN git checkout master

# Compile smp-server
RUN stack install && \
    strip /root/.local/bin/smp-server

### Final stage

FROM final

# Install OpenSSL dependency
RUN apt-get update && apt-get install -y openssl

# Copy compiled smp-server from build stage
COPY --from=build /root/.local/bin/smp-server /usr/bin/smp-server

# Copy our helper script
COPY ./entrypoint /usr/bin/entrypoint

# Open smp-server listening port
EXPOSE 5223

# SimpleX requires using SIGINT to correctly preserve undelivered messages and restore them on restart
STOPSIGNAL SIGINT

# Finally, execute helper script
ENTRYPOINT [ "/usr/bin/entrypoint" ]
