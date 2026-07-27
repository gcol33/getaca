#' Resolve a name to an immutable resource record
#'
#' Separates the two things that must not be conflated: an immutable resource
#' record, and the mutable channel that maps a logical name onto one. This
#' function walks the channel; everything downstream deals only in records.
#'
#' @param name Resource name.
#' @param package Declaring package. Ignored when `registry` is supplied.
#' @param registry A [registry()] object, for standalone use.
#' @param policy Resolution policy, defaulting to [getaca_policy()].
#' @param version Optional explicit version, bypassing channel resolution.
#'
#' @return A list with `id`, `record`, `policy`, `source`, `digest` and
#'   `created`. `policy` is the one actually in force, after the argument, the
#'   session setting, the registry default and the check clamp have been
#'   resolved. `digest` identifies the registry state that answered, and
#'   `created` says when that state was published, or `NA` for a declaration
#'   that was built in the session rather than read from a file.
#' @export
resolve_resource <- function(name, package = NULL, registry = NULL,
                             policy = NULL, version = NULL) {
  reg <- registry %||% registry_for(package)
  if (is.null(reg)) {
    err_invalid_registry(
      sprintf("package '%s' ships no getaca registry at inst/getaca/registry.rds", package),
      package = package
    )
  }
  policy <- policy %||% effective_policy(reg$policy)

  channel <- switch(policy,
    bundled = reg,
    offline = reg,
    current = remote_channel(reg),
    pinned  = pinned_channel(reg)
  )

  rec <- select_record(channel, name, version)
  if (is.null(rec)) {
    err_invalid_registry(
      sprintf("package '%s' declares no resource named '%s' (has: %s)",
              reg$package, name,
              paste(unique(vapply(channel$resources, function(r) r$name, character(1))),
                    collapse = ", ")),
      package = reg$package
    )
  }

  list(
    id = resource_id(reg$package, rec$name, rec$version),
    record = rec,
    policy = policy,
    source = if (policy %in% c("bundled", "offline")) "bundled" else policy,
    # Identity comes from the channel that answered, not from the bundled
    # registry, so provenance names the state that actually chose the record.
    digest = registry_digest(channel),
    created = channel$created %||% .POSIXct(NA_real_)
  )
}

select_record <- function(channel, name, version = NULL) {
  hits <- Filter(function(r) identical(r$name, name), channel$resources)
  if (!length(hits)) return(NULL)
  version <- version %||% channel_head(channel, name)
  # No head to consult means one declared version, since a registry offering a
  # choice without naming one is refused.
  if (is.null(version)) return(hits[[1]])
  hits <- Filter(function(r) identical(r$version, version), hits)
  if (length(hits)) hits[[1]] else NULL
}

# The version a bare name resolves to, when the registry states one.
channel_head <- function(channel, name) {
  cur <- channel$current
  if (is.null(cur) || !name %in% names(cur)) return(NULL)
  unname(cur[[name]])
}

remote_cache <- new.env(parent = emptyenv())

# The registry transport, separated from the decision of whether to trust what
# it returns. Which registry state wins is the part worth testing, and it is
# testable without a network because the transport is injectable.
fetch_registry <- function(url, dest) {
  tryCatch({
    curl::curl_download(url, dest, quiet = TRUE, handle = new_handle_for(url))
    TRUE
  }, error = function(e) FALSE)
}

remote_channel <- function(reg, fetch = fetch_registry) {
  if (is.null(reg$remote)) return(reg)
  key <- paste0(reg$package, "|", reg$remote)
  if (!is.null(remote_cache[[key]])) return(remote_cache[[key]])

  tmp <- tempfile(fileext = ".rds")
  on.exit(unlink(tmp), add = TRUE)
  ok <- isTRUE(fetch(reg$remote, tmp))

  if (!ok) {
    message(sprintf(
      "getaca: could not reach the remote registry for '%s'; using the bundled registry.",
      reg$package
    ))
    return(reg)
  }

  fetched <- tryCatch(registry_read(tmp), error = function(e) NULL)
  if (is.null(fetched)) {
    message(sprintf(
      "getaca: the remote registry for '%s' is unreadable; using the bundled registry.",
      reg$package
    ))
    return(reg)
  }
  if (!identical(fetched$package, reg$package)) {
    err_invalid_registry(
      sprintf("remote registry at %s declares package '%s'", reg$remote, fetched$package),
      package = reg$package
    )
  }
  # Who is speaking, before what they said. A forged registry that also
  # redefines a published version should be reported as forged.
  assert_signed(reg, fetched, fetch)
  assert_immutable(reg, fetched)
  remote_cache[[key]] <- fetched
  fetched
}

# The trusted keys are the bundled registry's, never the fetched one's: a
# declaration that nominated the keys allowed to vouch for it would vouch for
# itself. A package declaring none is unsigned, and nothing here applies.
#
# Reaching the registry but not its signature is not treated as the network
# being down. The two sit on one host, so a signature that alone fails to
# arrive is the shape a downgrade takes, and accepting the registry without it
# would make the check optional for whoever serves it.
assert_signed <- function(bundled, fetched, fetch = fetch_registry) {
  if (!length(bundled$keys)) return(invisible(TRUE))
  url <- signature_path(bundled$remote)

  tmp <- tempfile(fileext = ".sig")
  on.exit(unlink(tmp), add = TRUE)
  sig <- NULL
  if (isTRUE(fetch(url, tmp))) {
    sig <- tryCatch(signature_read(tmp), error = function(e) NULL)
  }
  if (is.null(sig)) {
    err_signature(bundled$package, "no signature could be fetched and read", url = url)
  }

  problem <- signature_problem(sig, fetched, bundled$keys,
                               floor = bundled$created)
  if (!is.null(problem)) err_signature(bundled$package, problem, url = url)
  invisible(TRUE)
}

# A remote channel may repair mirrors and add versions. It may never redefine
# what a published version means. A pin file is held to the same rule, so the
# message names whichever of the two is being checked.
#
# What counts as published is the bundled declaration plus whatever this
# machine has already fetched and verified. Without the second, a version the
# bundled registry never carried could be redefined freely, since there would
# be nothing on this side to contradict. `known` is injected so the adjudication
# stays testable without a cache.
assert_immutable <- function(bundled, fetched, source = "remote registry",
                             known = cached_checksums(bundled$package)) {
  old <- stats::setNames(vapply(bundled$resources, function(r) r$sha256, character(1)),
                         vapply(bundled$resources, version_key, character(1)))
  old <- c(old, known[setdiff(names(known), names(old))])
  new <- stats::setNames(vapply(fetched$resources, function(r) r$sha256, character(1)),
                         vapply(fetched$resources, version_key, character(1)))
  shared <- intersect(names(old), names(new))
  bad <- shared[old[shared] != new[shared]]
  if (length(bad)) {
    err_invalid_registry(
      c(sprintf("the %s redefines published version %s", source, bad),
        "A version identifies exact bytes. Publish a new version instead."),
      package = bundled$package
    )
  }
  invisible(TRUE)
}

pinned_channel <- function(reg) {
  path <- pin_file()
  if (!file.exists(path)) {
    err_invalid_registry(
      c(sprintf("policy is \"pinned\" but no pin file exists at %s", path),
        "Create one with getaca_pin()."),
      package = reg$package
    )
  }
  pins <- readRDS(path)
  hit <- pins[[reg$package]]
  if (is.null(hit)) {
    err_invalid_registry(
      sprintf("the pin file records nothing for package '%s'", reg$package),
      package = reg$package
    )
  }
  assert_immutable(reg, hit, source = "pin file")
  hit
}

pin_file <- function() {
  getOption("getaca.pin_file", file.path(getwd(), "getaca.pins.rds"))
}

#' Freeze current resolution into a pin file
#'
#' Records, for each named package, the registry state currently in effect.
#' Under the `"pinned"` policy those records are what resolution uses, so an
#' analysis keeps resolving the versions it was written against.
#'
#' @param packages Character vector of package names.
#' @param path Where to write the pin file.
#'
#' @return `path`, invisibly.
#' @export
getaca_pin <- function(packages, path = pin_file()) {
  pins <- if (file.exists(path)) readRDS(path) else list()
  for (p in packages) {
    reg <- registry_for(p)
    if (is.null(reg)) {
      warning(sprintf("package '%s' ships no getaca registry; skipped", p), call. = FALSE)
      next
    }
    pins[[p]] <- if (identical(effective_policy(reg$policy), "current")) {
      remote_channel(reg)
    } else {
      reg
    }
  }
  saveRDS(pins, path, version = 3)
  invisible(path)
}
