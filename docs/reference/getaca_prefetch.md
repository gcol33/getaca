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

  Suppress progress reporting.

## Value

A character vector of paths, invisibly.
