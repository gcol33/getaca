# Read and write registry files

The stored form is an R object serialised with
[`saveRDS()`](https://rdrr.io/r/base/readRDS.html). YAML and JSON are
supported as optional authoring formats only; they never define the
internal model and never become a hard dependency.

## Usage

``` r
registry_write(registry, path)

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

## Value

`registry_write()` returns `path` invisibly. `registry_read()` returns a
`getaca_registry`.
