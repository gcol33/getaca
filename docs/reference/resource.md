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
  urls,
  sha256,
  size = NA_real_,
  license = NA_character_,
  description = NA_character_,
  upstream = NULL,
  processor = NULL
)
```

## Arguments

- name:

  Resource name. Must be usable as a directory name.

- version:

  Version label for these exact bytes, for example `"2026.1"`.

- urls:

  Character vector of download locations, tried in order. All must be
  `https://`.

- sha256:

  Lowercase hex SHA-256 of the file as served.

- size:

  Expected size in bytes, or `NA`. Used to detect truncated transfers
  before hashing.

- license:

  License identifier for the data, for example `"CC-BY-4.0"`.

- description:

  One-line human description.

- upstream:

  Optional named list identifying what these bytes were built from, when
  the artefact is derived rather than an original release. A prepared
  database records both its own build identity and the upstream release
  it was made from, and both travel into provenance.

- processor:

  Optional
  [`processor()`](https://gillescolling.com/getaca/reference/processor.md)
  applied after verification.

## Value

An object of class `getaca_resource`.

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
```
