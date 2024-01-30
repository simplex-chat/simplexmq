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
  3. Use `encodeFileDescriptionURI` to get a QR-sized URI.
  4. Show QR code / copy link.
- Receiving:
  1. Scan QR code / paste link.
  2. Use `decodeFileDescriptionURI` to get `ValidFileDescription 'FRecipient`.
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
ALTER TABLE rcv_files ADD COLUMN redirect_entity_id BLOB;
ALTER TABLE rcv_files ADD COLUMN redirect_size INTEGER;
ALTER TABLE rcv_files ADD COLUMN redirect_digest BLOB;
```

These additional fields will exist on the file that is a short description to receive an actual description of the final file.

While a description YAML is being downloaded, the application will get `RFPROG` messages tagged for final entity, containing bytes downloaded so far and the total size from the original file.
When the description is fully downloaded, the worker would decode description and check if the stated size and digest match the declared in redirect.
Then it will replace placeholder description in `rcv_files` for destination file with the actual data from downloaded description.
Finally, instead of sending `RFDONE` for redirect, it hands over work to chunk download worker, which will run exactly as if the user requested its download directly.
An application will then receive `RFPROG` and `RFDONE` messages as usual.
