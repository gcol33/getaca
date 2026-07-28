# Declare an immutable resource record

A resource record names one concrete artefact: exact bytes, at one or
more locations, under one version label. Once published, a record is
immutable. If a publisher reissues the same nominal file with different
bytes that is an upstream mutation, not a routine update, and getaca
reports it as such.

## Usage

``` r
resource(
  name,
  version,
  urls = NULL,
  sha256,
  size = NA_real_,
  license = NA_character_,
  description = NA_character_,
  doi = NULL,
  upstream = NULL,
  processor = NULL,
  parts = NULL,
  combiner = NULL,
  file = NULL
)
```

## Arguments

- name:

  Resource name. Must be usable as a directory name.

- version:

  Version label for these exact bytes, for example `"2026.1"`.

- urls:

  Character vector of download locations, tried in order. All must be
  `https://`. Give this or `parts`.

- sha256:

  Lowercase hex SHA-256 of the artefact. For a record with `parts`, of
  the artefact they compose rather than of any one of them.

- size:

  Expected size in bytes, or `NA`. Used to detect truncated transfers
  before hashing.

- license:

  License identifier for the data, for example `"CC-BY-4.0"`.

- description:

  One-line human description.

- doi:

  Optional DOI for these bytes, for example `"10.5281/zenodo.1234567"`.
  A `https://doi.org/` or `doi:` prefix is accepted and stripped. This
  is what the artefact is cited as, and it travels into provenance; it
  never routes anything, and the locations to fetch from stay in `urls`.

- upstream:

  Optional named list identifying what these bytes were built from, when
  the artefact is derived rather than an original release. A prepared
  database records both its own build identity and the upstream release
  it was made from, and both travel into provenance.

- processor:

  Optional
  [`processor()`](https://gillescolling.com/getaca/reference/processor.md)
  applied after verification.

- parts:

  Optional list of
  [`part()`](https://gillescolling.com/getaca/reference/part.md)
  records, in the order they are combined. Give this or `urls`.

- combiner:

  Optional
  [`combiner()`](https://gillescolling.com/getaca/reference/combiner.md)
  turning the parts into the artefact. The default concatenates them,
  which is what a file split for a host with a size limit needs.

- file:

  Name the artefact is cached under. Defaults to the file name in the
  first URL, and is required alongside `parts`, where the URLs name the
  pieces rather than the result.

## Value

An object of class `getaca_resource`.

## Whole files and parts

A record names either locations for the whole file, in `urls`, or the
ordered series it is composed from, in `parts`. `sha256` describes the
artefact either way, so what a version means does not depend on how it
arrives. See
[`part()`](https://gillescolling.com/getaca/reference/part.md).

## Examples

``` r
resource(
  name = "wfo",
  version = "2026.1",
  urls = "https://example.org/wfo-2026.1.parquet",
  sha256 = strrep("a", 64),
  size = 1048576,
  license = "CC-BY-4.0"
)

# The same artefact, published as a base and the delta issued against it:
resource(
  name = "wfo",
  version = "2026.2",
  sha256 = strrep("b", 64),
  file = "wfo.parquet",
  parts = list(
    part("https://example.org/wfo-base.bin", sha256 = strrep("c", 64)),
    part("https://example.org/wfo-2026.2.bin", sha256 = strrep("d", 64))
  )
)
```
