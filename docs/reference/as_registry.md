# Convert an authoring format into a registry

Accepts the list shape a YAML or JSON registry parses into. Requires the
`yaml` or `jsonlite` package only when reading those formats; neither is
a hard dependency.

## Usage

``` r
as_registry(x, package, ...)
```

## Arguments

- x:

  A list, or a path to a `.yml`, `.yaml` or `.json` file.

- package:

  Declaring package name.

- ...:

  Passed to
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md).

## Value

A `getaca_registry`.
