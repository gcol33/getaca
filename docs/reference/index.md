# Package index

## Retrieval

The single front door

- [`getaca()`](https://gillescolling.com/getaca/reference/getaca.md) :
  Get a declared external resource
- [`getaca_prefetch()`](https://gillescolling.com/getaca/reference/getaca_prefetch.md)
  : Warm the cache ahead of time

## Progress

What a transfer looks like

- [`getaca-progress`](https://gillescolling.com/getaca/reference/getaca-progress.md)
  : How a transfer reports itself
- [`getaca_progress()`](https://gillescolling.com/getaca/reference/getaca_progress.md)
  : Choose how transfers report progress
- [`reporter()`](https://gillescolling.com/getaca/reference/reporter.md)
  : Write a progress reporter

## Declaration

What a package says it needs

- [`resource()`](https://gillescolling.com/getaca/reference/resource.md)
  : Declare an immutable resource record
- [`resource_id()`](https://gillescolling.com/getaca/reference/resource_id.md)
  : Identify a resource
- [`part()`](https://gillescolling.com/getaca/reference/part.md) :
  Declare one part of a resource
- [`combiner()`](https://gillescolling.com/getaca/reference/combiner.md)
  : Declare how parts are combined
- [`processor()`](https://gillescolling.com/getaca/reference/processor.md)
  : Declare a post-download processor
- [`unpack()`](https://gillescolling.com/getaca/reference/unpack.md) :
  Unpack an archive or a compressed file
- [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  : Declare a package's external resources
- [`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md)
  [`registry_read()`](https://gillescolling.com/getaca/reference/registry_write.md)
  : Read and write registry files
- [`registry_for()`](https://gillescolling.com/getaca/reference/registry_for.md)
  : Find the registry a package ships
- [`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md)
  : Content identity of a registry
- [`registry_manifest()`](https://gillescolling.com/getaca/reference/registry_manifest.md)
  : The canonical form a registry hashes to
- [`as_registry()`](https://gillescolling.com/getaca/reference/as_registry.md)
  : Convert an authoring format into a registry
- [`getaca_refresh()`](https://gillescolling.com/getaca/reference/getaca_refresh.md)
  : Forget cached registry state

## Resolution

Which record a name resolves to

- [`resolve_resource()`](https://gillescolling.com/getaca/reference/resolve_resource.md)
  : Resolve a name to an immutable resource record
- [`getaca_policy()`](https://gillescolling.com/getaca/reference/getaca_policy.md)
  : Resolution policy and settings
- [`getaca_pin()`](https://gillescolling.com/getaca/reference/getaca_pin.md)
  : Freeze current resolution into a pin file

## Signing

Who a remote registry came from

- [`getaca-signing`](https://gillescolling.com/getaca/reference/getaca-signing.md)
  : Signing a registry
- [`registry_keygen()`](https://gillescolling.com/getaca/reference/registry_keygen.md)
  : Create a signing key
- [`registry_sign()`](https://gillescolling.com/getaca/reference/registry_sign.md)
  : Sign a registry file
- [`registry_verify()`](https://gillescolling.com/getaca/reference/registry_verify.md)
  : Verify a signed registry file

## Checks and Offline Use

Behaving during R CMD check

- [`getaca_available()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
  [`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
  [`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
  : Behave during checks, examples and tests

## Provenance

Where a file came from

- [`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md)
  : Provenance for a resource
- [`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md)
  : What is declared, and what is cached

## Cache Management

Retention and removal

- [`getaca_clean()`](https://gillescolling.com/getaca/reference/getaca-gc.md)
  : Active cache management
- [`getaca_keep()`](https://gillescolling.com/getaca/reference/getaca_keep.md)
  : Keep a resource from being collected
- [`getaca_cache_dir()`](https://gillescolling.com/getaca/reference/getaca_cache_dir.md)
  : Where getaca stores things

## Conditions

The failure taxonomy

- [`getaca-conditions`](https://gillescolling.com/getaca/reference/getaca-conditions.md)
  : Failure taxonomy
