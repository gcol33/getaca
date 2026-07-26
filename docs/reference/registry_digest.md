# Content identity of a registry

The digest of a registry's
[`registry_manifest()`](https://gillescolling.com/getaca/reference/registry_manifest.md).
This is what identifies a declaration state: it is derived from the
declaration rather than asserted alongside it, so it cannot be typed
wrong, cannot go stale, and cannot claim that two different states are
the same one. Provenance records it for every retrieved resource, so a
cached file can always be traced to the exact declaration that resolved
it.

## Usage

``` r
registry_digest(registry)
```

## Arguments

- registry:

  A
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  object.

## Value

A single string: an algorithm name, a colon, and lowercase hex.

## Details

The value is self-describing, as in `"sha256:3f9ac2..."`, so the
algorithm can change later without changing the shape of anything that
stores one.

A digest says whether two registries are the same. It does not say which
is newer; `created` answers that. It also carries no authenticity: a
digest travelling inside the file it describes is rewritten by anyone
who rewrites the file. What stops a remote registry from redefining
published bytes is the per-resource checksum comparison in
[`resolve_resource()`](https://gillescolling.com/getaca/reference/resolve_resource.md),
which names the offending resource rather than reporting that something,
somewhere, moved.

## See also

[`registry_manifest()`](https://gillescolling.com/getaca/reference/registry_manifest.md)
for the exact bytes hashed.

## Examples

``` r
reg <- registry("demo", list(
  resource("example", "1.0",
           urls = "https://example.org/example-1.0.csv",
           sha256 = strrep("c", 64))
))
registry_digest(reg)
```
