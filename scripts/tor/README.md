1. Install `tor` following [official guide](https://community.torproject.org/onion-services/setup/install/).

2. Modify `/etc/tor/torrc` configuration file:

```sh
...
# Disable anonymous mode for better connectivity
## Needed for HiddenServiceNonAnonymousMode
SOCKSPort 0
## Needed for HiddenServiceSingleHopMode
HiddenServiceNonAnonymousMode 1
## Flag to disable anonymous mode
## This option reduces the latency of server connection, but it makes server itself not anonymous,
## it only protects the anonymity of the users connecting to the server.
## In case your server address has both public and onion hostnames it is not anonymous anyway,
## so this is what you want.
HiddenServiceSingleHopMode 1

# Specify folder for smp-tor
## Folder for keys, address, etc.
HiddenServiceDir /var/lib/tor/simplex-smp/
## Map smp port (5223) to tor
HiddenServicePort 5223 localhost:5223
...
```

3. Restart `tor` system service:

```
sudo systemctl restart tor
```

4. Onion address can be obtained from following file:

```sh
sudo cat /var/lib/tor/simplex-smp/hostname
```
