# Changelog

## getaca 0.0.0.9000

First development version. The v1 boundary is set; nothing here has been
released.

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
- [`getaca_pin()`](https://gillescolling.com/getaca/reference/getaca_pin.md):
  freeze current resolution into a local snapshot.
- Remote channels may repair mirrors and publish new versions;
  redefining a published version is rejected as an invalid registry.

### Retrieval

- [`getaca()`](https://gillescolling.com/getaca/reference/getaca.md):
  the single retrieval verb. Returns a local path.
- Resumable transfers into a temporary area, sized and hashed before an
  atomic move into the cache.
- Per-resource directory locking, so concurrent sessions never duplicate
  a large transfer or observe a partial one.
- Six classed conditions distinguishing user, author and upstream
  causes.

### Verification

- Full SHA-256 on download, cheap size check on access, scheduled
  re-hash via `getaca.verify_days`.
- Entry records keep `fetched_at`, `verified_at`, `checked_at` and
  `accessed_at` apart.

### Checks

- [`getaca_available()`](https://gillescolling.com/getaca/reference/getaca-checks.md),
  [`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md),
  [`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md).
- [`getaca_prefetch()`](https://gillescolling.com/getaca/reference/getaca_prefetch.md)
  and the `GETACA_CACHE` environment variable for seeding CI and check
  runs.

### Cache management

- [`getaca_clean()`](https://gillescolling.com/getaca/reference/getaca-gc.md)
  and automatic collection after retrieval: broken material, abandoned
  transfers, superseded versions past retention, then LRU eviction only
  above the size ceiling.
- [`getaca_keep()`](https://gillescolling.com/getaca/reference/getaca_keep.md)
  to exempt a resource.
- [`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md):
  one table covering what packages declare and what the cache holds,
  including declared resources never downloaded and cached versions no
  longer declared.
- [`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md):
  full provenance for one cached resource.
