# Failure taxonomy

Every failure raised by getaca carries a subclass naming the situation
and an `actor` field naming who can act on it: `"user"`, `"author"` or
`"upstream"`. Callers can therefore branch on the cause rather than on
message text.

## Conditions

- `getaca_error_unavailable`:

  No mirror could be reached. actor: user.

- `getaca_error_incomplete`:

  Transfer ended short of the expected size. actor: user.

- `getaca_error_upstream_changed`:

  A complete download hashed to something other than the declared
  checksum, and the declaration is otherwise sound. actor: upstream.

- `getaca_error_cache_corrupt`:

  The cached copy no longer matches its own entry record. actor: user
  (refetch).

- `getaca_error_redeclared`:

  The declaration now names different bytes for a version already held,
  so the two cannot both be that version. actor: author.

- `getaca_error_invalid_registry`:

  Malformed or internally inconsistent registry. actor: author.

- `getaca_error_declaration`:

  Several independent mirrors agreed with each other and disagreed with
  the declared checksum. actor: author.

- `getaca_error_signature`:

  A registry that must be signed carried no usable signature from a
  trusted key. actor: author.

## Reachability and authenticity

A remote registry that cannot be reached is an availability problem, and
resolution falls back to the bundled declaration with a message. A
remote registry that arrives and fails its signature is an integrity
problem, and resolution stops. The two are deliberately not the same:
falling back on a failed signature would work, in that the bundled
registry is trustworthy, but it would silently discard the one event the
signature exists to report.
