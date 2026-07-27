# Signing a registry

A
[`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md)
says whether two declarations are the same. It says nothing about who
wrote one, because it travels inside the file it describes: whoever
rewrites the registry rewrites the digest. A signature is what carries
authorship, and it works only because the key it is checked against
arrives by a different route than the registry does.

## Details

That route already exists. A declaring package ships its registry at
`inst/getaca/registry.rds`, installed from CRAN or from wherever the
user installs packages, while the remote registry comes from a host the
author operates. Putting the author's public key in the bundled registry
means an attacker who controls the host does not control the key, which
is the whole of what signing buys.

## What is signed

The bytes
[`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md)
hashes, which is to say
[`registry_manifest()`](https://gillescolling.com/getaca/reference/registry_manifest.md).
The signature file additionally binds the publication time and an
expiry, neither of which is part of the manifest:

    getaca-signature 1
    digest sha256:3f9ac2...
    created 2026-07-27T10:00:00Z
    expires 2026-10-25T10:00:00Z
    key ed25519:9f8a...
    sig ed25519:4c2b...

Everything above the `sig` line is what the signature covers. Binding
`created` is what stops a rollback: an attacker who cannot forge a
signature can still serve an older one forever, and a signed publication
time plus a signed expiry is what bounds that. `expires` is a statement
about the declaration's freshness rather than about the key, so
re-signing an unchanged registry is the ordinary way to extend it.

## Rotation

The trusted keys are the ones in the *bundled* registry. A remote
registry may declare further keys, and they are covered by the
signature, but they do not become trusted until a release ships them in
the bundled declaration. Rotating therefore means publishing the new key
alongside the old, signing with the old, releasing, and retiring the old
key once the release is out. Nothing about a key is remembered between
sessions, so there is no key history to go stale and no state a wrong
answer could persist into.
