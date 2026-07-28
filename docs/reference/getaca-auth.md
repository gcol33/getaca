# Declaring a credential without holding one

Some versioned scientific files are served only to a registered account.
A declaration can say which credential a host requires without ever
carrying one: `bearer()` and `basic()` name environment variables, and
`auth_host()` binds a scheme to the host it applies to.

## Usage

``` r
bearer(variable)

basic(user, password)

auth_host(host, scheme, register = NULL)
```

## Arguments

- variable:

  Name of the environment variable holding the token. The variable name
  is the declaration; its value never enters the registry.

- user:

  Name of the environment variable holding the user name.

- password:

  Name of the environment variable holding the password.

- host:

  Host the credential applies to, as it appears in the URL, for example
  `"data.example.org"`. Matched exactly, without wildcards.

- scheme:

  A `bearer()` or `basic()` declaration.

- register:

  Optional URL where a user obtains a credential. Reported when one is
  missing or refused, and part of the manifest so that a signed registry
  covers it.

## Value

`bearer()` and `basic()` return a `getaca_auth_scheme`; `auth_host()`
returns a `getaca_auth_host`.

## Details

A credential belongs to a host rather than to a file. One record may
list a mirror behind a token beside a public one, and several records
routinely share a credential, so the declaration sits on the
[`registry()`](https://gillescolling.com/getaca/reference/registry.md)
and is matched by host. Parts are matched by the same rule, since a
part's URLs are URLs.

## What getaca will not do

The credential is read from the environment at the moment of the request
and is never stored, never written to the cache, never recorded in
provenance and never printed. It is sent as an `Authorization` header
and to nothing but the declared host: libcurl withholds that header from
a redirect to a different host, which is what a query-string token could
not offer and is why one is not accepted here.

Hosts are matched exactly and there is no wildcard, so a declaration can
never widen the set of hosts that receive a credential.

## Examples

``` r
bearer("EXAMPLE_TOKEN")
basic("EXAMPLE_USER", "EXAMPLE_PASSWORD")
auth_host("data.example.org", bearer("EXAMPLE_TOKEN"),
          register = "https://data.example.org/register")
```
