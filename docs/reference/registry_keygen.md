# Create a signing key

Generates an Ed25519 key pair, writes the secret half to `path`, and
returns the public half in the form
[`registry()`](https://gillescolling.com/getaca/reference/registry.md)
takes. The seed comes from the operating system's cryptographic random
source, not from R's generator, whose stream is reproducible by design.

## Usage

``` r
registry_keygen(path, seed = NULL)
```

## Arguments

- path:

  Where to write the secret key.

- seed:

  Optional 32 raw bytes to derive the key from, for tests that need a
  fixed key. Omit for a real key.

## Value

The public key, as `"ed25519:<hex>"`.

## Details

The secret file is the one thing in this package that must not be
published. It is written with owner-only permissions where the platform
has them, and belongs outside the package source tree so that no build
can sweep it up.

## See also

[`registry_sign()`](https://gillescolling.com/getaca/reference/registry_sign.md)

## Examples

``` r
file <- tempfile()
public <- registry_keygen(file)
substr(public, 1, 16)
unlink(file)
```
