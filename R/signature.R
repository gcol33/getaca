#' Signing a registry
#'
#' A [registry_digest()] says whether two declarations are the same. It says
#' nothing about who wrote one, because it travels inside the file it
#' describes: whoever rewrites the registry rewrites the digest. A signature is
#' what carries authorship, and it works only because the key it is checked
#' against arrives by a different route than the registry does.
#'
#' That route already exists. A declaring package ships its registry at
#' `inst/getaca/registry.rds`, installed from CRAN or from wherever the user
#' installs packages, while the remote registry comes from a host the author
#' operates. Putting the author's public key in the bundled registry means an
#' attacker who controls the host does not control the key, which is the whole
#' of what signing buys.
#'
#' @section What is signed:
#' The bytes [registry_digest()] hashes, which is to say [registry_manifest()].
#' The signature file additionally binds the publication time and an expiry,
#' neither of which is part of the manifest:
#'
#' ```
#' getaca-signature 1
#' digest sha256:3f9ac2...
#' created 2026-07-27T10:00:00Z
#' expires 2026-10-25T10:00:00Z
#' key ed25519:9f8a...
#' sig ed25519:4c2b...
#' ```
#'
#' Everything above the `sig` line is what the signature covers. Binding
#' `created` is what stops a rollback: an attacker who cannot forge a signature
#' can still serve an older one forever, and a signed publication time plus a
#' signed expiry is what bounds that. `expires` is a statement about the
#' declaration's freshness rather than about the key, so re-signing an unchanged
#' registry is the ordinary way to extend it.
#'
#' @section Rotation:
#' The trusted keys are the ones in the *bundled* registry. A remote registry
#' may declare further keys, and they are covered by the signature, but they do
#' not become trusted until a release ships them in the bundled declaration.
#' Rotating therefore means publishing the new key alongside the old, signing
#' with the old, releasing, and retiring the old key once the release is out.
#' Nothing about a key is remembered between sessions, so there is no key
#' history to go stale and no state a wrong answer could persist into.
#'
#' @name getaca-signing
#' @keywords internal
NULL

SIGNATURE_FORMAT <- 1L

# The compiled primitives, in src/ed25519.c and src/sha512.c. Named here for
# the same reason sha256_file() is named in verify.R: a .Call in the middle of
# an adjudication reads as machinery rather than as the question being asked.
# `seed` is NULL for a real key, which takes its bytes from the operating
# system, and fixed only where a test drives a published vector.
ed25519_keypair <- function(seed = NULL) .Call(C_ed25519_keypair, seed)
ed25519_sign    <- function(message, secret) .Call(C_ed25519_sign, message, secret)
ed25519_verify  <- function(sig, message, public) .Call(C_ed25519_verify, sig, message, public)
sha512_bytes    <- function(bytes) .Call(C_sha512_raw, bytes)

# 90 days, matching the re-verification window in options.R. Both answer the
# same question about how long an earlier check stays evidence.
SIGNATURE_DAYS <- 90

raw_to_hex <- function(x) paste(sprintf("%02x", as.integer(x)), collapse = "")

hex_to_raw <- function(x) {
  if (!is_string(x) || nchar(x) %% 2L != 0L || !grepl("^[0-9a-f]*$", x)) return(NULL)
  if (!nzchar(x)) return(raw(0))
  pairs <- substring(x, seq(1L, nchar(x), by = 2L), seq(2L, nchar(x), by = 2L))
  as.raw(strtoi(pairs, 16L))
}

# An algorithm name and lowercase hex, the shape registry_digest() already
# uses, so a key or a signature says what it is rather than relying on length.
tagged_bytes <- function(x, algorithm, bytes) {
  if (!is_string(x)) return(NULL)
  parts <- strsplit(x, ":", fixed = TRUE)[[1]]
  if (length(parts) != 2L || !identical(parts[1], algorithm)) return(NULL)
  raw <- hex_to_raw(parts[2])
  if (is.null(raw) || length(raw) != bytes) return(NULL)
  raw
}

public_key_bytes <- function(x) tagged_bytes(x, "ed25519", 32L)
signature_bytes  <- function(x) tagged_bytes(x, "ed25519", 64L)
secret_key_bytes <- function(x) tagged_bytes(x, "ed25519", 64L)

is_public_key <- function(x) !is.null(public_key_bytes(x))

format_utc <- function(t) format(as.POSIXct(t), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

parse_utc <- function(x) {
  if (!is_string(x)) return(NULL)
  t <- as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  if (is.na(t)) NULL else t
}

#' Create a signing key
#'
#' Generates an Ed25519 key pair, writes the secret half to `path`, and returns
#' the public half in the form [registry()] takes. The seed comes from the
#' operating system's cryptographic random source, not from R's generator,
#' whose stream is reproducible by design.
#'
#' The secret file is the one thing in this package that must not be published.
#' It is written with owner-only permissions where the platform has them, and
#' belongs outside the package source tree so that no build can sweep it up.
#'
#' @param path Where to write the secret key.
#' @param seed Optional 32 raw bytes to derive the key from, for tests that
#'   need a fixed key. Omit for a real key.
#'
#' @return The public key, as `"ed25519:<hex>"`.
#' @seealso [registry_sign()]
#' @export
#'
#' @examples
#' file <- tempfile()
#' public <- registry_keygen(file)
#' substr(public, 1, 16)
#' unlink(file)
registry_keygen <- function(path, seed = NULL) {
  stopifnot(is_string(path))
  if (!is.null(seed)) {
    if (!is.raw(seed) || length(seed) != 32L) {
      stop("`seed` must be 32 raw bytes.", call. = FALSE)
    }
  }
  pair <- ed25519_keypair(seed)
  public <- paste0("ed25519:", raw_to_hex(pair$public))

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(
    paste("getaca-key", SIGNATURE_FORMAT),
    paste0("public ", public),
    paste0("secret ed25519:", raw_to_hex(pair$secret))
  ), path)
  # Best effort: a filesystem without owner-only permissions is not a reason to
  # refuse to make a key, but it is a reason not to pretend the file is private.
  try(Sys.chmod(path, "0600"), silent = TRUE)

  public
}

read_key_file <- function(path) {
  if (!file.exists(path)) {
    stop(sprintf("No signing key at %s. Create one with registry_keygen().", path),
         call. = FALSE)
  }
  lines <- readLines(path, warn = FALSE)
  values <- key_values(lines)
  secret <- secret_key_bytes(values[["secret"]])
  if (is.null(secret)) {
    stop(sprintf("The signing key at %s is not readable as one.", path), call. = FALSE)
  }
  list(secret = secret, public = values[["public"]])
}

# One space-separated key and value per line, which is the manifest's own shape.
key_values <- function(lines) {
  lines <- lines[nzchar(lines)]
  keys <- sub(" .*$", "", lines)
  vals <- sub("^[^ ]* ?", "", lines)
  stats::setNames(as.list(vals), keys)
}

#' Sign a registry file
#'
#' Signs the declaration in a written registry, producing a detached signature
#' beside it. Sign after [registry_write()]: writing is what stamps `created`,
#' and the signature binds that stamp.
#'
#' Publish the `.sig` alongside the registry it describes. getaca fetches it
#' from the registry's own URL with `.sig` appended.
#'
#' @param path Path to a registry file written by [registry_write()].
#' @param key Path to a secret key from [registry_keygen()].
#' @param expires When the signature stops being accepted. Re-sign an unchanged
#'   registry to extend it. `NA` signs without an expiry, which leaves nothing
#'   bounding how long a stale declaration is served.
#'
#' @return The signature path, invisibly.
#' @seealso [registry_keygen()], [registry_verify()]
#' @export
registry_sign <- function(path, key,
                          expires = Sys.time() + SIGNATURE_DAYS * 86400) {
  stopifnot(is_string(path), is_string(key))
  registry <- registry_read(path)
  if (is.null(registry$created)) {
    stop("This registry carries no `created` stamp; write it with registry_write() first.",
         call. = FALSE)
  }
  secret <- read_key_file(key)

  signed <- signature_head(
    digest = registry_digest(registry),
    created = registry$created,
    expires = expires
  )
  # The public half travels in the signature so a reader can say which key was
  # used before deciding whether it trusts it, which is what lets a rotation
  # name the key that failed.
  public <- paste0("ed25519:", raw_to_hex(secret$secret[33:64]))
  signed <- c(signed, paste0("key ", public))

  sig <- ed25519_sign(signature_payload(signed), secret$secret)
  out <- signature_path(path)
  writeLines(c(signed, paste0("sig ed25519:", raw_to_hex(sig))), out)
  invisible(out)
}

signature_path <- function(path) paste0(path, ".sig")

signature_head <- function(digest, created, expires) {
  c(
    paste("getaca-signature", SIGNATURE_FORMAT),
    paste0("digest ", digest),
    paste0("created ", format_utc(created)),
    if (!is.null(expires) && !is.na(expires)) paste0("expires ", format_utc(expires))
  )
}

# The exact bytes a signature covers. Explicitly UTF-8 for the same reason
# registry_digest() is: a session's native encoding must not decide what was
# signed.
signature_payload <- function(lines) {
  charToRaw(enc2utf8(paste0(paste(lines, collapse = "\n"), "\n")))
}

# NULL for anything that is not a signature, a missing file included: the
# caller is asking whether one is there to be checked, and every no is the
# same answer.
signature_read <- function(path) {
  if (!file.exists(path)) return(NULL)
  lines <- readLines(path, warn = FALSE)
  lines <- lines[nzchar(lines)]
  if (!length(lines) || !grepl("^getaca-signature ", lines[1])) return(NULL)

  format <- suppressWarnings(as.integer(sub("^getaca-signature ", "", lines[1])))
  if (is.na(format)) return(NULL)
  at <- match("sig", sub(" .*$", "", lines))
  if (is.na(at)) return(NULL)

  values <- key_values(lines)
  list(
    format  = format,
    digest  = values[["digest"]],
    created = values[["created"]],
    expires = values[["expires"]],
    key     = values[["key"]],
    sig     = values[["sig"]],
    # Everything above the sig line, which is what was signed. Taken from the
    # file as read rather than re-rendered, so a field this getaca does not
    # know about is still covered by the check.
    payload = signature_payload(lines[seq_len(at - 1L)])
  )
}

#' Verify a signed registry file
#'
#' Checks a registry against the detached signature beside it. Returns `TRUE`
#' or raises `getaca_error_signature` naming what failed.
#'
#' This is the check resolution performs on a fetched remote registry, exposed
#' so an author can run it on their own output before publishing. In resolution
#' the trusted keys come from the bundled registry; here they default to the
#' keys the file itself declares, which answers whether a registry is
#' internally consistent rather than whether it is authentic.
#'
#' @param path Path to a registry file.
#' @param keys Public keys to accept, as returned by [registry_keygen()].
#'   Defaults to the keys the registry declares.
#' @param now Time to judge expiry against.
#'
#' @return `TRUE`, invisibly.
#' @seealso [registry_sign()]
#' @export
registry_verify <- function(path, keys = NULL, now = Sys.time()) {
  registry <- registry_read(path)
  sig <- signature_read(signature_path(path))
  if (is.null(sig)) {
    err_signature(
      registry$package,
      sprintf("no readable signature beside %s", path)
    )
  }
  problem <- signature_problem(sig, registry, keys %||% registry$keys, now)
  if (!is.null(problem)) err_signature(registry$package, problem)
  invisible(TRUE)
}

# The adjudication, separated from every source of bytes so it can be driven
# directly. Returns NULL when the signature stands, and one line naming the
# first thing that failed otherwise.
#
# Order is not cosmetic. Nothing a signature asserts means anything until the
# signature itself verifies, so the cryptography comes before the fields it
# covers, and the fields come before the freshness they carry.
signature_problem <- function(sig, registry, keys, now = Sys.time(),
                              floor = NULL) {
  if (sig$format > SIGNATURE_FORMAT) {
    return(sprintf(
      "the signature uses format %d, which is newer than this getaca reads (%d); upgrade getaca",
      sig$format, SIGNATURE_FORMAT
    ))
  }

  key <- public_key_bytes(sig$key)
  raw <- signature_bytes(sig$sig)
  if (is.null(key) || is.null(raw)) {
    return("the signature file is malformed")
  }
  if (!length(keys)) {
    return("the bundled registry declares no signing keys, so nothing can be trusted to sign this one")
  }
  if (!sig$key %in% keys) {
    return(sprintf(
      "signed by %s, which the bundled registry does not list as a signing key",
      short_key(sig$key)
    ))
  }
  if (!isTRUE(ed25519_verify(raw, sig$payload, key))) {
    return("the signature does not match these bytes")
  }

  if (!identical(sig$digest, registry_digest(registry))) {
    return(sprintf(
      "the signature covers %s but this registry is %s",
      short_digest(sig$digest), short_digest(registry_digest(registry))
    ))
  }

  created <- parse_utc(sig$created)
  if (is.null(created)) return("the signature carries no readable publication time")
  if (is.null(registry$created) ||
      !identical(format_utc(registry$created), sig$created)) {
    return("the signature and the registry disagree about when it was published")
  }

  if (!is.null(sig$expires)) {
    expires <- parse_utc(sig$expires)
    if (is.null(expires)) return("the signature carries no readable expiry")
    if (now > expires) {
      return(sprintf("the signature expired on %s", sig$expires))
    }
  }

  # A signature an attacker cannot forge can still be replayed, so a
  # declaration older than one this machine already holds is refused even
  # though it is authentic.
  if (!is.null(floor) && created < floor) {
    return(sprintf(
      "published %s, which is older than the declaration already installed (%s)",
      sig$created, format_utc(floor)
    ))
  }

  NULL
}

short_key <- function(key) {
  parts <- strsplit(key, ":", fixed = TRUE)[[1]]
  if (length(parts) != 2L) return(key)
  paste0(parts[1], ":", substr(parts[2], 1L, 12L))
}
