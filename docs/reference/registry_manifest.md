# The canonical form a registry hashes to

Renders the declaration as a sorted, escaped, line-oriented text form
and returns its lines.
[`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md)
hashes exactly these bytes, so a digest is never a black box: two
registries that disagree can be diffed on the text that produced the
disagreement.

## Usage

``` r
registry_manifest(registry)
```

## Arguments

- registry:

  A
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  object.

## Value

A character vector of lines, classed `getaca_manifest`.

## Details

Hashing the R object directly is not an option. A
[`resource()`](https://gillescolling.com/getaca/reference/resource.md)
may carry a
[`processor()`](https://gillescolling.com/getaca/reference/processor.md),
which holds a closure, and a closure digests differently across machines
and builds because its environment, bytecode and source references
travel with it. A registry declaring a processor would appear to change
identity on every machine. The manifest reduces a processor to its `id`,
which is what the declaration actually promises.

## Format

The first line names the format version, which moves independently of
`schema_version` because the two change for different reasons: a new
field in the stored form need not change how existing fields are
rendered.

    getaca-manifest 1
    package taxify
    remote https://taxify.example.org/registry.rds
    key ed25519:9f8a...
    current wfo 2026-09
    resource wfo 2026-06
      sha256 3f9ac2...
      size 1048576
      license CC-BY-4.0
      url https://zenodo.org/record/123/wfo-2026-06.parquet
      url https://mirror.example.org/wfo-2026-06.parquet
      upstream release 2026-06
      processor unzip-v2

Resources are sorted by `name@version` in the C locale, so the same
declaration renders identically wherever it is read. URLs keep
declaration order, which is load-bearing: mirrors are tried in the order
given. Signing keys are sorted, since which one signs is a fact about
the signature rather than about the declaration. Absent and `NA` fields
are omitted rather than rendered as empty, since a key that is present
carries a value by construction.

Rendering an absent field as nothing is what let signing keys join the
manifest without a new format version. A registry declaring none renders
exactly the bytes it always did, so every digest recorded before keys
existed still identifies the state that produced it. Only a registry
that actually carries a key renders a line for one, and none did before
the field existed.

## What is left out

`created` and `policy` are not part of the declaration. `created` says
when a state was written and `policy` supplies a default; neither
changes which bytes a name resolves to, and including either would mean
an unchanged registry took on a new identity for writing it out again.
`description` is prose, so a typo fix would invalidate a digest already
recorded in provenance.

## See also

[`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md)

## Examples

``` r
reg <- registry("demo", list(
  resource("example", "1.0",
           urls = "https://example.org/example-1.0.csv",
           sha256 = strrep("c", 64), license = "CC0-1.0")
))
registry_manifest(reg)
```
