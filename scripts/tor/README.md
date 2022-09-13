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
