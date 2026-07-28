# Behave during checks, examples and tests

CRAN policy requires that a package using Internet resources "fail
gracefully with an informative message if the resource is not available
or has changed (and not give a check warning nor error)". These three
helpers answer three different questions, so a package can satisfy that
in every context without writing its own availability logic.

## Usage

``` r
getaca_available(
  name,
  package = NULL,
  registry = NULL,
  version = NULL,
  processed = TRUE
)

getaca_optional(
  name,
  package = NULL,
  registry = NULL,
  version = NULL,
  processed = TRUE,
  quiet = FALSE
)

getaca_skip_if_unavailable(
  name,
  package = NULL,
  registry = NULL,
  version = NULL,
  processed = TRUE
)
```

## Arguments

- name:

  Resource name as declared by `package`.

- package:

  Declaring package. The resource identity is
  `package / name / version`, so two packages declaring the same name
  never collide.

- registry:

  A
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  object, for standalone use without a declaring package.

- version:

  Explicit version, bypassing channel resolution. Use this to hold an
  analysis to one release.

- processed:

  Apply the declared
  [`processor()`](https://gillescolling.com/getaca/reference/processor.md),
  when there is one, and return the processed path. `FALSE` returns the
  raw artefact.

- quiet:

  Report nothing for this call, whatever
  [`getaca_progress()`](https://gillescolling.com/getaca/reference/getaca_progress.md)
  is set to.

## Value

`getaca_available()` returns `TRUE` when the resource is cached and
passes its cheap integrity check.

`getaca_optional()` returns a path, or `NULL` when the resource is
unavailable.

`getaca_skip_if_unavailable()` returns `NULL` invisibly, or signals a
testthat skip.

## Details

- `getaca_available()`:

  Is this resource usable right now, without touching the network?
  Returns a logical.

- `getaca_optional()`:

  Give me the path if you have it. Returns `NULL` with a message
  otherwise, and never errors. For examples and vignettes.

- `getaca_skip_if_unavailable()`:

  Skip this test, naming the missing dependency and how to prefetch it.
  For testthat.

## Examples

``` r
getaca_available("nothing-here", package = "getaca")
```
