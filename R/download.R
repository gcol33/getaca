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
#' @section When a transfer is given up on:
#' A transfer is given up on for standing still, never for taking long. A
#' connection that takes longer than `getaca.connect_seconds`, 30 by default,
#' to open, or that delivers nothing for `getaca.stall_seconds`, 60 by
#' default, is dropped. One that keeps delivering runs for as long as the file
#' takes. `getaca.timeout` limits a whole transfer, in seconds, and is off
#' unless set.
#'
#' A connection that dropped after delivering bytes is resumed on the same
#' mirror, for as long as each attempt gets further. A mirror that answers
#' that it is busy (HTTP 408, 429, 500, 502, 503 or 504) is asked again after
#' a wait that doubles from two seconds, or after the interval its
#' `Retry-After` header names, and never after more than a minute. Attempts
#' that move nothing are counted against `getaca.retries`, 3 by default, after
#' which the next mirror is tried. A mirror that never answered, or answered
#' that the file is not there, is not asked twice.
#'
#' @section Several files at once:
#' The parts of a series, and the resources of one [getaca_prefetch()] call,
#' share up to `getaca.connections` connections, 4 by default. A file two of
#' them name is transferred once.
#'
#' Each setting is also read from an environment variable,
#' `GETACA_STALL_SECONDS` for `getaca.stall_seconds` and so on, when the
#' option is unset.
#'
#' @name getaca-transfer
#' @keywords internal
NULL

# A transfer is given up on for standing still, never for taking long. A cap
# on the whole operation would fail every file too large for the link it
# arrives over, which is the size this package exists for, so what is bounded
# is how long a connection may deliver nothing. `getaca.timeout` remains for a
# caller who does want the whole operation capped, and is off unless set.
new_handle_for <- function(url) {
  h <- curl::new_handle()
  curl::handle_setopt(h,
    url = url,
    timeout = setting_timeout(),
    connecttimeout = setting_connect(),
    low_speed_limit = 1,
    low_speed_time = setting_stall(),
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
                          reporter = NULL, auth = NULL, sleep = Sys.sleep) {
  got <- fetch_many(list(list(id = id, record = record)), quiet = quiet,
                    transport = transport, reporter = reporter, auth = auth,
                    sleep = sleep)[[1]]
  if (inherits(got, "condition")) stop(got)
  got
}

# Several files at once, each walking its own mirrors. An item is what one
# transfer needs to know: the identity it reports under, the record naming the
# bytes and where they are served, and the credential declarations in force for
# it. The result for each is where the verified bytes landed, or the condition
# its mirrors added up to, so one file failing leaves the others to finish.
#
# The work goes in rounds. Every file still unsettled makes one attempt, the
# attempts of a round move together, and each is then judged on its own: done,
# the same mirror again, or the next mirror. A file therefore never waits on
# another's bytes, only on another's retry.
fetch_many <- function(items, quiet = FALSE, transport = try_one,
                       reporter = NULL, auth = NULL, sleep = Sys.sleep) {
  rep <- reporter %||% effective_reporter(quiet)
  jobs <- lapply(items, new_job, auth = auth)
  repeat {
    open <- which(vapply(jobs, function(j) is.null(j$result), logical(1)))
    if (!length(open)) break
    wait <- max(vapply(jobs[open], function(j) j$wait, numeric(1)))
    if (wait > 0) sleep(wait)
    for (k in open) jobs[[k]]$offset <- bytes_on_disk(job_dest(jobs[[k]]))
    attempts <- lapply(jobs[open], job_attempt, rep = rep)
    results <- run_attempts(attempts, transport)
    for (i in seq_along(open)) {
      jobs[[open[i]]] <- settle_job(jobs[[open[i]]], results[[i]], rep)
    }
  }
  lapply(jobs, function(j) j$result)
}

new_job <- function(item, auth = NULL) {
  list(id = item$id, record = item$record, auth = item$auth %||% auth,
       mirror = 1L, idle = 0L, wait = 0, offset = 0, result = NULL,
       unreachable = character(), reasons = character(),
       observed = character(), short = numeric(), refused = list())
}

job_url <- function(job) job$record$urls[job$mirror]
job_dest <- function(job) partial_path(job$record, job_url(job))

# One attempt at one mirror, as the transport is handed it. The begin event is
# raised here rather than once per mirror because an attempt that is repeated
# is a second transfer to anyone watching.
job_attempt <- function(job, rep) {
  emit(rep, "begin", id = job$id, url = job_url(job),
       total = job$record$size, offset = job$offset)
  with_credentials(
    list(url = job_url(job), dest = job_dest(job),
         progress = byte_callback(rep, job$id, job$record$size)),
    job$auth
  )
}

# What one attempt came to, and what the file does next.
settle_job <- function(job, res, rep) {
  url <- job_url(job)
  dest <- job_dest(job)
  out <- judge_attempt(job, res, bytes_on_disk(dest), dest, rep)
  job$wait <- 0

  if (identical(out$status, "ok")) {
    job$result <- list(path = dest, url = url, sha256 = out$sha256)
    return(job)
  }
  if (identical(out$status, "mismatch")) {
    unlink(dest)
    # A resumed transfer that completes but does not verify indicts the partial
    # rather than the publisher, so the same mirror is asked once more from
    # empty. Without that, one stale temporary file makes a resource
    # permanently unfetchable and blames upstream for it.
    if (job$offset > 0) return(job)
    job$observed <- c(job$observed, stats::setNames(out$sha256, url))
    return(next_mirror(job))
  }
  if (identical(out$status, "unreachable") && worth_retrying(job, out)) {
    # A mirror that is delivering is asked again for as long as it delivers. The
    # count is of attempts that moved nothing, which is what a mirror that has
    # stopped answering looks like and a long file on a poor link does not.
    job$idle <- if (out$progressed) 0L else job$idle + 1L
    if (job$idle <= setting_retries()) {
      job$wait <- retry_wait(job$idle, out$retry_after)
      return(job)
    }
  }

  job$unreachable <- c(job$unreachable, url)
  job$reasons <- c(job$reasons, out$reason)
  if (identical(out$status, "truncated")) job$short <- c(job$short, out$observed)
  # What this URL required, asked of the declaration rather than of the
  # response, so the report says which variable was wanted whether the server
  # rejected a credential or never saw one.
  if (isTRUE(out$http %in% c(401L, 403L))) {
    job$refused[[length(job$refused) + 1L]] <- credential_demand(url, job$auth) %||%
      list(host = url_host(url), scheme = NA_character_,
           variables = character(), missing = character(), register = NULL)
  }
  next_mirror(job)
}

next_mirror <- function(job) {
  job$mirror <- job$mirror + 1L
  job$idle <- 0L
  if (job$mirror > length(job$record$urls)) {
    job$result <- tryCatch(adjudicate(job), getaca_error = function(e) e)
  }
  job
}

# Every mirror has been tried. Which condition that adds up to depends on what
# the mirrors did between them, not on what the last one did.
adjudicate <- function(job) {
  id <- job$id
  record <- job$record
  observed <- job$observed
  # Every mirror that answered agreed with the others and disagreed with the
  # registry. The registry is then the likely error, not the publisher.
  if (length(observed) > 1L && length(unique(observed)) == 1L) {
    err_declaration(id, record$sha256, observed[[1]], names(observed))
  }
  if (length(observed) >= 1L) {
    err_upstream_changed(id, record$sha256, observed[[1]], names(observed)[1])
  }
  # Nothing failed except by ending short, so the action is to retry rather
  # than to find a network. Mixed causes keep the broader condition, whose
  # message lists each mirror's reason including the truncations.
  if (length(job$short) && length(job$short) == length(job$unreachable)) {
    err_incomplete(id, record$size, max(job$short))
  }
  # Every failure was a refusal to serve, which is a permission the caller can
  # obtain rather than a network they have to find. Same reasoning as the
  # truncation branch above, and a mixed set keeps the broader condition.
  if (length(job$refused) && length(job$refused) == length(job$unreachable)) {
    err_credentials(id, job$refused)
  }
  err_unavailable(id, job$unreachable, job$reasons)
}

# One attempt, read against the record: bracketed by the event a reporter sees
# it end with, then sized, then hashed.
judge_attempt <- function(job, res, arrived, dest, rep) {
  record <- job$record
  if (!isTRUE(res$success)) {
    emit(rep, "end", id = job$id, status = "failed", bytes = arrived,
         reason = res$reason)
    return(list(status = "unreachable", reason = res$reason, http = res$http,
                retry_after = res$retry_after,
                progressed = arrived > job$offset))
  }
  emit(rep, "end", id = job$id, status = "ok", bytes = arrived,
       reason = NA_character_)

  if (!is.na(record$size) && arrived < record$size) {
    unlink(dest)
    return(list(status = "truncated", observed = arrived,
                reason = sprintf("truncated (%s of %s bytes)", arrived, record$size)))
  }

  observed <- sha256_file(dest)
  list(status = if (identical(observed, record$sha256)) "ok" else "mismatch",
       sha256 = observed)
}

# Statuses that describe the moment rather than the request: the server is
# busy, restarting, or asking the client to slow down.
TRANSIENT_STATUS <- c(408L, 429L, 500L, 502L, 503L, 504L)

# Two failures are worth putting to the same mirror again. A connection that
# dropped after delivering bytes left a partial this mirror can continue, and
# moving on would abandon it for a transfer from zero somewhere else. And a
# server that says it is busy has said the request itself was fine. A mirror
# that never answered, or answered that the file is not there, is told apart
# from both by having sent nothing and no such status.
worth_retrying <- function(job, out) {
  answered <- !is.null(out$http) && !is.na(out$http)
  if (answered) return(out$http %in% TRANSIENT_STATUS)
  isTRUE(out$progressed)
}

RETRY_WAIT_CEILING <- 60

# Doubling from one second, unless the server named its own interval. Either
# way no longer than a minute: a wait a caller cannot see the end of is a hang.
retry_wait <- function(idle, retry_after = NULL) {
  asked <- retry_after %||% NA_real_
  wait <- if (is.na(asked)) 2^idle else asked
  min(RETRY_WAIT_CEILING, max(0, wait))
}

bytes_on_disk <- function(path) {
  # A transfer with no destination has nothing on disk to continue from, so it
  # always starts at zero.
  if (is.null(path) || !file.exists(path)) return(0)
  size <- file_size(path)
  if (is.na(size)) 0 else size
}

# A transport moves one attempt, and is called as
# `transport(url, dest, progress =)` with `auth =` added where the declaration
# names a credential for the host. One that can move several attempts over
# shared connections carries the function that does so as `many`; any other is
# driven one attempt at a time, which is what a stand-in in a test is.
run_attempts <- function(attempts, transport) {
  many <- attr(transport, "many", exact = TRUE)
  if (!is.null(many)) return(many(attempts))
  lapply(attempts, function(a) do.call(transport, a))
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

# Several attempts, driven together over one pool. Each returns the fields
# every transport returns, so how many moved at once is invisible above here.
#
# An attempt's `progress` is called with the cumulative bytes on disk for it,
# including whatever it resumed onto. It is the only thing the transport knows
# about reporting: what the bytes mean, and how they are drawn, belongs to the
# reporter that supplied the callback.
#
# `dest = NULL` asks for the digest instead of the file. The bytes are hashed
# as they arrive and dropped, and the result carries `sha256` and `bytes` in
# place of a path. Nothing is written, so nothing can be resumed and nothing is
# left behind; that is the shape a caller wanting a checksum rather than a copy
# needs, and it is what makes hashing a hundred gigabytes cost no disk.
try_many <- function(attempts) {
  limit <- setting_connections()
  pool <- curl::new_pool(total_con = limit, host_con = limit)
  states <- list()
  on.exit(for (st in states) close_transfer(st), add = TRUE)
  for (a in attempts) states[[length(states) + 1L]] <- start_transfer(pool, a)
  curl::multi_run(pool = pool)
  lapply(states, function(st) {
    close_transfer(st)
    transfer_result(st)
  })
}

# The transport a retrieval uses unless it is handed another.
try_one <- structure(
  function(url, dest, progress = NULL, auth = NULL) {
    try_many(list(list(url = url, dest = dest, progress = progress,
                       auth = auth)))[[1]]
  },
  many = try_many
)

start_transfer <- function(pool, attempt) {
  st <- new.env(parent = emptyenv())
  st$dest <- attempt$dest
  st$offset <- bytes_on_disk(attempt$dest)
  st$progress <- attempt$progress
  st$con <- NULL
  # Made before the first chunk rather than on it, so a response with an empty
  # body still produces the digest of no bytes rather than nothing at all.
  st$digest <- if (is.null(attempt$dest)) sha256_stream() else NULL
  st$opened <- FALSE
  st$refused <- FALSE
  st$base <- 0
  st$written <- 0
  st$status <- NA_integer_
  st$retry_after <- NA_real_
  st$completed <- FALSE
  st$error <- NA_character_

  handle <- transfer_handle(attempt$url, st$offset, attempt$auth)
  curl::multi_add(
    handle, pool = pool,
    data = function(buf, final) receive(st, handle, buf),
    done = function(res) {
      st$completed <- TRUE
      st$status <- res$status_code
      st$retry_after <- retry_after(res$headers)
    },
    fail = function(err) st$error <- as.character(err)
  )
  st
}

# Where the bytes go is decided once, on the first chunk, from the status the
# response already carries. Three cases, and only the first is the ordinary one:
# a partial continued, a range request the server ignored, and a response whose
# body is not the resource at all.
receive <- function(st, handle, buf) {
  if (!st$opened && !st$refused) open_destination(st, handle)
  if (st$refused) return(invisible(NULL))
  if (is.null(st$dest)) {
    sha256_stream_update(st$digest, buf)
  } else {
    writeBin(buf, st$con)
  }
  st$written <- st$written + length(buf)
  if (!is.null(st$progress)) st$progress(st$base + st$written)
  invisible(NULL)
}

open_destination <- function(st, handle) {
  status <- tryCatch(curl::handle_data(handle)$status_code,
                     error = function(e) NA_integer_)
  st$status <- status
  # An error response has a body, and it is not the resource. Refusing to open
  # the file is what keeps it out of a partial a later attempt would resume
  # onto, and leaves bytes an earlier attempt did get where they are. A hashed
  # transfer refuses for the same reason: an error page is not what the caller
  # asked for the digest of.
  if (is.na(status) || status >= 400) {
    st$refused <- TRUE
    return(invisible(NULL))
  }
  st$opened <- TRUE
  if (is.null(st$dest)) return(invisible(NULL))
  # 206 is the range honoured. Anything else in the 2xx range answered a resume
  # request with the whole file, so what is on disk is the first bytes of it
  # twice over unless the file is truncated first.
  resuming <- st$offset > 0 && identical(as.integer(status), 206L)
  st$base <- if (resuming) st$offset else 0
  st$con <- file(st$dest, open = if (resuming) "ab" else "wb")
  invisible(NULL)
}

close_transfer <- function(st) {
  if (!is.null(st$con)) {
    close(st$con)
    st$con <- NULL
  }
  invisible(NULL)
}

# How long the server asked to be left alone, in seconds, or NA where it did
# not say. The header carries either a count of seconds or a date, and a
# response reached through redirects carries every hop's headers, of which the
# last is the one that answered.
retry_after <- function(headers, now = Sys.time()) {
  lines <- tryCatch(curl::parse_headers(headers), error = function(e) character())
  hit <- grep("^retry-after:", lines, ignore.case = TRUE, value = TRUE)
  if (!length(hit)) return(NA_real_)
  value <- trimws(sub("^[^:]*:", "", hit[length(hit)]))
  if (grepl("^[0-9]+$", value)) return(as.numeric(value))
  at <- tryCatch(curl::parse_date(value), error = function(e) NA)
  if (is.na(at)) return(NA_real_)
  max(0, as.numeric(difftime(at, now, units = "secs")))
}

transfer_result <- function(st) {
  dest <- st$dest
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
    if (!is.null(dest) && (st$offset == 0 || identical(as.integer(status), 416L))) {
      unlink(dest)
    }
    return(list(success = FALSE, reason = paste("HTTP", status),
                http = as.integer(status), retry_after = st$retry_after))
  }
  if (is.null(dest)) {
    digest <- sha256_stream_final(st$digest)
    return(list(success = TRUE, reason = NA_character_,
                http = as.integer(status),
                sha256 = digest$sha256, bytes = digest$size))
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
