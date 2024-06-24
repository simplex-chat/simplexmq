# Sending large file descriptions

It is desirable to provide a QR code/URI from which a file can be downloaded. This way files may be addressed outside a chat client.
Currently the `xftp` CLI tool can generate YAML file descriptions that can be used to receive a file.
It is possible to pass such a description as an URI, but descriptions for files larger than ~8 MBs (two 4 MB chunks) would give QR codes that are difficult to process.
A user can manually upload description and get a shorter one. Typically descriptions for files that are up to ~20 GBs would still be small enough to not require another pass, and that is way beyond any current (or, reasonable, fwiw) limitations.

It is possible to streamline this process, so any application using simplexmq agent can easily send file descriptions and follow redirects.
A file description with a redirect contains an extra field with final file size and digest so it can be followed automatically.

The flow would be like this:

- Sending:
  1. Upload file as usual with `xftpSendFile`, get recipient file descriptions in `SFDONE` message.
  2. Upload one of the file descriptions with `xftpSendDescription`, get its redirect-description in its `SFDONE` message.
  3. Wrap in `FileDescriptionURI` and use `strEncode` to get a QR-sized URI.
  4. Show QR code / copy link.
- Receiving:
  1. Scan QR code / paste link.
  2. Use `strDecode` and unwrap `FileDescriptionURI` to get `ValidFileDescription 'FRecipient`.
  3. Download it as usual with `xftpReceiveFile`, getting `RFDONE` message when the file is fully received.

It is not necesary to use redirect description if original description can be encoded to fit in 1002 characters. Beyond this size there is a significant jump in QR code complexity.
It is possible to call `encodeFileDescriptionURI` right after upload to test if the URI fits and skip step 2.
When `xftpReceiveFile` receives a decoded description that lacks `redirect` field, the procedure for downloading a file is the same as usual - download chunks and reassemble local file.

## Agent changes

### Sending

Sending and receiving files in agent is a multi-step process mediated by DB entries in `snd_files` and `rcv_files` tables.

`xftpSendDescription` is tasked with storing original description in a temporary locally-encrypted file, then creating upload task for it.

It is necessary to preserve redirect metadata so it can be attached to descriptions in the `SFDONE` message sent by a worker:

```sql
ALTER TABLE snd_files ADD COLUMN redirect_size INTEGER;
ALTER TABLE snd_files ADD COLUMN redirect_digest BLOB;
```

### Receiving

`xftpReceiveFile` gets a file description as an argument and knows if it should follow redirect procedure or run an ordinary download.
For redirects it will prepare a `RcvFile` for redirect and then a placeholder, for the final file.
Agent messages would be sent using the entity ID of the final file, which is stored along with redirect metadata in `RcvFile` for the redirect.

```sql
ALTER TABLE rcv_files ADD COLUMN redirect_id INTEGER REFERENCES rcv_files ON DELETE CASCADE; -- for later updates
ALTER TABLE rcv_files ADD COLUMN redirect_entity_id BLOB; -- for notifications
ALTER TABLE rcv_files ADD COLUMN redirect_size INTEGER;
ALTER TABLE rcv_files ADD COLUMN redirect_digest BLOB;
```

These additional fields will exist on the file that is a short description to receive an actual description of the final file.

While a description YAML is being downloaded, the application will get `RFPROG` messages tagged for final entity, containing bytes downloaded so far and the total size from the original file.
When the description is fully downloaded, the worker would decode description and check if the stated size and digest match the declared in redirect.
Then it will replace placeholder description in `rcv_files` for destination file with the actual data from downloaded description.
Finally, instead of sending `RFDONE` for redirect, it hands over work to chunk download worker, which will run exactly as if the user requested its download directly.
An application will then receive `RFPROG` and `RFDONE` messages as usual.

## URI encoding

File description URIs use the same service schema `simplex:` or its `https://simplex.chat` (or any custom host) equivalent as do contact links and can be extracted from text and processed the same way.
The path section is `/file` (with an optional trailing `/`).
The payload is encoded in the "fragment" part of the link, using `#/?`, followed by a query string.
File description is encoded first in a YAML document, then URL-encoded in under the key `d`.
An application may want to pass extra parameters not necessary to download a file. Those go in the `_` key, encoded as a JSON dictionary.

An example link:

`simplex:/file#/?d=chunkSize%3A%2064kb%0Adigest%3A%20OtpnXkECTW4a18Eots2m3O22maeOCMqPUX4ulugIjgMEJfCpTYc_-T257Uw7s9bW_F0G5WBg5BioBWd4Z_OoCw%3D%3D%0Akey%3A%20rNR8_2SJuH7Qve43gV3zszL0R6oY5HSdRZT_paB-wfE%3D%0Anonce%3A%202oKwfK-w75nwyWp8_1Lv6QnQonIRtJmG%0Aparty%3A%20recipient%0Areplicas%3A%0A-%20chunks%3A%0A%20%20-%201%3ATdvaxMnG2Ph1e3QCx3-rpA%3D%3D%3AMC4CAQAwBQYDK2VwBCIEILdErEICvgrBCajDLTX2h3LXyMB7z5vrtLa3XVigJuf-%3ANS46KuYdgOWs6dUeMp7p2oF8rBQ9wQ2Ez6TW6Y6gHg0%3D%0A%20%20-%202%3AH5SRbtKYrXWVXTthrkeWzw%3D%3D%3AMC4CAQAwBQYDK2VwBCIEIGeEPNLt7lUGPfplwsoJLCDFnbIc5Hm31kz5X6rWXmgu%3A7QNRI-gvFx9UM-baXp3YVDli9pcfh3HGFKDhsA9JQHY%3D%0A%20%20-%203%3A_xjukkIl9WZFryUXT0h_TQ%3D%3D%3AMC4CAQAwBQYDK2VwBCIEIIRFBaL1HvUfePvKLuggwUrC_q_ZHd7v08IL9jhM7teC%3Aid2lgLMMjTGsR8SUogJuRdLoEHAc5SDQKFDqlZRSuEY%3D%0A%20%20server%3A%20xftp%3A%2F%2FLcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI%3D%40localhost%3A7002%0Asize%3A%20192kb%0A&_=%7B%22k%22:%22test%22%7D`
