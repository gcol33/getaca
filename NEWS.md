# getaca 0.0.0.9000

First development version. The v1 boundary is set; nothing here has been
released.

## Declaration
* `resource()`: immutable record of exact bytes, with version, mirrors,
  SHA-256, size, license, upstream identity and optional processor.
* `registry()`, `registry_write()`, `registry_read()`, `registry_for()`:
  package-scoped declarations, discovered by convention at
  `inst/getaca/registry.rds`.
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
* `getaca_pin()`: freeze current resolution into a local snapshot.
* Remote channels may repair mirrors and publish new versions; redefining a
  published version is rejected as an invalid registry.

## Retrieval
* `getaca()`: the single retrieval verb. Returns a local path.
* Resumable transfers into a temporary area, sized and hashed before an atomic
  move into the cache.
* Per-resource directory locking, so concurrent sessions never duplicate a
  large transfer or observe a partial one.
* Six classed conditions distinguishing user, author and upstream causes.

## Verification
* Full SHA-256 on download, cheap size check on access, scheduled re-hash via
  `getaca.verify_days`.
* Entry records keep `fetched_at`, `verified_at`, `checked_at` and
  `accessed_at` apart.

## Checks
* `getaca_available()`, `getaca_optional()`, `getaca_skip_if_unavailable()`.
* `getaca_prefetch()` and the `GETACA_CACHE` environment variable for seeding
  CI and check runs.

## Cache management
* `getaca_clean()` and automatic collection after retrieval: broken material,
  abandoned transfers, superseded versions past retention, then LRU eviction
  only above the size ceiling.
* `getaca_keep()` to exempt a resource.
* `getaca_catalogue()`: one table covering what packages declare and what the
  cache holds, including declared resources never downloaded and cached
  versions no longer declared.
* `getaca_info()`: full provenance for one cached resource.
