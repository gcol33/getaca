# Sign a registry file

Signs the declaration in a written registry, producing a detached
signature beside it. Sign after
[`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md):
writing is what stamps `created`, and the signature binds that stamp.

## Usage

``` r
registry_sign(path, key, expires = Sys.time() + SIGNATURE_DAYS * 86400)
```

## Arguments

- path:

  Path to a registry file written by
  [`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md).

- key:

  Path to a secret key from
  [`registry_keygen()`](https://gillescolling.com/getaca/reference/registry_keygen.md).

- expires:

  When the signature stops being accepted. Re-sign an unchanged registry
  to extend it. `NA` signs without an expiry, which leaves nothing
  bounding how long a stale declaration is served.

## Value

The signature path, invisibly.

## Details

Publish the `.sig` alongside the registry it describes. getaca fetches
it from the registry's own URL with `.sig` appended.

## See also

[`registry_keygen()`](https://gillescolling.com/getaca/reference/registry_keygen.md),
[`registry_verify()`](https://gillescolling.com/getaca/reference/registry_verify.md)
