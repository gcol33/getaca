#' Behave during checks, examples and tests
#'
#' CRAN policy requires that a package using Internet resources "fail
#' gracefully with an informative message if the resource is not available or
#' has changed (and not give a check warning nor error)". These three helpers
#' answer three different questions, so a package can satisfy that in every
#' context without writing its own availability logic.
#'
#' \describe{
#'   \item{[getaca_available()]}{Is this resource usable right now, without
#'     touching the network? Returns a logical.}
#'   \item{[getaca_optional()]}{Give me the path if you have it. Returns
#'     `NULL` with a message otherwise, and never errors. For examples and
#'     vignettes.}
#'   \item{[getaca_skip_if_unavailable()]}{Skip this test, naming the missing
#'     dependency and how to prefetch it. For testthat.}
#' }
#'
#' @name getaca-checks
NULL

#' @rdname getaca-checks
#' @inheritParams getaca
#' @return `getaca_available()` returns `TRUE` when the resource is cached and
#'   passes its cheap integrity check.
#' @export
#'
#' @examples
#' getaca_available("nothing-here", package = "getaca")
getaca_available <- function(name, package = NULL, registry = NULL,
                             version = NULL, processed = TRUE) {
  entry <- tryCatch(
    getaca_info(name, package = package, registry = registry,
                version = version, processed = processed),
    error = function(e) NULL
  )
  if (is.null(entry)) return(FALSE)
  isTRUE(cheap_check_ok(entry))
}

#' @rdname getaca-checks
#' @return `getaca_optional()` returns a path, or `NULL` when the resource is
#'   unavailable.
#' @export
getaca_optional <- function(name, package = NULL, registry = NULL,
                            version = NULL, processed = TRUE, quiet = FALSE) {
  tryCatch(
    getaca(name, package = package, registry = registry, version = version,
           processed = processed, quiet = quiet),
    getaca_error = function(e) {
      message(sprintf(
        "getaca: '%s' is not available here, so this output is abbreviated.\n%s",
        name, conditionMessage(e)
      ))
      NULL
    }
  )
}

#' @rdname getaca-checks
#' @return `getaca_skip_if_unavailable()` returns `NULL` invisibly, or signals
#'   a testthat skip.
#' @export
getaca_skip_if_unavailable <- function(name, package = NULL, registry = NULL,
                                       version = NULL, processed = TRUE) {
  need_suggested("testthat", "getaca_skip_if_unavailable()")
  if (getaca_available(name, package = package, registry = registry,
                       version = version, processed = processed)) {
    return(invisible(NULL))
  }
  where <- package %||% (if (!is.null(registry)) registry$package else "<registry>")
  testthat::skip(sprintf(
    "external resource '%s' (declared by %s) is not cached; prefetch with getaca_prefetch(\"%s\", package = \"%s\")",
    name, where, name, where
  ))
}
