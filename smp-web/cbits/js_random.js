addToLibrary({
  js_random_bytes: function(buf, len) {
    var bytes = new Uint8Array(len);
    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
      crypto.getRandomValues(bytes);
    } else {
      // Node.js fallback
      var nodeCrypto = require('crypto');
      var nodeBytes = nodeCrypto.randomBytes(len);
      bytes.set(nodeBytes);
    }
    HEAPU8.set(bytes, buf);
  }
});
