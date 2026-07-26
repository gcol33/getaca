#' Transfer and promotion
#'
#' Bytes land in `.tmp/`, are sized, hashed, and only then moved into the
#' cache. An interrupted transfer can never appear as a valid cached resource,
#' and a failed transfer never touches a copy that was already good.
#'
#' The temporary file is named after the declared checksum, so an interrupted
#' download resumes on the next attempt rather than starting over. That
#' matters when the resource is measured in gigabytes.
#'
#' @name getaca-transfer
#' @keywords internal
NULL

new_handle_for <- function(url) {
  h <- curl::new_handle()
  curl::handle_setopt(h,
    timeout = setting_timeout(),
    connecttimeout = 30,
    followlocation = TRUE,
    useragent = sprintf("getaca/%s (R %s.%s)",
                        utils::packageVersion("getaca"),
                        R.version$major, R.version$minor)
  )
  h
}

partial_path <- function(record) {
  file.path(cache_tmp_dir(), paste0(substr(record$sha256, 1, 16), ".part"))
}

# Try each mirror in order. Records what each one produced so that the caller
# can tell "nobody answered" from "everybody answered with the same wrong
# bytes", which are user-actionable and author-actionable respectively.
#
# `transport` is the seam between which mirror to trust and how bytes move.
# Adjudication is the part worth testing, and it is testable without a
# network because the transport is injectable.
fetch_to_temp <- function(id, record, quiet = FALSE, transport = try_one) {
  dest <- partial_path(record)
  unreachable <- character()
  reasons <- character()
  observed_hashes <- character()

  for (url in record$urls) {
    res <- transport(url, dest, quiet = quiet)
    if (!isTRUE(res$success)) {
      unreachable <- c(unreachable, url)
      reasons <- c(reasons, res$reason)
      next
    }

    size <- file_size(dest)
    if (!is.na(record$size) && size < record$size) {
      unlink(dest)
      unreachable <- c(unreachable, url)
      reasons <- c(reasons, sprintf("truncated (%s of %s bytes)", size, record$size))
      next
    }

    observed <- sha256_file(dest)
    if (identical(observed, record$sha256)) {
      return(list(path = dest, url = url, sha256 = observed))
    }

    observed_hashes <- c(observed_hashes, stats::setNames(observed, url))
    unlink(dest)
  }

  # Every mirror that answered agreed with the others and disagreed with the
  # registry. The registry is then the likely error, not the publisher.
  if (length(observed_hashes) > 1L && length(unique(observed_hashes)) == 1L) {
    err_declaration(id, record$sha256, observed_hashes[[1]], names(observed_hashes))
  }
  if (length(observed_hashes) >= 1L) {
    err_upstream_changed(id, record$sha256, observed_hashes[[1]], names(observed_hashes)[1])
  }
  err_unavailable(id, unreachable, reasons)
}

try_one <- function(url, dest, quiet = FALSE) {
  out <- tryCatch(
    curl::multi_download(
      url, dest,
      resume = TRUE,
      progress = !quiet && interactive(),
      timeout = setting_timeout()
    ),
    error = function(e) NULL
  )
  if (is.null(out)) return(list(success = FALSE, reason = "transfer failed"))
  if (!isTRUE(out$success[1])) {
    reason <- if (!is.na(out$error[1]) && nzchar(out$error[1])) {
      out$error[1]
    } else {
      paste("HTTP", out$status_code[1])
    }
    return(list(success = FALSE, reason = reason))
  }
  if (!is.na(out$status_code[1]) && out$status_code[1] >= 400) {
    return(list(success = FALSE, reason = paste("HTTP", out$status_code[1])))
  }
  list(success = TRUE, reason = NA_character_)
}

# Move verified bytes into their final slot. The destination directory is
# built beside the target and renamed, so a reader never sees a partially
# populated version directory.
promote <- function(id, record, temp_path) {
  raw <- cache_raw_dir(id)
  dir.create(raw, recursive = TRUE, showWarnings = FALSE)
  final <- file.path(raw, url_basename(record$urls[1]))
  if (file.exists(final)) unlink(final)
  ok <- file.rename(temp_path, final)
  if (!ok) {
    ok <- file.copy(temp_path, final, overwrite = TRUE)
    unlink(temp_path)
  }
  if (!ok) {
    stop(sprintf("getaca: could not move the verified file into the cache at %s", final),
         call. = FALSE)
  }
  final
}

url_basename <- function(url) {
  path <- sub("[?#].*$", "", url)
  # Drop scheme and authority, so a URL with no path does not name the cached
  # file after the host.
  path <- sub("^[A-Za-z][A-Za-z0-9+.-]*://[^/]*", "", path)
  path <- sub("/+$", "", path)
  base <- basename(path)
  if (!nzchar(base) || identical(base, "/")) "resource.bin" else base
}
