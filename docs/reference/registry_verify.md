# Verify a signed registry file

Checks a registry against the detached signature beside it. Returns
`TRUE` or raises `getaca_error_signature` naming what failed.

## Usage

``` r
registry_verify(path, keys = NULL, now = Sys.time())
```

## Arguments

- path:

  Path to a registry file.

- keys:

  Public keys to accept, as returned by
  [`registry_keygen()`](https://gillescolling.com/getaca/reference/registry_keygen.md).
  Defaults to the keys the registry declares.

- now:

  Time to judge expiry against.

## Value

`TRUE`, invisibly.

## Details

This is the check resolution performs on a fetched remote registry,
exposed so an author can run it on their own output before publishing.
In resolution the trusted keys come from the bundled registry; here they
default to the keys the file itself declares, which answers whether a
registry is internally consistent rather than whether it is authentic.

## See also

[`registry_sign()`](https://gillescolling.com/getaca/reference/registry_sign.md)
