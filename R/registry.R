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
#' @param resources A list of [resource()] records.
#' @param remote Optional URL of an author-controlled registry file. Consulted
#'   only under the `"current"` policy. It may repair or add mirrors and may
#'   introduce new versions. It may never change the bytes a published version
#'   refers to.
#' @param policy Default resolution policy for this package. One of
#'   `"bundled"`, `"current"`, `"pinned"`, `"offline"`. See [getaca_policy()].
#' @param revision Monotonically increasing integer identifying this registry
#'   state, recorded in provenance.
#'
#' @return An object of class `getaca_registry`.
#' @export
#'
#' @examples
#' registry(
#'   package = "mypackage",
#'   resources = list(
#'     resource("reference-data", "2.1",
#'              urls = "https://example.org/ref-2.1.zip",
#'              sha256 = strrep("b", 64))
#'   )
#' )
registry <- function(package, resources, remote = NULL,
                     policy = c("bundled", "current", "pinned", "offline"),
                     revision = 1L) {
  policy <- match.arg(policy)
  stopifnot(is_string(package))
  if (!is.list(resources)) resources <- list(resources)
  names(resources) <- vapply(resources, function(r) r$name, character(1))

  reg <- structure(
    list(
      schema_version = REGISTRY_SCHEMA,
      package = package,
      revision = as.integer(revision),
      remote = remote,
      policy = policy,
      resources = resources
    ),
    class = "getaca_registry"
  )
  problems <- validate_registry(reg)
  if (length(problems)) err_invalid_registry(problems, package = package)
  reg
}

REGISTRY_SCHEMA <- 1L

validate_registry <- function(x) {
  p <- character()
  if (!identical(x$schema_version, REGISTRY_SCHEMA)) {
    p <- c(p, sprintf("unsupported schema version %s (this getaca understands %s)",
                      x$schema_version, REGISTRY_SCHEMA))
  }
  if (!length(x$resources)) {
    p <- c(p, "registry declares no resources")
  }
  ok <- vapply(x$resources, inherits, logical(1), "getaca_resource")
  if (!all(ok)) p <- c(p, "every element of `resources` must come from resource()")
  if (all(ok) && length(x$resources)) {
    keys <- vapply(x$resources, function(r) paste0(r$name, "@", r$version), character(1))
    dup <- unique(keys[duplicated(keys)])
    if (length(dup)) p <- c(p, sprintf("duplicate resource declaration: %s", dup))
  }
  if (!is.null(x$remote) && !grepl("^https://", x$remote)) {
    p <- c(p, "`remote` must be an https URL")
  }
  p
}

#' @export
print.getaca_registry <- function(x, ...) {
  cat("<getaca registry> ", x$package,
      "  (revision ", x$revision, ", policy \"", x$policy, "\")\n", sep = "")
  if (!is.null(x$remote)) cat("  remote: ", x$remote, "\n", sep = "")
  for (r in x$resources) cat("  - ", format(r), "\n", sep = "")
  invisible(x)
}

#' Read and write registry files
#'
#' The stored form is an R object serialised with [saveRDS()]. YAML and JSON
#' are supported as optional authoring formats only; they never define the
#' internal model and never become a hard dependency.
#'
#' @param registry A [registry()] object.
#' @param path File path. For [registry_write()], the conventional location
#'   inside a package source tree is `inst/getaca/registry.rds`.
#'
#' @return `registry_write()` returns `path` invisibly.
#'   `registry_read()` returns a `getaca_registry`.
#' @export
registry_write <- function(registry, path) {
  stopifnot(inherits(registry, "getaca_registry"))
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

#' Convert an authoring format into a registry
#'
#' Accepts the list shape a YAML or JSON registry parses into. Requires the
#' `yaml` or `jsonlite` package only when reading those formats; neither is a
#' hard dependency.
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
      licence = spec$licence %||% spec$license %||% NA_character_,
      description = spec$description %||% NA_character_
    )
  })
  registry(package = package, resources = resources, ...)
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
