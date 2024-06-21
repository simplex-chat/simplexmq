# Short invitation links

## Problem

Long links look scary and unsafe for many users. While this is a perceived problem, rather than a real one, it hurts adoption.

What is worse, long links do not fit in profile descriptions of other social networks where people might want to advertize their contact addresses.

The current link size limitation is also the reason for not including PQ KEM keys into invitation links and addresses, postponing the moment when PQ-resistant encryption kicks in - if we include PQ KEM key into the link, the QR code will not be scannable.

## Solution

MITM-resistant link shortening.

Instead of generating the random address that would resolve into the link - doing so would create the possibility of MITM by the server hosting this link - we can hash the full link with SHA256 or SHA512 and use this hash as part of the shorter address.

The proposed syntaxt:

```abnf
shortConnectionRequest = connectionScheme "/" connReqType "#/" smpServer "/" linkHash
connReqType = %s"invitation" / %s"contact"
connectionScheme = (%s"https://" clientAppServer) / %s"simplex:"
clientAppServer = hostname [ ":" port ]
  ; client app server, e.g. simplex.chat
smpServer = serverIdentity "@" srvHosts [":" port] ; no smp:// prefix, no escaping
srvHosts = <hostname> ["," srvHosts] ; RFC1123, RFC5891
linkHash = <base64url encoded SHA256 or SHA512 hash of the original link>
```

Example link:

```
https://simplex.chat/contact/#0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU=@smp8.simplex.im,beccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion/abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789abcd=
```

This link has the length of ~240 characters, which is a bit shorter than the full contact address (~310 characters) and much shorter than invitation links (~528 characters) even without post-quantum keys added to them.

This size can be further reduced by
- not pinning server TLS certificate - the downside here is that while the attack that compromises TLS will not be able to substitute the link (because it's hash will not match), it will be able to intercept and to block it.
- using even shorter hash - reducing the collision resistance.

If we implement it, the request to resolve the link would be made via proxied SMP command (to avoid the direct connection between the client and the recipient's server).

Pros:
- a bit shorter link.
- possibility to include post-quantum keys into the full link keeping the same shortened link size.

Cons:
- the length reduction, compared with the current contact address, is less than 25%.
- protocol complexity.
- even though the server cannot replace the link, it will have access to it.

Overall, there is a strong argument for postponing this improvement until we add identity/addressing layer with short memorizable addresses.
