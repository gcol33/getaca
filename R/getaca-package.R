#' getaca: Reproducible External Data Dependencies
#'
#' Lets an R package declare that it depends on data living somewhere else,
#' and makes that dependency behave like a dependency: pinned to exact bytes,
#' resolvable offline, and safe during `R CMD check`.
#'
#' @section The four responsibilities:
#' \describe{
#'   \item{Get}{Resolve mirrors, download safely, return an ordinary local path.}
#'   \item{Authenticate}{Verify the exact expected bytes before the path is
#'     handed back. Throughout the API this operation is called \emph{verify};
#'     "authentication" is reserved for credentials, which are declared rather
#'     than held. See [getaca-auth].}
#'   \item{Track}{Record version, registry state, resolution policy, observed
#'     checksum and verification state.}
#'   \item{Cache}{Reuse resources across sessions and actively remove
#'     obsolete material, as CRAN policy requires.}
#' }
#'
#' @section Identity:
#' A resource is identified by the triple `package / name / version`, never by
#' name alone. Two packages may declare the same physical file; their
#' dependency records stay separate.
#'
#' A registry is identified by [registry_digest()], derived from the
#' declaration rather than asserted beside it. Provenance records that digest,
#' so a cached file names the exact declaration state that resolved it.
#'
#' @keywords internal
#' @useDynLib getaca, .registration = TRUE, .fixes = "C_"
"_PACKAGE"

## usethis namespace: start
## usethis namespace: end
NULL
