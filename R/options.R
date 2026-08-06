#' Resolution policy and settings
#'
#' `getaca_policy()` reports or sets the resolution policy for the current
#' session. The policy decides which registry state a name resolves through,
#' and is recorded in provenance so a result can always be traced back to it.
#'
#' @section Policies:
#' \describe{
#'   \item{`"bundled"`}{Always use the registry shipped with the declaring
#'     package. The same installed package resolves the same bytes forever.
#'     This is the default.}
#'   \item{`"current"`}{Consult the author-controlled remote registry, falling
#'     back to bundled when it cannot be reached. Lets an author repair a dead
#'     mirror or publish a new version without a CRAN release.}
#'   \item{`"pinned"`}{Resolve through a frozen local snapshot, so an analysis
#'     keeps resolving what it resolved on the day it was written.}
#'   \item{`"offline"`}{Never touch the network. Cached and bundled
#'     information only.}
#' }
#'
#' During `R CMD check` resolution always collapses to `"offline"`, whatever
#' is set here.
#'
#' Setting the policy sets the `getaca.policy` option and nothing else, and
#' returns what that option held before, so a caller that has to change it
#' can put it back:
#'
#' ```
#' old <- getaca_policy("offline")
#' on.exit(options(getaca.policy = old), add = TRUE)
#' ```
#'
#' @param policy One of `"bundled"`, `"current"`, `"pinned"`, `"offline"`, or
#'   `NULL` to query without setting.
#'
#' @return When querying, the policy in effect. When setting, the previous
#'   value of the `getaca.policy` option invisibly, `NULL` if it was unset.
#' @export
#'
#' @examples
#' getaca_policy()
#'
#' # Setting it is reversible, because the previous value comes back.
#' old <- getaca_policy("offline")
#' getaca_policy()
#' options(getaca.policy = old)
getaca_policy <- function(policy = NULL) {
  if (is.null(policy)) return(effective_policy())
  policy <- match.arg(policy, c("bundled", "current", "pinned", "offline"))
  previous <- getOption("getaca.policy", NULL)
  options(getaca.policy = policy)
  invisible(previous)
}

effective_policy <- function(registry_default = NULL) {
  if (in_r_check() || is_offline_forced()) return("offline")
  opt <- getOption("getaca.policy", NULL)
  if (!is.null(opt)) return(opt)
  env <- Sys.getenv("GETACA_POLICY", "")
  if (nzchar(env)) return(env)
  registry_default %||% "bundled"
}

is_offline_forced <- function() {
  tolower(Sys.getenv("GETACA_OFFLINE", "")) %in% c("1", "true", "yes")
}

in_r_check <- function() {
  if (identical(tolower(Sys.getenv("NOT_CRAN")), "true")) return(FALSE)
  nzchar(Sys.getenv("_R_CHECK_PACKAGE_NAME_")) ||
    nzchar(Sys.getenv("_R_CHECK_TIMINGS_")) ||
    nzchar(Sys.getenv("_R_CHECK_LICENSE_"))
}

#' Where getaca stores things
#'
#' Uses `tools::R_user_dir("getaca", "cache")` as CRAN policy requires, unless
#' overridden by the `getaca.cache` option or the `GETACA_CACHE` environment
#' variable. Setting `GETACA_CACHE` is the supported way to point a CI job or
#' a check run at a pre-seeded cache.
#'
#' @return A directory path. Not created as a side effect of asking.
#' @export
#'
#' @examples
#' getaca_cache_dir()
getaca_cache_dir <- function() {
  opt <- getOption("getaca.cache", NULL)
  if (!is.null(opt)) return(path.expand(opt))
  env <- Sys.getenv("GETACA_CACHE", "")
  if (nzchar(env)) return(path.expand(env))
  tools::R_user_dir("getaca", "cache")
}

getaca_setting <- function(name, default) {
  opt <- getOption(paste0("getaca.", name), NULL)
  if (!is.null(opt)) return(opt)
  env <- Sys.getenv(paste0("GETACA_", toupper(name)), "")
  if (nzchar(env)) return(utils::type.convert(env, as.is = TRUE))
  default
}

# Retention defaults. "Superseded" and "not recently used" are different
# states and are aged out on different clocks.
setting_supersede_days <- function() getaca_setting("supersede_days", 30)
setting_verify_days    <- function() getaca_setting("verify_days", 90)
setting_max_bytes      <- function() getaca_setting("max_bytes", 20 * 1024^3)
setting_timeout        <- function() getaca_setting("timeout", 3600)
setting_lock_stale     <- function() getaca_setting("lock_stale_seconds", 1800)
