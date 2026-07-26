# getaca: Reproducible External Data Dependencies for R Packages

Lets an R package declare that it depends on data living somewhere else,
and makes that dependency behave like a dependency: pinned to exact
bytes, resolvable offline, and safe during `R CMD check`.

## The four responsibilities

- Get:

  Resolve mirrors, download safely, return an ordinary local path.

- Authenticate:

  Verify the exact expected bytes before the path is handed back.
  Throughout the API this operation is called *verify*; "authentication"
  is reserved for credentials.

- Track:

  Record version, registry revision, resolution policy, observed
  checksum and verification state.

- Cache:

  Reuse resources across sessions and actively remove obsolete material,
  as CRAN policy requires.

## Identity

A resource is identified by the triple `package / name / version`, never
by name alone. Two packages may declare the same physical file; their
dependency records stay separate.

## See also

Useful links:

- <https://gillescolling.com/getaca/>

- <https://github.com/gcol33/getaca>

- Report bugs at <https://github.com/gcol33/getaca/issues>

## Author

**Maintainer**: Gilles Colling <gilles.colling051@gmail.com>
([ORCID](https://orcid.org/0000-0003-3070-6066)) \[copyright holder\]

Authors:

- Gilles Colling <gilles.colling051@gmail.com>
  ([ORCID](https://orcid.org/0000-0003-3070-6066)) \[copyright holder\]
