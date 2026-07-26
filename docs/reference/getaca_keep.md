# Keep a resource from being collected

Keep a resource from being collected

## Usage

``` r
getaca_keep(
  name,
  package = NULL,
  registry = NULL,
  version = NULL,
  processed = TRUE,
  pinned = TRUE
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

- pinned:

  Set `FALSE` to release the pin.

## Value

The updated entry, invisibly.
