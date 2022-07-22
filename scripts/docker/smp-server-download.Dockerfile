FROM ubuntu:focal

# Install curl
RUN apt-get update && apt-get install -y curl

# Download latest smp-server release and assign executable permission
RUN curl -L https://github.com/simplex-chat/simplexmq/releases/latest/download/smp-server-ubuntu-20_04-x86-64 -o /usr/bin/smp-server && \
	chmod +x /usr/bin/smp-server

# Copy our helper script
COPY ./entrypoint /usr/bin/entrypoint

# Open smp-server listening port
EXPOSE 5223

# SimpleX requires using SIGINT to correctly preserve undelivered messages and restore them on restart
STOPSIGNAL SIGINT

# Finally, execute helper script
ENTRYPOINT [ "/usr/bin/entrypoint" ]
