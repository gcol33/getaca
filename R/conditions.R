#' Failure taxonomy
#'
#' Every failure raised by getaca carries a subclass naming the situation and
#' an `actor` field naming who can act on it: `"user"`, `"author"` or
#' `"upstream"`. Callers can therefore branch on the cause rather than on
#' message text.
#'
#' @section Conditions:
#' \describe{
#'   \item{`getaca_error_unavailable`}{No mirror could be reached. actor: user.}
#'   \item{`getaca_error_incomplete`}{Transfer ended short of the expected
#'     size. actor: user.}
#'   \item{`getaca_error_upstream_changed`}{A complete download hashed to
#'     something other than the declared checksum, and the declaration is
#'     otherwise sound. actor: upstream.}
#'   \item{`getaca_error_cache_corrupt`}{The cached copy no longer matches its
#'     own entry record. actor: user (refetch).}
#'   \item{`getaca_error_redeclared`}{The declaration now names different bytes
#'     for a version already held, so the two cannot both be that version.
#'     actor: author.}
#'   \item{`getaca_error_invalid_registry`}{Malformed or internally
#'     inconsistent registry. actor: author.}
#'   \item{`getaca_error_declaration`}{Several independent mirrors agreed with
#'     each other and disagreed with the declared checksum. actor: author.}
#'   \item{`getaca_error_signature`}{A registry that must be signed carried no
#'     usable signature from a trusted key. actor: author.}
#' }
#'
#' @section Reachability and authenticity:
#' A remote registry that cannot be reached is an availability problem, and
#' resolution falls back to the bundled declaration with a message. A remote
#' registry that arrives and fails its signature is an integrity problem, and
#' resolution stops. The two are deliberately not the same: falling back on a
#' failed signature would work, in that the bundled registry is trustworthy,
#' but it would silently discard the one event the signature exists to report.
#'
#' @name getaca-conditions
#' @keywords internal
NULL

actor_hint <- function(actor) {
  switch(actor,
    user     = "Fix: see the actions listed above.",
    author   = "Fix: the declaring package needs a correction. Report it to its maintainer.",
    upstream = "Fix: the publisher changed the file. The declaring package needs a new registry entry.",
    NULL
  )
}

getaca_abort <- function(subclass, message, actor, data = list(), call = NULL) {
  cond <- c(
    list(
      message = paste(c(message, "", actor_hint(actor)), collapse = "\n"),
      call = call,
      actor = actor
    ),
    data
  )
  class(cond) <- c(subclass, "getaca_error", "error", "condition")
  stop(cond)
}

err_unavailable <- function(id, urls, reasons, call = NULL) {
  getaca_abort(
    "getaca_error_unavailable",
    c(
      sprintf("Cannot reach any source for %s.", format(id)),
      sprintf("  %s", paste0(urls, ": ", reasons)),
      "",
      "Actions: connect to a network; or run getaca_prefetch() on a connected",
      "machine and copy the cache directory; or set the resource optional here",
      "with getaca_available() before calling."
    ),
    actor = "user",
    data = list(id = id, urls = urls, reasons = reasons),
    call = call
  )
}

err_incomplete <- function(id, expected, observed, call = NULL) {
  getaca_abort(
    "getaca_error_incomplete",
    c(
      sprintf("Transfer of %s ended early.", format(id)),
      sprintf("  expected %s bytes, received %s bytes", expected, observed),
      "",
      "Action: retry. Any previously cached copy was left untouched."
    ),
    actor = "user",
    data = list(id = id, expected = expected, observed = observed),
    call = call
  )
}

err_upstream_changed <- function(id, expected, observed, url, call = NULL) {
  getaca_abort(
    "getaca_error_upstream_changed",
    c(
      sprintf("The remote file no longer matches %s.", format(id)),
      sprintf("  declared SHA-256: %s", expected),
      sprintf("  observed SHA-256: %s", observed),
      sprintf("  source: %s", url),
      "",
      "The publisher appears to have replaced the contents without issuing a",
      "new version. getaca will not accept the substitution, and any copy",
      "already verified in the cache has been left untouched."
    ),
    actor = "upstream",
    data = list(id = id, expected = expected, observed = observed, url = url),
    call = call
  )
}

err_cache_corrupt <- function(id, path, expected, observed, call = NULL) {
  getaca_abort(
    "getaca_error_cache_corrupt",
    c(
      sprintf("The cached copy of %s is damaged.", format(id)),
      sprintf("  path: %s", path),
      sprintf("  declared SHA-256: %s", expected),
      sprintf("  observed SHA-256: %s", observed),
      "",
      sprintf("Action: getaca_clean(\"%s\", package = \"%s\"), then retry.",
              id$name, id$package)
    ),
    actor = "user",
    data = list(id = id, path = path, expected = expected, observed = observed),
    call = call
  )
}

err_redeclared <- function(id, cached, declared, call = NULL) {
  getaca_abort(
    "getaca_error_redeclared",
    c(
      sprintf("The declaration for %s no longer names the bytes already held.",
              format(id)),
      sprintf("  cached SHA-256:   %s", cached),
      sprintf("  declared SHA-256: %s", declared),
      "",
      "A version identifies exact bytes, so these cannot both be that version.",
      "The cached copy was verified against the earlier declaration and has",
      "been left untouched. Publish a new version instead of redefining this",
      "one.",
      "",
      "Action: if the new declaration is the correct one, drop the old copy",
      sprintf("with getaca_clean(\"%s\", package = \"%s\") and retry.",
              id$name, id$package)
    ),
    actor = "author",
    data = list(id = id, cached = cached, declared = declared),
    call = call
  )
}

err_invalid_registry <- function(problems, package = NULL, call = NULL) {
  getaca_abort(
    "getaca_error_invalid_registry",
    c(
      if (is.null(package)) {
        "Invalid getaca registry."
      } else {
        sprintf("Invalid getaca registry for package '%s'.", package)
      },
      sprintf("  - %s", problems)
    ),
    actor = "author",
    data = list(problems = problems, package = package),
    call = call
  )
}

err_signature <- function(package, problem, url = NULL, call = NULL) {
  getaca_abort(
    "getaca_error_signature",
    c(
      sprintf("The registry for '%s' could not be established as authentic.", package),
      sprintf("  %s", problem),
      if (!is.null(url)) sprintf("  source: %s", url),
      "",
      "This package declares signing keys, so a remote registry that cannot be",
      "checked against one is refused rather than used. The bundled declaration",
      "the package ships is unaffected and still resolves.",
      "",
      sprintf("Action: getaca_policy(\"bundled\") resolves through it for this session.")
    ),
    actor = "author",
    data = list(package = package, problem = problem, url = url),
    call = call
  )
}

err_declaration <- function(id, expected, observed, urls, call = NULL) {
  getaca_abort(
    "getaca_error_declaration",
    c(
      sprintf("The declared checksum for %s looks wrong.", format(id)),
      sprintf("  %d independent sources agreed on SHA-256 %s", length(urls), observed),
      sprintf("  the registry declares %s", expected),
      "",
      "When every mirror agrees with the others and disagrees with the",
      "registry, the registry is the likely error."
    ),
    actor = "author",
    data = list(id = id, expected = expected, observed = observed, urls = urls),
    call = call
  )
}
