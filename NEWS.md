# getaca 0.0.0.9000

First development version. The v1 boundary is set; nothing here has been
released.

## Dependencies
* Requires R >= 4.0.0 and imports `curl` (>= 5.0.0), with `stats`, `tools` and
  `utils` from base R. Zero non-base transitive dependencies, and no
  `LinkingTo`. The floor on `curl` is `multi_download()`, which is what makes a
  mirror attempt resumable.
* SHA-256 is implemented in C, in `src/sha256.c`, covering both the artefact on
  disk and the manifest in memory. On x86-64 with the SHA extensions and on
  ARMv8 with the SHA-256 extensions the block compression runs in hardware,
  which on an i9-14900K hashes at 1.43 GB/s against 0.20 GB/s for
  `tools::sha256sum()`: a 4 GB resource is verified in 2.8 s rather than 20 s.
  Machines without either extension use a portable path that is no slower than
  what R provides. A digest is a single specified value, so this changes only
  the time a verification takes; registry digests already recorded stay valid.

## Declaration
* `resource()`: immutable record of exact bytes, with version, mirrors,
  SHA-256, size, license, upstream identity and optional processor.
* `registry()`, `registry_write()`, `registry_read()`, `registry_for()`:
  package-scoped declarations, discovered by convention at
  `inst/getaca/registry.rds`.
* `registry(current = )`: names the channel head, the version a bare request
  for each resource resolves to. Required for any name declaring more than one
  version, since version strings are labels and declaration order is not an
  ordering. A registry that offers a choice and names no head is refused.
* `registry_digest()`: a registry state is identified by a digest of its own
  declaration, as `"sha256:3f9ac2..."`. There is no revision number to keep in
  step, so identity cannot be typed wrong and two states that differ cannot
  claim to be the same one.
* `registry_manifest()`: the canonical text the digest is taken over, exported
  so a digest is never a black box. Two registries that disagree are diffable
  on the lines that produced the disagreement. Hashing the object itself is not
  an option, since a `processor()` closure digests differently on every machine.
* `registry_write()` stamps `created`, which orders two states in time.
  Deliberately outside the digest, so republishing an unchanged registry leaves
  its identity alone; pass a fixed value to keep a build byte-reproducible.
* A stored form older than this getaca still reads, and only a newer one is
  refused. Adding a field therefore costs nothing to registries already
  installed.
* `as_registry()`: YAML and JSON accepted as authoring formats, gated at call
  time so neither becomes a hard dependency.
* `processor()`: post-verification transformation with a stable id, so the
  derived result gets its own cache slot and provenance.
* `getaca_refresh()`: forget cached registry state, so a reinstalled declaring
  package or an updated remote registry is picked up without restarting the
  session.

## Resolution
* `getaca_policy()`: `bundled`, `current`, `pinned` and `offline` policies.
  Resolution collapses to `offline` under `R CMD check`.
* `resolve_resource()` reports the policy in force, and `getaca()` reads it, so
  `policy = "offline"` on a single call keeps that call off the network
  whatever the session is set to.
* `getaca_pin()`: freeze current resolution into a local snapshot.
* Remote channels may repair mirrors and publish new versions; redefining a
  published version is rejected as an invalid registry. Published means the
  bundled declaration together with whatever this machine has already fetched
  and verified, so a version that only ever existed remotely is held to its
  bytes as firmly as one that shipped with the package.

## Signing
* `registry(keys = )` declares the Ed25519 public keys allowed to sign a
  package's remote registry, and `registry_keygen()`, `registry_sign()` and
  `registry_verify()` are the author-side workflow. Declaring a key makes a
  signature mandatory under the `current` policy; declaring none leaves
  resolution exactly as it was, and no signature is ever fetched.
* The keys trusted are the ones in the registry the package *ships*, which
  reaches a user over the R install channel while the remote registry comes
  from the author's own host. A signature is worth something because those are
  two different routes.
* The signature covers `registry_manifest()`, plus the publication time and an
  expiry. Binding the time is what stops an old genuine declaration being
  replayed indefinitely; a state older than the installed one is refused as a
  rollback.
* A remote that cannot be reached still falls back to the bundled registry with
  a message. A remote that arrives and fails verification raises
  `getaca_error_signature` instead, including when the registry arrives and its
  signature does not.
* Ed25519 and SHA-512 are implemented in C, in `src/ed25519.c` and
  `src/sha512.c`, checked against RFC 8032 and FIPS 180-4. No new dependency:
  `Imports` remains `curl` plus three base packages.

## Retrieval
* `getaca()`: the single retrieval verb. Returns a local path.
* Resumable transfers into a temporary area, sized and hashed before an atomic
  move into the cache.
* Directory locking keyed on the declared checksum, so concurrent sessions
  never duplicate a large transfer or observe a partial one. Two packages
  declaring the same file wait on each other, and the second finds what the
  first retrieved.
* Eight classed conditions distinguishing user, author and upstream causes.
  A transfer that ends short on every mirror raises `getaca_error_incomplete`,
  whose action is to retry; mixed causes keep `getaca_error_unavailable` and
  list each mirror's reason.

## Verification
* Full SHA-256 on download, cheap size check on access, scheduled re-hash via
  `getaca.verify_days`.
* A full re-hash reads the file the caller is handed. Where the filesystem
  allowed a link that is the blob's own bytes, and where it refused one the
  view is an independent copy that nothing else would ever read. A processed
  slot holds a derived tree the declared checksum does not describe, so it is
  verified against the artefact it was made from instead.
* A verification whose target cannot be found raises rather than recording a
  pass. Moving `verified_at` forward for a check that never ran would put the
  entry beyond re-verification for good, since every later access would do the
  same.
* A mismatch is a verdict on bytes rather than on the slot that found it. Where
  those bytes are ones the store shares, it withdraws `verified_at` from every
  other slot naming that digest, so each re-hashes against its own copy on next
  access. Previously a second package holding the same corrupt bytes kept
  passing the cheap size check and kept being handed them as verified for the
  remainder of its own window, up to 90 days. A slot's own copy and a processed
  tree indict nothing but themselves.
* A cache hit is measured against the declaration in force as well as against
  the entry's own record. A version whose declaration has moved to different
  bytes raises `getaca_error_redeclared` naming both checksums, rather than
  resolving quietly to the copy already held. `verify = TRUE` asks the same
  question, so a forced re-hash can no longer confirm bytes against a
  declaration they no longer match.
* Entry records keep `fetched_at`, `verified_at`, `checked_at` and
  `accessed_at` apart.
* Provenance records which declaration state resolved the bytes
  (`registry_digest`), when that state was published (`registry_created`) and
  which getaca acted on it (`getaca_version`).

## Checks
* `getaca_available()`, `getaca_optional()`, `getaca_skip_if_unavailable()`.
* `getaca_prefetch()` and the `GETACA_CACHE` environment variable for seeding
  CI and check runs.

## Cache management
* Bytes live once, in a content-addressed store at `blobs/sha256/`, and a
  version slot holds a name for them. Two packages declaring the same file
  keep one copy and separate dependency records. The store holds no metadata:
  what is still needed is derived from the package indexes rather than counted
  beside them.
* Everything the store owns is read-only, since a caller writing to a returned
  path would otherwise damage every package that shares those bytes. A caller
  needing a writable layout declares a `processor()`, which gets its own slot.
* `getaca_clean()` and automatic collection after retrieval: broken material,
  abandoned transfers, superseded versions past retention, LRU eviction only
  above the size ceiling, and finally bytes no declaration references.
* The size ceiling measures what the cache occupies. Shared bytes count once,
  so two packages declaring one 4 GB file no longer count 8 GB against it.
* `getaca_keep()` to exempt a resource.
* `getaca_catalogue()`: one table covering what packages declare and what the
  cache holds, including declared resources never downloaded and cached
  versions no longer declared. A `current` column marks the version a bare
  request resolves to.
* `getaca_info()`: full provenance for one cached resource.
