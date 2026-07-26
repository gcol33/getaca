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

- `getaca_error_invalid_registry`:

  Malformed or internally inconsistent registry. actor: author.

- `getaca_error_declaration`:

  Several independent mirrors agreed with each other and disagreed with
  the declared checksum. actor: author.
