# Read and write registry files

The stored form is an R object serialised with
[`saveRDS()`](https://rdrr.io/r/base/readRDS.html). YAML and JSON are
supported as optional authoring formats only; they never define the
internal model and never become a hard dependency.

## Usage

``` r
registry_write(registry, path, created = Sys.time())

registry_read(path)
```

## Arguments

- registry:

  A
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  object.

- path:

  File path. For `registry_write()`, the conventional location inside a
  package source tree is `inst/getaca/registry.rds`.

- created:

  Publication time recorded in the file. Pass a fixed value to keep a
  build byte-reproducible.

## Value

`registry_write()` returns `path` invisibly. `registry_read()` returns a
`getaca_registry`.

## Details

Writing stamps `created`, since publishing a state is what dates it.
`created` is what orders two states in time, which a content digest
cannot do;
[`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md)
says whether two states are the same, and `created` says which came
first. It is deliberately outside the digest, so writing an unchanged
registry out again leaves its identity alone.
