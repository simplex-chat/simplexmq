# Topic Candidates

> Cross-cutting patterns noticed during module documentation. Each entry may become a topic doc in `spec/` after all module docs are complete.

- **Exception handling strategy**: `catchOwn`/`catchAll`/`tryAllErrors` pattern (defined in Util.hs) used across server, client, and agent modules. The three-category classification (synchronous, own-async, cancellation) and when to use which catch variant is not obvious from any single call site.
