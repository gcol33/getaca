#' Declare a package's external resources
#'
#' A registry is one package's declaration of what it needs. It carries no
#' download logic: getaca is the single engine, and every package supplies
#' only its own list of resource records.
#'
#' Ship the result at `inst/getaca/registry.rds` via [registry_write()].
#' getaca discovers it with `system.file()`, so no registration call and no
#' load hook are required.
#'
#' @param package Name of the declaring package. Becomes part of every
#'   resource identity and scopes the cache, so two packages declaring the
#'   same resource name never collide.
#' @param resources A list of [resource()] records, or a single record.
#' @param remote Optional URL of an author-controlled registry file. Consulted
#'   only under the `"current"` policy. It may repair or add mirrors and may
#'   introduce new versions. It may never change the bytes a published version
#'   refers to.
#' @param policy Default resolution policy for this package. One of
#'   `"bundled"`, `"current"`, `"pinned"`, `"offline"`. See [getaca_policy()].
#' @param current Named character vector giving the channel head: the version a
#'   bare request for each resource name resolves to, as
#'   `c(backbone = "2026-09")`. Required for any name declaring more than one
#'   version, and optional for the rest, since a name with one version has only
#'   one answer.
#' @param keys Public keys, from [registry_keygen()], that may sign this
#'   package's remote registry. Declaring any of them makes a signature
#'   mandatory under the `"current"` policy: an unsigned or unverifiable remote
#'   registry is then refused rather than used. The keys trusted are the ones in
#'   the registry the *package ships*, which reaches a user by a different route
#'   than the remote does, and that is what a signature rests on. See
#'   [getaca-signing].
#' @param auth Optional list of [auth_host()] declarations, naming the
#'   environment variables a host requires before it will serve a resource.
#'   Read from the registry the *package ships*, never from a remote one, for
#'   the reason `keys` is: a declaration arriving over the network must not be
#'   able to say where a credential is sent. See [getaca-auth].
#'
#' @section Identity:
#' A registry state is identified by [registry_digest()], derived from the
#' declaration itself, and recorded in the provenance of every resource it
#' resolves. There is no revision number to keep in step: a digest cannot be
#' typed wrong, and two states that differ cannot claim to be the same one.
#' [registry_write()] stamps `created`, which is what orders two states in
#' time, and a bundled registry additionally has the version of the package
#' that ships it.
#'
#' @section Channel heads:
#' A registry declares records; a channel points at one of them. When a
#' resource name carries several versions, which of them `getaca("name")`
#' returns is a decision, so the registry states it in `current` rather than
#' leaving it to declaration order. A registry that declares two versions of a
#' name without naming a head is refused, which is what stops a version
#' appended in the wrong place from silently moving every user backwards.
#'
#' @return An object of class `getaca_registry`.
#' @export
#'
#' @examples
#' registry(
#'   package = "yourpkg",
#'   resources = list(
#'     resource("reference-data", "2.1",
#'              urls = "https://example.org/ref-2.1.zip",
#'              sha256 = strrep("b", 64))
#'   )
#' )
#'
#' # Two versions on offer, one of them the channel head:
#' registry(
#'   package = "yourpkg",
#'   current = c("reference-data" = "2.1"),
#'   resources = list(
#'     resource("reference-data", "2.0",
#'              urls = "https://example.org/ref-2.0.zip",
#'              sha256 = strrep("a", 64)),
#'     resource("reference-data", "2.1",
#'              urls = "https://example.org/ref-2.1.zip",
#'              sha256 = strrep("b", 64))
#'   )
#' )
registry <- function(package, resources, remote = NULL,
                     policy = c("bundled", "current", "pinned", "offline"),
                     current = NULL, keys = NULL, auth = NULL) {
  policy <- match.arg(policy)
  stopifnot(is_string(package))
  # A record is itself a list, so a lone one is recognised by its class. Asking
  # whether it is a list would see the record's own fields as the declarations.
  if (inherits(resources, "getaca_resource")) resources <- list(resources)
  if (!is.list(resources)) resources <- list(resources)

  reg <- structure(
    list(
      schema_version = REGISTRY_SCHEMA,
      package = package,
      # Stamped by registry_write(), because publishing a state is what dates
      # it. A declaration built in a session and never written has no date.
      created = NULL,
      remote = remote,
      policy = policy,
      current = as_channel_heads(current),
      keys = if (length(keys)) unique(as.character(keys)) else NULL,
      auth = if (length(auth)) auth else NULL,
      resources = resources
    ),
    class = "getaca_registry"
  )
  problems <- validate_registry(reg)
  if (length(problems)) err_invalid_registry(problems, package = package)
  # Named once every element is known to be a record, so an element that is not
  # one is reported as an invalid registry rather than failing on the name.
  names(reg$resources) <- vapply(reg$resources, function(r) r$name, character(1))
  reg
}

# 4 since a registry may declare `auth`. An older getaca refuses a registry at
# this schema, which is the right answer: it would fetch an authenticated host
# with no credential and report the refusal as an outage. `doi` arrived with it
# and would not have justified a bump on its own.
REGISTRY_SCHEMA <- 4L

validate_registry <- function(x) {
  p <- character()
  # An older stored form is read, because every field added since has a defined
  # absence and the reader supplies it. A newer one is refused, because this
  # getaca cannot know what a field it has never heard of was meant to
  # constrain. Accepting a range is what keeps a later addition from rejecting
  # every registry already installed.
  sv <- x$schema_version
  if (!is.numeric(sv) || length(sv) != 1L || is.na(sv)) {
    p <- c(p, "registry carries no usable schema version")
  } else if (sv > REGISTRY_SCHEMA) {
    p <- c(p, sprintf(
      "registry schema version %s comes from a newer getaca (this one reads up to %s); upgrade getaca",
      sv, REGISTRY_SCHEMA
    ))
  }
  if (!length(x$resources)) {
    p <- c(p, "registry declares no resources")
  }
  ok <- vapply(x$resources, inherits, logical(1), "getaca_resource")
  if (!all(ok)) p <- c(p, "every element of `resources` must come from resource()")
  if (all(ok) && length(x$resources)) {
    keys <- vapply(x$resources, version_key, character(1))
    dup <- unique(keys[duplicated(keys)])
    if (length(dup)) p <- c(p, sprintf("duplicate resource declaration: %s", dup))
    p <- c(p, validate_channel_heads(x))
  }
  if (!is.null(x$remote) && !grepl("^https://", x$remote)) {
    p <- c(p, "`remote` must be an https URL")
  }
  p <- c(p, validate_keys(x$keys))
  p <- c(p, validate_auth(x$auth))
  p
}

# A key that cannot be parsed is refused on the author's machine rather than
# on every user's, where it would present as an unverifiable remote registry.
validate_keys <- function(keys) {
  if (is.null(keys) || !length(keys)) return(character())
  if (!is.character(keys)) {
    return("`keys` must be public keys as returned by registry_keygen()")
  }
  bad <- keys[!vapply(keys, is_public_key, logical(1))]
  if (!length(bad)) return(character())
  sprintf("'%s' is not a public key of the form \"ed25519:<64 hex characters>\"", bad)
}

as_channel_heads <- function(current) {
  if (is.null(current) || !length(current)) return(NULL)
  if (is.list(current)) current <- unlist(current, use.names = TRUE)
  stats::setNames(as.character(current), names(current))
}

validate_channel_heads <- function(x) {
  p <- character()
  cur <- x$current
  declared <- split(
    vapply(x$resources, function(r) r$version, character(1)),
    vapply(x$resources, function(r) r$name, character(1))
  )

  if (!is.null(cur)) {
    if (is.null(names(cur)) || !all(nzchar(names(cur))) || anyNA(cur)) {
      return("`current` must name one version per resource, as current = c(name = \"version\")")
    }
    dup <- unique(names(cur)[duplicated(names(cur))])
    if (length(dup)) {
      p <- c(p, sprintf("`current` names resource '%s' more than once", dup))
    }
    unknown <- setdiff(names(cur), names(declared))
    if (length(unknown)) {
      p <- c(p, sprintf("`current` names '%s', which the registry does not declare", unknown))
    }
    for (nm in intersect(names(cur), names(declared))) {
      if (!cur[[nm]] %in% declared[[nm]]) {
        p <- c(p, sprintf(
          "`current` names version '%s' of '%s', which is not declared (has: %s)",
          cur[[nm]], nm, paste(declared[[nm]], collapse = ", ")
        ))
      }
    }
  }

  # Declaration order is not a version order, so a name offering a choice has
  # to say which one a bare request resolves to.
  headless <- setdiff(names(declared)[lengths(declared) > 1L], names(cur))
  for (nm in headless) {
    p <- c(p, sprintf(
      "resource '%s' declares %d versions (%s) but the registry names no current one; add current = c(\"%s\" = \"%s\")",
      nm, length(declared[[nm]]), paste(declared[[nm]], collapse = ", "),
      nm, declared[[nm]][length(declared[[nm]])]
    ))
  }
  p
}

#' @export
print.getaca_registry <- function(x, ...) {
  cat("<getaca registry> ", x$package,
      "  (policy \"", x$policy, "\")\n", sep = "")
  cat("  digest: ", short_digest(registry_digest(x)), "\n", sep = "")
  if (!is.null(x$created)) {
    cat("  created: ", format(x$created, "%Y-%m-%d %H:%M:%S"), "\n", sep = "")
  }
  if (!is.null(x$remote)) cat("  remote: ", x$remote, "\n", sep = "")
  for (k in x$keys) cat("  signed by: ", short_key(k), "\n", sep = "")
  for (a in x$auth) cat("  credential: ", format(a), "\n", sep = "")
  for (r in x$resources) {
    head <- identical(channel_head(x, r$name), r$version)
    cat("  - ", format(r), if (head) "  (current)", "\n", sep = "")
  }
  invisible(x)
}

#' Read and write registry files
#'
#' The stored form is an R object serialised with [saveRDS()]. YAML and JSON
#' are supported as optional authoring formats only; they never define the
#' internal model and never become a hard dependency.
#'
#' Writing stamps `created`, since publishing a state is what dates it.
#' `created` is what orders two states in time, which a content digest cannot
#' do; [registry_digest()] says whether two states are the same, and `created`
#' says which came first. It is deliberately outside the digest, so writing an
#' unchanged registry out again leaves its identity alone.
#'
#' @param registry A [registry()] object.
#' @param path File path. For [registry_write()], the conventional location
#'   inside a package source tree is `inst/getaca/registry.rds`.
#' @param created Publication time recorded in the file. Pass a fixed value to
#'   keep a build byte-reproducible.
#'
#' @return `registry_write()` returns `path` invisibly.
#'   `registry_read()` returns a `getaca_registry`.
#' @export
registry_write <- function(registry, path, created = Sys.time()) {
  stopifnot(inherits(registry, "getaca_registry"))
  registry$created <- created
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  saveRDS(registry, path, version = 3)
  invisible(path)
}

#' @rdname registry_write
#' @export
registry_read <- function(path) {
  reg <- readRDS(path)
  problems <- validate_registry(reg)
  if (length(problems)) err_invalid_registry(problems, package = reg$package)
  reg
}

registry_cache <- new.env(parent = emptyenv())

#' Find the registry a package ships
#'
#' @param package Package name.
#' @return A `getaca_registry`, or `NULL` when the package ships none.
#' @export
registry_for <- function(package) {
  if (!is.null(registry_cache[[package]])) return(registry_cache[[package]])
  path <- system.file("getaca", "registry.rds", package = package)
  if (!nzchar(path)) return(NULL)
  reg <- registry_read(path)
  if (!identical(reg$package, package)) {
    err_invalid_registry(
      sprintf("registry shipped by '%s' declares package '%s'", package, reg$package),
      package = package
    )
  }
  registry_cache[[package]] <- reg
  reg
}

#' Forget cached registry state
#'
#' Registries are read once per session: the one a package ships is cached
#' after the first `system.file()` lookup, and a remote registry is cached
#' after the first fetch. Call this after installing a new version of a
#' declaring package, or to make the `"current"` policy consult the remote
#' again within the same session.
#'
#' Cached *resources* are untouched. This forgets declarations, not data.
#'
#' @return `NULL`, invisibly.
#' @export
#'
#' @examples
#' getaca_refresh()
getaca_refresh <- function() {
  rm(list = ls(registry_cache, all.names = TRUE), envir = registry_cache)
  rm(list = ls(remote_cache, all.names = TRUE), envir = remote_cache)
  invisible(NULL)
}

#' Convert an authoring format into a registry
#'
#' Accepts the list shape a YAML or JSON registry parses into. Requires the
#' `yaml` or `jsonlite` package only when reading those formats; neither is a
#' hard dependency.
#'
#' Multi-part records are expressible, since a [part()] is data. A [combiner()]
#' is not, so a record combined by anything other than the default has to be
#' declared with [resource()] in R, where the function it names exists.
#'
#' @param x A list, or a path to a `.yml`, `.yaml` or `.json` file.
#' @param package Declaring package name.
#' @param ... Passed to [registry()].
#'
#' @return A `getaca_registry`.
#' @export
as_registry <- function(x, package, ...) {
  if (is_string(x) && file.exists(x)) x <- read_authoring_format(x)
  resources <- lapply(names(x), function(nm) {
    spec <- x[[nm]]
    resource(
      name = nm,
      version = as.character(spec$version),
      urls = unlist(spec$urls %||% spec$url, use.names = FALSE),
      sha256 = spec$sha256,
      size = spec$size %||% NA_real_,
      # Authoring formats accept either spelling; the model has one field.
      license = spec$license %||% spec$licence %||% NA_character_,
      description = spec$description %||% NA_character_,
      doi = spec$doi,
      parts = authoring_parts(spec$parts),
      combiner = authoring_combiner(spec$combiner, nm),
      file = spec$file
    )
  })
  registry(package = package, resources = resources, ...)
}

authoring_parts <- function(parts) {
  if (!length(parts)) return(NULL)
  lapply(parts, function(p) {
    part(urls = unlist(p$urls %||% p$url, use.names = FALSE),
         sha256 = p$sha256,
         size = p$size %||% NA_real_)
  })
}

# A combiner carries a function, and an authoring format carries data, so the
# only one nameable here is the default. Saying so is better than accepting the
# name and combining by something else.
authoring_combiner <- function(id, name) {
  if (is.null(id) || identical(as.character(id), CONCAT_ID)) return(NULL)
  err_invalid_registry(sprintf(
    "resource '%s': combiner '%s' carries a function, so it cannot come from an authoring format; declare this record with resource() in R",
    name, id
  ))
}

read_authoring_format <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("yml", "yaml")) {
    need_suggested("yaml", "reading YAML registries")
    yaml::read_yaml(path)
  } else if (ext == "json") {
    need_suggested("jsonlite", "reading JSON registries")
    jsonlite::fromJSON(path, simplifyVector = FALSE)
  } else {
    stop("Unsupported registry format: ", ext, call. = FALSE)
  }
}

need_suggested <- function(pkg, what) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop(sprintf("The '%s' package is required for %s.\nInstall it with install.packages(\"%s\").",
                 pkg, what, pkg), call. = FALSE)
  }
}

`%||%` <- function(x, y) if (is.null(x)) y else x
