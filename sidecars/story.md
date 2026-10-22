# Story: getaca

## Claim
getaca retrieves, verifies, caches and garbage-collects the large external files an R package
declares it needs, each pinned to a SHA-256 checksum and resolved through an explicit policy, so
the same installed package resolves the same bytes.

## Audience
R package authors whose package needs data too large or too fast-moving to ship (reference
datasets, trained models, example archives), and the users of those packages, who meet getaca
through the declaring package's own functions and error messages. Authors know package
development and `R CMD check`; they do not need to know content-addressed storage or Ed25519.

## Relation
- to: none as a parent. Neighbours: companion data packages, pins, BiocFileCache, pooch (Python),
  a hand-written downloader and cache directory.
- phrase: "one engine and many declarations"
- same: pooch also ships a registry of file names and hashes with the package
- differs: identity is package / name / version with the version labelling the data; channels
  move between releases; the declaration ships inside the installed package
- status: not a successor of anything
- home: vignettes/alternatives.Rmd
- context: none

## Arcs

### A1 Declare once, retrieve with one call
- question: "how do I make every user end up with the same copy of a file my package needs?"
- answer: `resource()` with name, version, URLs and checksum; `registry()`; `getaca()` returns a
  verified local path; `registry_draft()` takes the checksum from the bytes
- payoff: the reader declares a resource and retrieves it
- evidence: README usage chunk; quickstart.Rmd
- limits: the checksum has to come from the bytes
- home: vignettes/quickstart.Rmd, vignettes/declaring.Rmd
- also: README, DESCRIPTION

### A2 Surviving R CMD check and CI
- question: "how does a package with a 4 GB dependency pass CRAN checks?"
- answer: resolution collapses to `offline` under check; three helpers for tests, examples and
  vignettes; a pre-seeded `GETACA_CACHE` for CI
- payoff: the reader writes check-safe tests, examples and vignettes
- evidence: checks.Rmd
- home: vignettes/checks.Rmd
- also: README

### A3 Policies, channels and signing
- question: "can I repair a mirror or publish new data without a CRAN release?"
- answer: `bundled`, `current`, `pinned`, `offline`; a remote registry may move a channel head but
  never redefine a published version; it can be signed with Ed25519 against a key the package ships
- payoff: the reader chooses a policy and, if remote, signs it
- evidence: policies.Rmd
- home: vignettes/policies.Rmd
- also: README, DESCRIPTION

### A4 Failures that name who can fix them
- question: "what does my user see when a download fails?"
- answer: classed conditions, each with an `actor` field (user, author, upstream)
- payoff: the declaring package catches the ones its users meet and answers in its own words
- evidence: failures.Rmd
- home: vignettes/failures.Rmd
- also: README

### A5 A managed cache with provenance
- question: "where do the files go, and will the cache grow without bound?"
- answer: bytes stored once by checksum, read-only, admitted only after verification; provenance
  per entry; retention sweeps after every retrieval
- payoff: the reader inspects, keeps or cleans cached resources
- evidence: cache.Rmd
- home: vignettes/cache.Rmd
- also: README

## Non-goals
- getaca knows nothing about file formats and never reads data.
- No hosting: the files live on hosts the author chooses.

## Documents
- DESCRIPTION: listing text; claim, A3 (signing), standards cited
- README / landing: entry point; claim, first example, one section per arc, routing
- quickstart.Rmd: tutorial; the whole cycle
- declaring.Rmd, policies.Rmd, checks.Rmd, cache.Rmd, failures.Rmd: how-to, one arc each
- migrating.Rmd: how-to, an existing downloader to a declaration
- alternatives.Rmd: comparison, Relation home

## Open
- The verification-speed figure (SHA-256 with CPU instructions) is sourced only in dev_notes and
  NEWS; it is not in the README until an article holds the benchmark.
