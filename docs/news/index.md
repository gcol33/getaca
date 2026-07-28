# Changelog

## getaca 0.1.2

### Transfers report themselves

- [`getaca_progress()`](https://gillescolling.com/getaca/reference/getaca_progress.md)
  chooses what a transfer looks like: `"bar"` redraws a line with the
  share, the rate and what is left, `"line"` writes one line to start
  and one to finish for a log, `"none"` says nothing, and `"auto"` picks
  between the first and the third by whether the session is interactive.
  Also readable from `getaca.progress` and `GETACA_PROGRESS`, and
  `quiet = TRUE` on a single
  [`getaca()`](https://gillescolling.com/getaca/reference/getaca.md)
  call still overrides all of it.
- [`reporter()`](https://gillescolling.com/getaca/reference/reporter.md)
  builds your own out of a function of one argument, so a declaring
  package can report a download in its own voice, or into a Shiny
  session, or as a row in a log. No dependency: `Imports` is still
  `curl` plus three base packages.
- The events carry what the registry knows and a transfer library
  cannot: the resource identity, which renders as
  `taxify/wfo@2026-09 (part 2 of 3)` for a series, the size the
  declaration states rather than whatever content length the mirror
  sent, which mirror is being tried, and how much was already on disk
  when an interrupted transfer resumed. The share a bar shows is
  therefore right before the first byte arrives and stays right for a
  host that sends no content length at all.
- A reporter that raises is caught, warned about once and switched off.
  Reporting is cosmetic and a retrieval is not.

### The transfer loop

- getaca drives the transfer over the curl multi interface rather than
  handing a URL to
  [`curl::multi_download()`](https://jeroen.r-universe.dev/curl/reference/multi_download.html),
  which is what makes the byte counts reachable at all:
  `multi_download()` sets `noprogress` on the handle after the caller’s
  options, so a progress callback attached to it never runs. See
  `dev_notes/adr-008-own-transfer-loop.md`.
- Resumed transfers now ask for `identity` encoding. A range request
  counts bytes of the decoded stream and a compressing server counts
  encoded ones, and libcurl reports the combination as an error rather
  than as bytes: against `raw.githubusercontent.com` a resumed request
  failed with `curl_error_bad_content_encoding` and transferred nothing.
  Every resume from a compressing mirror was silently starting the
  download over.
- The response status is read before the first byte is written, so the
  body of a failed request is never written to the partial file. It was
  previously written and then removed.
- `HTTP 416` is distinguished from other refusals. It says the offset
  asked for is past the end of the file the server holds, so the partial
  disagrees with upstream and is dropped; any other refusal leaves the
  bytes an earlier attempt did get.
- A mirror that answers a resume request with the whole file is now
  detected from the status and written from zero. It previously
  appended, and cost a full retry once the checksum failed.
- Transfers now send getaca’s user agent. `new_handle_for()` never set
  the URL or reached the transfer path at all; the multi interface takes
  both from the handle.

## getaca 0.1.1

### Resources that arrive in pieces

- [`part()`](https://gillescolling.com/getaca/reference/part.md) and
  [`combiner()`](https://gillescolling.com/getaca/reference/combiner.md):
  a record names either locations for the whole file or the ordered
  series it is composed from, and `sha256` describes the artefact either
  way. A host that caps file size, and a publisher issuing deltas
  against a base release, both produce a resource that arrives as a
  series.
- Each part is verified and stored under its own digest, so a base
  shared by every version of a resource is transferred once and kept
  once, and publishing a version costs its consumers the delta rather
  than the whole file.
- Parts are concatenated unless the record declares a
  [`combiner()`](https://gillescolling.com/getaca/reference/combiner.md),
  which is what a delta format needs. The composed result is held to the
  record’s own checksum before anything sees it, so a combiner cannot
  produce bytes the declaration did not already name. That is also why
  `assert_immutable()` compares only that checksum: re-splitting a
  series or moving a piece to another host is a change of route, not of
  identity.
- `getaca_error_composition`: every part arrived and matched its own
  checksum, and combining them produced something else. Nothing failed
  in transit, so the actor is the author rather than the network.
- `resource(file = )`: the name the artefact is cached under, for a URL
  with no useful basename and for composed records, where each URL names
  a piece rather than the result.
- A part is reached through the entry composed from it, since no version
  slot names one. A base shared by several versions therefore lives
  exactly as long as the last version holding it, under the same
  reachability rule as everything else in the store.
- [`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md)
  gains a `parts` column, `0` where a version is served whole, so what
  an update costs to fetch is visible before it is fetched.
- `part`, `combiner` and `file` render nothing when absent, so every
  registry digest recorded before they existed still identifies the
  state that produced it. The manifest format is unchanged.

## getaca 0.1.0

First release.

### Dependencies

- Requires R \>= 4.0.0 and imports `curl` (\>= 5.0.0), with `stats`,
  `tools` and `utils` from base R. Zero non-base transitive
  dependencies, and no `LinkingTo`. The floor on `curl` is
  `multi_download()`, which is what makes a mirror attempt resumable.
- SHA-256 is implemented in C, in `src/sha256.c`, covering both the
  artefact on disk and the manifest in memory. On x86-64 with the SHA
  extensions and on ARMv8 with the SHA-256 extensions the block
  compression runs in hardware, which on an i9-14900K hashes at 1.43
  GB/s against 0.20 GB/s for
  [`tools::sha256sum()`](https://rdrr.io/r/tools/sha256sum.html): a 4 GB
  resource is verified in 2.8 s rather than 20 s. Machines without
  either extension use a portable path that is no slower than what R
  provides. A digest is a single specified value, so this changes only
  the time a verification takes; registry digests already recorded stay
  valid.

### Declaration

- [`resource()`](https://gillescolling.com/getaca/reference/resource.md):
  immutable record of exact bytes, with version, mirrors, SHA-256, size,
  license, upstream identity and optional processor.
- [`registry()`](https://gillescolling.com/getaca/reference/registry.md),
  [`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md),
  [`registry_read()`](https://gillescolling.com/getaca/reference/registry_write.md),
  [`registry_for()`](https://gillescolling.com/getaca/reference/registry_for.md):
  package-scoped declarations, discovered by convention at
  `inst/getaca/registry.rds`.
- `registry(current = )`: names the channel head, the version a bare
  request for each resource resolves to. Required for any name declaring
  more than one version, since version strings are labels and
  declaration order is not an ordering. A registry that offers a choice
  and names no head is refused.
- [`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md):
  a registry state is identified by a digest of its own declaration, as
  `"sha256:3f9ac2..."`. There is no revision number to keep in step, so
  identity cannot be typed wrong and two states that differ cannot claim
  to be the same one.
- [`registry_manifest()`](https://gillescolling.com/getaca/reference/registry_manifest.md):
  the canonical text the digest is taken over, exported so a digest is
  never a black box. Two registries that disagree are diffable on the
  lines that produced the disagreement. Hashing the object itself is not
  an option, since a
  [`processor()`](https://gillescolling.com/getaca/reference/processor.md)
  closure digests differently on every machine.
- [`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md)
  stamps `created`, which orders two states in time. Deliberately
  outside the digest, so republishing an unchanged registry leaves its
  identity alone; pass a fixed value to keep a build byte-reproducible.
- A stored form older than this getaca still reads, and only a newer one
  is refused. Adding a field therefore costs nothing to registries
  already installed.
- [`as_registry()`](https://gillescolling.com/getaca/reference/as_registry.md):
  YAML and JSON accepted as authoring formats, gated at call time so
  neither becomes a hard dependency.
- [`processor()`](https://gillescolling.com/getaca/reference/processor.md):
  post-verification transformation with a stable id, so the derived
  result gets its own cache slot and provenance.
- [`getaca_refresh()`](https://gillescolling.com/getaca/reference/getaca_refresh.md):
  forget cached registry state, so a reinstalled declaring package or an
  updated remote registry is picked up without restarting the session.

### Resolution

- [`getaca_policy()`](https://gillescolling.com/getaca/reference/getaca_policy.md):
  `bundled`, `current`, `pinned` and `offline` policies. Resolution
  collapses to `offline` under `R CMD check`.
- [`resolve_resource()`](https://gillescolling.com/getaca/reference/resolve_resource.md)
  reports the policy in force, and
  [`getaca()`](https://gillescolling.com/getaca/reference/getaca.md)
  reads it, so `policy = "offline"` on a single call keeps that call off
  the network whatever the session is set to.
- [`getaca_pin()`](https://gillescolling.com/getaca/reference/getaca_pin.md):
  freeze current resolution into a local snapshot.
- Remote channels may repair mirrors and publish new versions;
  redefining a published version is rejected as an invalid registry.
  Published means the bundled declaration together with whatever this
  machine has already fetched and verified, so a version that only ever
  existed remotely is held to its bytes as firmly as one that shipped
  with the package.

### Signing

- `registry(keys = )` declares the Ed25519 public keys allowed to sign a
  package’s remote registry, and
  [`registry_keygen()`](https://gillescolling.com/getaca/reference/registry_keygen.md),
  [`registry_sign()`](https://gillescolling.com/getaca/reference/registry_sign.md)
  and
  [`registry_verify()`](https://gillescolling.com/getaca/reference/registry_verify.md)
  are the author-side workflow. Declaring a key makes a signature
  mandatory under the `current` policy; declaring none leaves resolution
  exactly as it was, and no signature is ever fetched.
- The keys trusted are the ones in the registry the package *ships*,
  which reaches a user over the R install channel while the remote
  registry comes from the author’s own host. A signature is worth
  something because those are two different routes.
- The signature covers
  [`registry_manifest()`](https://gillescolling.com/getaca/reference/registry_manifest.md),
  plus the publication time and an expiry. Binding the time is what
  stops an old genuine declaration being replayed indefinitely; a state
  older than the installed one is refused as a rollback.
- A remote that cannot be reached still falls back to the bundled
  registry with a message. A remote that arrives and fails verification
  raises `getaca_error_signature` instead, including when the registry
  arrives and its signature does not.
- Ed25519 and SHA-512 are implemented in C, in `src/ed25519.c` and
  `src/sha512.c`, checked against RFC 8032 and FIPS 180-4. No new
  dependency: `Imports` remains `curl` plus three base packages.

### Retrieval

- [`getaca()`](https://gillescolling.com/getaca/reference/getaca.md):
  the single retrieval verb. Returns a local path.
- Resumable transfers into a temporary area, sized and hashed before an
  atomic move into the cache.
- Directory locking keyed on the declared checksum, so concurrent
  sessions never duplicate a large transfer or observe a partial one.
  Two packages declaring the same file wait on each other, and the
  second finds what the first retrieved.
- Eight classed conditions distinguishing user, author and upstream
  causes. A transfer that ends short on every mirror raises
  `getaca_error_incomplete`, whose action is to retry; mixed causes keep
  `getaca_error_unavailable` and list each mirror’s reason.

### Verification

- Full SHA-256 on download, cheap size check on access, scheduled
  re-hash via `getaca.verify_days`.
- A full re-hash reads the file the caller is handed. Where the
  filesystem allowed a link that is the blob’s own bytes, and where it
  refused one the view is an independent copy that nothing else would
  ever read. A processed slot holds a derived tree the declared checksum
  does not describe, so it is verified against the artefact it was made
  from instead.
- A verification whose target cannot be found raises rather than
  recording a pass. Moving `verified_at` forward for a check that never
  ran would put the entry beyond re-verification for good, since every
  later access would do the same.
- A mismatch is a verdict on bytes rather than on the slot that found
  it. Where those bytes are ones the store shares, it withdraws
  `verified_at` from every other slot naming that digest, so each
  re-hashes against its own copy on next access. Previously a second
  package holding the same corrupt bytes kept passing the cheap size
  check and kept being handed them as verified for the remainder of its
  own window, up to 90 days. A slot’s own copy and a processed tree
  indict nothing but themselves.
- A cache hit is measured against the declaration in force as well as
  against the entry’s own record. A version whose declaration has moved
  to different bytes raises `getaca_error_redeclared` naming both
  checksums, rather than resolving quietly to the copy already held.
  `verify = TRUE` asks the same question, so a forced re-hash can no
  longer confirm bytes against a declaration they no longer match.
- Entry records keep `fetched_at`, `verified_at`, `checked_at` and
  `accessed_at` apart.
- Provenance records which declaration state resolved the bytes
  (`registry_digest`), when that state was published
  (`registry_created`) and which getaca acted on it (`getaca_version`).

### Checks

- [`getaca_available()`](https://gillescolling.com/getaca/reference/getaca-checks.md),
  [`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md),
  [`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md).
- [`getaca_prefetch()`](https://gillescolling.com/getaca/reference/getaca_prefetch.md)
  and the `GETACA_CACHE` environment variable for seeding CI and check
  runs.

### Cache management

- Bytes live once, in a content-addressed store at `blobs/sha256/`, and
  a version slot holds a name for them. Two packages declaring the same
  file keep one copy and separate dependency records. The store holds no
  metadata: what is still needed is derived from the package indexes
  rather than counted beside them.
- Everything the store owns is read-only, since a caller writing to a
  returned path would otherwise damage every package that shares those
  bytes. A caller needing a writable layout declares a
  [`processor()`](https://gillescolling.com/getaca/reference/processor.md),
  which gets its own slot.
- [`getaca_clean()`](https://gillescolling.com/getaca/reference/getaca-gc.md)
  and automatic collection after retrieval: broken material, abandoned
  transfers, superseded versions past retention, LRU eviction only above
  the size ceiling, and finally bytes no declaration references.
- The size ceiling measures what the cache occupies. Shared bytes count
  once, so two packages declaring one 4 GB file no longer count 8 GB
  against it.
- [`getaca_keep()`](https://gillescolling.com/getaca/reference/getaca_keep.md)
  to exempt a resource.
- [`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md):
  one table covering what packages declare and what the cache holds,
  including declared resources never downloaded and cached versions no
  longer declared. A `current` column marks the version a bare request
  resolves to.
- [`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md):
  full provenance for one cached resource.
