# Provenance for a resource

Answers, for a cached resource: which package declared it, which
registry state and which policy resolved it, the exact version, declared
and observed checksums, which mirror served it, when it was fetched and
when it was last fully verified, its license, any processor applied,
which getaca retrieved it, and the local path. Suitable for a
reproducibility appendix or a bug report.

## Usage

``` r
getaca_info(
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

## Value

A `getaca_entry`, or `NULL` when the resource is not cached.

## Details

The registry state appears as a
[`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md),
so the declaration that resolved the resource can be identified exactly
rather than by a number someone kept in step by hand.
