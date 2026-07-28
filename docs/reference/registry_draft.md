# Draft a registry from where the data is

Takes locations, returns a
[`registry()`](https://gillescolling.com/getaca/reference/registry.md)
with every checksum filled in. What it saves is the part of authoring
that cannot be done by hand: a SHA-256 has to be computed from the
bytes, which means retrieving them.

## Usage

``` r
registry_draft(
  x,
  package,
  version = NULL,
  source = "auto",
  keep = FALSE,
  quiet = FALSE,
  ...
)
```

## Arguments

- x:

  Locations. A character vector, where each element is one location, or
  a list, where each element is a character vector of mirrors for one
  resource. Names, if any, name the resources.

- package:

  Declaring package name.

- version:

  Version label for every resource drafted. Optional where the archive
  supplies one, required for a plain URL.

- source:

  Which handler to use: `"auto"`, or one of `"zenodo"`, `"figshare"`,
  `"dataverse"`, `"url"` to override the detection.

- keep:

  Keep the downloaded bytes in the cache, so that a later
  [`getaca()`](https://gillescolling.com/getaca/reference/getaca.md)
  call for the drafted resource finds them already there instead of
  transferring them a second time.

- quiet:

  Suppress transfer progress.

- ...:

  Passed to
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md),
  for `remote`, `policy`, `keys` and `auth`.

## Value

A `getaca_registry`.

## Details

A location is a plain URL, or an identifier for a data archive that
holds several files. Which one it is, and which archive, is read off the
string, so one call covers both:

    registry_draft("10.5281/zenodo.17844561", package = "yourpkg")
    registry_draft(c(backbone = "https://example.org/backbone.parquet"),
                   package = "yourpkg", version = "2026.1")

Every file is downloaded once and hashed locally. Checksums an archive
reports are not used: they are md5 at all three archives supported here,
and they arrive from the host that serves the bytes, so they say nothing
the transfer itself has not already said.

This is an authoring tool. Nothing in the retrieval path calls it, and a
drafted registry names ordinary `https://` locations, so an archive is
consulted when the registry is written and never when a user fetches.

## Archives

- Zenodo:

  `"10.5281/zenodo.17844561"` or a `https://zenodo.org/records/...` URL.
  Version defaults to the record id, which Zenodo mints afresh for each
  version.

- figshare:

  `"10.6084/m9.figshare.14763051.v1"` or a
  `https://figshare.com/articles/...` URL. A DOI without a `.vN` suffix
  resolves to whatever figshare currently calls latest, and the version
  it served is what the draft records.

- Dataverse:

  A dataset DOI, or a `https://<host>/dataset.xhtml?persistentId=...`
  URL. Instances are self-hosted under their own DOI prefixes, so a bare
  DOI is resolved through `doi.org` to find which host to ask. The other
  two are recognised from the string alone and cost no such lookup.

## What to edit afterwards

A draft is a starting point. Resources are named after their files,
which is rarely the name you want a user to type, and `description` is
left empty. Both are ordinary arguments of
[`resource()`](https://gillescolling.com/getaca/reference/resource.md);
edit the call, or edit the returned registry, and write it with
[`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md).

## See also

[`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md)
to ship it,
[`registry_sign()`](https://gillescolling.com/getaca/reference/registry_sign.md)
to sign it.

## Examples

``` r
if (FALSE) { # \dontrun{
reg <- registry_draft("10.5281/zenodo.17844561", package = "yourpkg")
registry_write(reg, "inst/getaca/registry.rds")
} # }
```
