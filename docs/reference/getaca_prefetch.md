# Warm the cache ahead of time

Downloads and verifies without returning anything, so a connected
machine can prepare a cache that a check run, a CI job or an offline
session will then find already populated.

## Usage

``` r
getaca_prefetch(names = NULL, package = NULL, registry = NULL, quiet = FALSE)
```

## Arguments

- names:

  Resource names. `NULL` prefetches everything the package declares.

- package:

  Declaring package. The resource identity is
  `package / name / version`, so two packages declaring the same name
  never collide.

- registry:

  A
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  object, for standalone use without a declaring package.

- quiet:

  Report nothing for this call, whatever
  [`getaca_progress()`](https://gillescolling.com/getaca/reference/getaca_progress.md)
  is set to.

## Value

A character vector of paths named by resource, invisibly.

## Details

The resources of one call are transferred together, up to
`getaca.connections` at a time, and a file two of them name is moved
once. One that cannot be retrieved does not stop the others: everything
that could be had is cached before the first failure is raised.
