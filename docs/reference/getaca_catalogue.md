# What is declared, and what is cached

Reports both halves. Declared resources appear whether or not they have
ever been downloaded, so "what does this package need, and what do I
already have" is one table rather than two. Cached copies of versions
that are no longer declared appear as well, since those are what
[`getaca_clean()`](https://gillescolling.com/getaca/reference/getaca-gc.md)
reclaims.

## Usage

``` r
getaca_catalogue(package = NULL, registry = NULL)
```

## Arguments

- package:

  Restrict to one declaring package. `NULL` reports every installed
  package that ships a registry, together with any package holding
  cached resources.

- registry:

  A
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  object, for standalone use without an installed declaring package.

## Value

A data frame, one row per resource version. `current` marks the version
a bare request for that name resolves to, so a channel head is visible
rather than implied. `declared` is `TRUE` when the registry in force
names that version, `FALSE` when it does not, and `NA` when no registry
could be read for the package; `current` is `NA` in that same case.
`cached` says whether a local copy is recorded; the provenance columns
are `NA` for declared resources that are not cached. `link` says how the
slot reaches its bytes, so two packages sharing one copy in the store
are visible as such.

## Examples

``` r
reg <- registry("demo", list(
  resource("example", "1.0",
           urls = "https://example.org/example-1.0.csv",
           sha256 = strrep("c", 64))
))
getaca_catalogue(registry = reg)
```
