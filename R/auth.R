#' Declaring a credential without holding one
#'
#' Some versioned scientific files are served only to a registered account.
#' A declaration can say which credential a host requires without ever carrying
#' one: [bearer()] and [basic()] name environment variables, and [auth_host()]
#' binds a scheme to the host it applies to.
#'
#' A credential belongs to a host rather than to a file. One record may list a
#' mirror behind a token beside a public one, and several records routinely
#' share a credential, so the declaration sits on the [registry()] and is
#' matched by host. Parts are matched by the same rule, since a part's URLs are
#' URLs.
#'
#' @section What getaca will not do:
#' The credential is read from the environment at the moment of the request and
#' is never stored, never written to the cache, never recorded in provenance and
#' never printed. It is sent as an `Authorization` header and to nothing but the
#' declared host: libcurl withholds that header from a redirect to a different
#' host, which is what a query-string token could not offer and is why one is
#' not accepted here.
#'
#' Hosts are matched exactly and there is no wildcard, so a declaration can
#' never widen the set of hosts that receive a credential.
#'
#' @name getaca-auth
NULL

#' @rdname getaca-auth
#'
#' @param variable Name of the environment variable holding the token. The
#'   variable name is the declaration; its value never enters the registry.
#'
#' @return [bearer()] and [basic()] return a `getaca_auth_scheme`;
#'   [auth_host()] returns a `getaca_auth_host`.
#' @export
#'
#' @examples
#' bearer("EXAMPLE_TOKEN")
bearer <- function(variable) {
  auth_scheme("bearer", c(token = variable))
}

#' @rdname getaca-auth
#'
#' @param user Name of the environment variable holding the user name.
#' @param password Name of the environment variable holding the password.
#' @export
#'
#' @examples
#' basic("EXAMPLE_USER", "EXAMPLE_PASSWORD")
basic <- function(user, password) {
  auth_scheme("basic", c(user = user, password = password))
}

auth_scheme <- function(scheme, variables) {
  sch <- structure(
    list(scheme = scheme, variables = variables),
    class = "getaca_auth_scheme"
  )
  problems <- validate_auth_scheme(sch)
  if (length(problems)) err_invalid_registry(problems)
  sch
}

validate_auth_scheme <- function(x) {
  vars <- x$variables
  if (!is.character(vars) || anyNA(vars) ||
      !all(grepl("^[A-Za-z_][A-Za-z0-9_]*$", vars))) {
    return(sprintf(
      "auth scheme '%s': each argument names an environment variable, not a credential",
      x$scheme
    ))
  }
  character()
}

#' @rdname getaca-auth
#'
#' @param host Host the credential applies to, as it appears in the URL, for
#'   example `"data.example.org"`. Matched exactly, without wildcards.
#' @param scheme A [bearer()] or [basic()] declaration.
#' @param register Optional URL where a user obtains a credential. Reported
#'   when one is missing or refused, and part of the manifest so that a signed
#'   registry covers it.
#' @export
#'
#' @examples
#' auth_host("data.example.org", bearer("EXAMPLE_TOKEN"),
#'           register = "https://data.example.org/register")
auth_host <- function(host, scheme, register = NULL) {
  ah <- structure(
    list(host = tolower(as.character(host)[1]), scheme = scheme,
         register = register),
    class = "getaca_auth_host"
  )
  problems <- validate_auth_host(ah)
  if (length(problems)) err_invalid_registry(problems)
  ah
}

validate_auth_host <- function(x) {
  p <- character()
  if (!is_string(x$host) || !grepl("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", x$host)) {
    p <- c(p, sprintf("auth host '%s': must be a bare host name, with no scheme, port or path",
                      x$host))
  }
  if (!inherits(x$scheme, "getaca_auth_scheme")) {
    p <- c(p, sprintf("auth host '%s': `scheme` must come from bearer() or basic()", x$host))
  }
  if (!is.null(x$register) && (!is_string(x$register) || !grepl("^https://", x$register))) {
    p <- c(p, sprintf("auth host '%s': `register` must be an https URL", x$host))
  }
  p
}

validate_auth <- function(auth) {
  if (is.null(auth) || !length(auth)) return(character())
  if (!is.list(auth)) return("`auth` must be a list of auth_host() declarations")
  ok <- vapply(auth, inherits, logical(1), "getaca_auth_host")
  if (!all(ok)) return("every element of `auth` must come from auth_host()")
  hosts <- vapply(auth, function(a) a$host, character(1))
  dup <- unique(hosts[duplicated(hosts)])
  if (length(dup)) {
    return(sprintf("`auth` declares host '%s' more than once", dup))
  }
  character()
}

#' @export
format.getaca_auth_host <- function(x, ...) {
  sprintf("%s  %s  %s", x$host, x$scheme$scheme,
          paste(x$scheme$variables, collapse = ", "))
}

#' @export
print.getaca_auth_host <- function(x, ...) {
  cat("<getaca auth host> ", format(x), "\n", sep = "")
  invisible(x)
}

#' @export
print.getaca_auth_scheme <- function(x, ...) {
  cat("<getaca auth scheme> ", x$scheme, ": ",
      paste(x$variables, collapse = ", "), "\n", sep = "")
  invisible(x)
}

# The host a URL addresses. Userinfo is dropped by taking what follows the last
# `@`, so `https://data.example.org@attacker.example/` is matched as the host it
# actually reaches rather than the one it is dressed as.
url_host <- function(url) {
  rest <- sub("^[A-Za-z][A-Za-z0-9+.-]*://", "", url)
  authority <- sub("[/?#].*$", "", rest)
  authority <- sub("^.*@", "", authority)
  tolower(sub(":[0-9]*$", "", authority))
}

auth_for_url <- function(url, auth) {
  if (is.null(auth) || !length(auth)) return(NULL)
  host <- url_host(url)
  for (a in auth) if (identical(a$host, host)) return(a)
  NULL
}

# What a URL requires, and whether this machine can supply it. Reads no value,
# so everything that composes a message stays clear of the credential itself.
credential_demand <- function(url, auth) {
  a <- auth_for_url(url, auth)
  if (is.null(a)) return(NULL)
  vars <- a$scheme$variables
  list(
    host = a$host,
    scheme = a$scheme$scheme,
    variables = unname(vars),
    missing = unname(vars[!nzchar(Sys.getenv(unname(vars)))]),
    register = a$register
  )
}

# The credential itself, read at the moment of the request. Returned as what the
# handle should set rather than as a value to be passed around: Basic goes
# through libcurl's own user/password option, which encodes it and, like the
# Authorization header, is withheld from a redirect to another host.
credential_secret <- function(url, auth) {
  a <- auth_for_url(url, auth)
  if (is.null(a)) return(NULL)
  vars <- a$scheme$variables
  # Sys.getenv() names its result after the variables it read, so the scheme's
  # own labels have to be put back before anything indexes by them.
  values <- stats::setNames(Sys.getenv(unname(vars)), names(vars))
  if (!all(nzchar(values))) return(NULL)
  switch(a$scheme$scheme,
    bearer = list(scheme = "bearer",
                  header = paste("Bearer", values[["token"]])),
    basic  = list(scheme = "basic",
                  userpwd = paste0(values[["user"]], ":", values[["password"]])),
    NULL
  )
}

# The seam between "which host needs a credential" and "how a request carries
# one". Applied to the transport rather than threaded through the mirror loop,
# so a stand-in transport in a test is unaffected by a declaration it is not
# exercising.
with_credentials <- function(transport, auth) {
  function(url, dest, progress = NULL) {
    transport(url, dest, progress = progress,
              auth = credential_secret(url, auth))
  }
}

#' Which credentials a package expects
#'
#' Reports the environment variables a package's declaration reads, and whether
#' each is set in this session. Answers "do I have what I need" before a fetch
#' rather than during one, without touching the network.
#'
#' Values are never read or shown. `set` says only that the variable holds
#' something.
#'
#' @param package Declaring package. Ignored when `registry` is supplied.
#' @param registry A [registry()] object, for standalone use.
#'
#' @return A data frame with one row per declared variable: `package`, `host`,
#'   `scheme`, `variable`, `set` and `register`. Empty when nothing is declared.
#' @seealso [getaca-auth]
#' @export
#'
#' @examples
#' reg <- registry("demo",
#'   auth = list(auth_host("data.example.org", bearer("EXAMPLE_TOKEN"))),
#'   resources = list(
#'     resource("example", "1.0",
#'              urls = "https://data.example.org/example-1.0.csv",
#'              sha256 = strrep("c", 64))
#'   ))
#' getaca_credentials(registry = reg)
getaca_credentials <- function(package = NULL, registry = NULL) {
  reg <- registry %||% registry_for(package)
  if (is.null(reg) || !length(reg$auth)) return(empty_credentials())
  rows <- lapply(reg$auth, function(a) {
    vars <- a$scheme$variables
    data.frame(
      package = reg$package,
      host = a$host,
      scheme = a$scheme$scheme,
      variable = unname(vars),
      set = nzchar(Sys.getenv(unname(vars))),
      register = a$register %||% NA_character_,
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

empty_credentials <- function() {
  data.frame(package = character(), host = character(), scheme = character(),
             variable = character(), set = logical(), register = character(),
             stringsAsFactors = FALSE)
}
