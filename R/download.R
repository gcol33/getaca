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
#' getaca drives the transfer itself, over the curl multi interface, rather
#' than handing a URL to a function that returns when it is done. What that
#' buys is the response status before the first byte is written, and a count of
#' the bytes as they arrive. The first decides where they go; the second is
#' what [getaca-progress] reports.
#'
#' @name getaca-transfer
#' @keywords internal
NULL

new_handle_for <- function(url) {
  h <- curl::new_handle()
  curl::handle_setopt(h,
    url = url,
    timeout = setting_timeout(),
    connecttimeout = 30,
    followlocation = TRUE,
    useragent = sprintf("getaca/%s (R %s.%s)",
                        utils::packageVersion("getaca"),
                        R.version$major, R.version$minor)
  )
  h
}

# A partial transfer is resumable only against the mirror that produced it, so
# each mirror gets its own temporary file. Sharing one file across mirrors
# means a failed attempt at the first is resumed onto by the second, and the
# resulting corruption is indistinguishable from the publisher having changed
# the bytes.
partial_path <- function(record, url) {
  sprintf("%s/%s-%s.part", cache_tmp_dir(),
          substr(record$sha256, 1, 16),
          substr(sha256_bytes(charToRaw(enc2utf8(url))), 1, 8))
}

# Try each mirror in order. Records what each one produced so that the caller
# can tell "nobody answered" from "everybody answered with the same wrong
# bytes", which are user-actionable and author-actionable respectively.
#
# `transport` is the seam between which mirror to trust and how bytes move.
# Adjudication is the part worth testing, and it is testable without a
# network because the transport is injectable.
fetch_to_temp <- function(id, record, quiet = FALSE, transport = try_one,
                          reporter = NULL, auth = NULL) {
  unreachable <- character()
  reasons <- character()
  observed_hashes <- character()
  short <- numeric()
  refused <- list()
  rep <- reporter %||% effective_reporter(quiet)
  # The credential is attached to the transport rather than threaded through the
  # loop, so nothing below here handles one and a stand-in transport is
  # unaffected by a declaration it is not exercising.
  send <- if (is.null(auth)) transport else with_credentials(transport, auth)

  for (url in record$urls) {
    dest <- partial_path(record, url)
    out <- attempt_mirror(url, dest, record, send, rep, id)

    if (identical(out$status, "ok")) {
      return(list(path = dest, url = url, sha256 = out$sha256))
    }
    if (identical(out$status, "mismatch")) {
      observed_hashes <- c(observed_hashes, stats::setNames(out$sha256, url))
    } else {
      unreachable <- c(unreachable, url)
      reasons <- c(reasons, out$reason)
      if (identical(out$status, "truncated")) short <- c(short, out$observed)
      # What this URL required, asked of the declaration rather than of the
      # response, so the report says which variable was wanted whether the
      # server rejected a credential or never saw one.
      if (isTRUE(out$http %in% c(401L, 403L))) {
        refused[[length(refused) + 1L]] <- credential_demand(url, auth) %||%
          list(host = url_host(url), scheme = NA_character_,
               variables = character(), missing = character(), register = NULL)
      }
    }
  }

  # Every mirror that answered agreed with the others and disagreed with the
  # registry. The registry is then the likely error, not the publisher.
  if (length(observed_hashes) > 1L && length(unique(observed_hashes)) == 1L) {
    err_declaration(id, record$sha256, observed_hashes[[1]], names(observed_hashes))
  }
  if (length(observed_hashes) >= 1L) {
    err_upstream_changed(id, record$sha256, observed_hashes[[1]], names(observed_hashes)[1])
  }
  # Nothing failed except by ending short, so the action is to retry rather
  # than to find a network. Mixed causes keep the broader condition, whose
  # message lists each mirror's reason including the truncations.
  if (length(short) && length(short) == length(unreachable)) {
    err_incomplete(id, record$size, max(short))
  }
  # Every failure was a refusal to serve, which is a permission the caller can
  # obtain rather than a network they have to find. Same reasoning as the
  # truncation branch above, and a mixed set keeps the broader condition.
  if (length(refused) && length(refused) == length(unreachable)) {
    err_credentials(id, refused)
  }
  err_unavailable(id, unreachable, reasons)
}

# One mirror, with the partial file it owns. A resumed transfer that completes
# but does not verify indicts the partial rather than the publisher, so the
# same mirror is asked once more from empty. Without that, one stale temporary
# file makes a resource permanently unfetchable and blames upstream for it.
attempt_mirror <- function(url, dest, record, transport, rep, id) {
  out <- one_pass(url, dest, record, transport, rep, id)
  if (identical(out$status, "mismatch") && out$resumed) {
    unlink(dest)
    out <- one_pass(url, dest, record, transport, rep, id)
  }
  if (identical(out$status, "mismatch")) unlink(dest)
  out
}

# One attempt at one mirror, bracketed by the events a reporter sees. The
# bracket is here rather than around the mirror loop because a resumed transfer
# that fails its checksum is asked again from empty, and that second attempt is
# a second transfer to anyone watching.
one_pass <- function(url, dest, record, transport, rep, id) {
  offset <- bytes_on_disk(dest)
  resumed <- offset > 0
  emit(rep, "begin", id = id, url = url, total = record$size, offset = offset)

  res <- transport(url, dest, progress = byte_callback(rep, id, record$size))
  arrived <- bytes_on_disk(dest)

  if (!isTRUE(res$success)) {
    emit(rep, "end", id = id, status = "failed", bytes = arrived,
         reason = res$reason)
    return(list(status = "unreachable", reason = res$reason, resumed = resumed,
                http = res$http))
  }
  emit(rep, "end", id = id, status = "ok", bytes = arrived,
       reason = NA_character_)

  size <- arrived
  if (!is.na(record$size) && size < record$size) {
    unlink(dest)
    return(list(status = "truncated", observed = size, resumed = resumed,
                reason = sprintf("truncated (%s of %s bytes)", size, record$size)))
  }

  observed <- sha256_file(dest)
  status <- if (identical(observed, record$sha256)) "ok" else "mismatch"
  list(status = status, sha256 = observed, resumed = resumed)
}

bytes_on_disk <- function(path) {
  if (!file.exists(path)) return(0)
  size <- file_size(path)
  if (is.na(size)) 0 else size
}

# The handle for one attempt at one mirror.
#
# Content encoding and byte ranges number the same response differently: a
# server compressing on the fly counts encoded bytes, while a resume offset
# counts decoded ones, and libcurl reports the combination as a content-encoding
# error rather than as bytes. Identity is what a resumable transfer needs, and
# what getaca wants for its own sake, since what it hashes is what it stores.
#
# A credential reaches the request as an `Authorization` header and nothing
# else. libcurl withholds that header from a redirect to a different host, and
# these archives redirect to object storage routinely, so a token in a query
# string or in a header of another name would be handed to a third party. Basic
# goes through libcurl's own user and password option, which is the same header
# under the same protection.
transfer_handle <- function(url, offset, auth = NULL) {
  h <- new_handle_for(url)
  curl::handle_setopt(h, accept_encoding = "identity", noprogress = TRUE)
  if (offset > 0) curl::handle_setopt(h, resume_from_large = offset)
  if (identical(auth$scheme, "bearer")) {
    curl::handle_setheaders(h, Authorization = auth$header)
  } else if (identical(auth$scheme, "basic")) {
    curl::handle_setopt(h, userpwd = auth$userpwd, httpauth = 1L)
  }
  h
}

# One mirror, driven over the multi interface. Returns the same two fields
# every transport returns, so which one is in use is invisible above here.
#
# `progress` is called with the cumulative bytes on disk for this attempt,
# including whatever it resumed onto. It is the only thing the transport knows
# about reporting: what the bytes mean, and how they are drawn, belongs to the
# reporter that supplied the callback.
try_one <- function(url, dest, progress = NULL, auth = NULL) {
  offset <- bytes_on_disk(dest)
  handle <- transfer_handle(url, offset, auth)
  st <- new.env(parent = emptyenv())
  st$con <- NULL
  st$refused <- FALSE
  st$base <- 0
  st$written <- 0
  st$status <- NA_integer_
  st$completed <- FALSE
  st$error <- NA_character_

  on.exit(close_transfer(st), add = TRUE)

  pool <- curl::new_pool()
  curl::multi_add(
    handle, pool = pool,
    data = function(buf, final) receive(st, handle, buf, dest, offset, progress),
    done = function(res) {
      st$completed <- TRUE
      st$status <- res$status_code
    },
    fail = function(err) st$error <- as.character(err)
  )
  curl::multi_run(pool = pool)
  close_transfer(st)
  transfer_result(st, dest, offset)
}

# Where the bytes go is decided once, on the first chunk, from the status the
# response already carries. Three cases, and only the first is the ordinary one:
# a partial continued, a range request the server ignored, and a response whose
# body is not the resource at all.
receive <- function(st, handle, buf, dest, offset, progress) {
  if (is.null(st$con) && !st$refused) open_destination(st, handle, dest, offset)
  if (st$refused) return(invisible(NULL))
  writeBin(buf, st$con)
  st$written <- st$written + length(buf)
  if (!is.null(progress)) progress(st$base + st$written)
  invisible(NULL)
}

open_destination <- function(st, handle, dest, offset) {
  status <- tryCatch(curl::handle_data(handle)$status_code,
                     error = function(e) NA_integer_)
  st$status <- status
  # An error response has a body, and it is not the resource. Refusing to open
  # the file is what keeps it out of a partial a later attempt would resume
  # onto, and leaves bytes an earlier attempt did get where they are.
  if (is.na(status) || status >= 400) {
    st$refused <- TRUE
    return(invisible(NULL))
  }
  # 206 is the range honoured. Anything else in the 2xx range answered a resume
  # request with the whole file, so what is on disk is the first bytes of it
  # twice over unless the file is truncated first.
  resuming <- offset > 0 && identical(as.integer(status), 206L)
  st$base <- if (resuming) offset else 0
  st$con <- file(dest, open = if (resuming) "ab" else "wb")
  invisible(NULL)
}

close_transfer <- function(st) {
  if (!is.null(st$con)) {
    close(st$con)
    st$con <- NULL
  }
  invisible(NULL)
}

transfer_result <- function(st, dest, offset) {
  if (!st$completed) {
    reason <- if (!is.na(st$error) && nzchar(st$error)) st$error else "transfer failed"
    return(list(success = FALSE, reason = reason, http = NA_integer_))
  }
  status <- st$status
  if (!is.na(status) && status >= 400) {
    # Nothing was written, so what is on disk is whatever was there before. An
    # empty file is not a partial and leaves nothing to resume onto, and 416
    # says the offset is past the end of the file the server holds, so the
    # partial disagrees with upstream and cannot be continued. Anything else
    # keeps the bytes an earlier attempt did get.
    if (offset == 0 || identical(as.integer(status), 416L)) unlink(dest)
    return(list(success = FALSE, reason = paste("HTTP", status),
                http = as.integer(status)))
  }
  # A resource of no bytes still has to arrive as a file, and a response with an
  # empty body never reaches the writer.
  if (!file.exists(dest)) file.create(dest)
  list(success = TRUE, reason = NA_character_, http = as.integer(status))
}

# Verified bytes join the store under their own digest, and the version slot
# gets a name for them. The two steps are separate because the bytes belong to
# every package that declares them and the name belongs to one.
promote <- function(id, record, temp_path) {
  admit(temp_path, record$sha256)
  place(id, record)
}

# The version slot's name for bytes that are already in the store. `link`
# carries through to materialise(), so which mechanism the filesystem allows is
# a decision a caller can stand in for.
place <- function(id, record, link = link_file) {
  view <- file.path(cache_raw_dir(id), record_file_name(record))
  list(path = view, link = materialise(record$sha256, view, link = link))
}

# What the artefact is called in the slot. A declaration may state it, and a
# record composed from parts must, since each part's URL names a piece rather
# than the result.
record_file_name <- function(record) {
  record$file %||% url_basename(record$urls[1])
}

# One move, by whichever mechanism the filesystem allows: a rename when both
# sides sit on one device, a copy when they do not, which a cache pointed at
# another disk makes routine. `rename` is the seam between the two, the way
# `transport` is the seam in fetch_to_temp(). A copy that fails leaves the
# verified temporary file alone, so the retry resumes onto complete bytes
# rather than starting the transfer again.
move_file <- function(from, to, rename = file.rename) {
  if (isTRUE(rename(from, to))) return(TRUE)
  ok <- file.copy(from, to, overwrite = TRUE)
  if (ok) unlink(from)
  ok
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
