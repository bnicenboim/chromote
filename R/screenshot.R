ChromoteSession$set("public", "screenshot",
  function(
    filename = "screenshot.png",
    selector = "html",
    cliprect = NULL,
    region = c("content", "padding", "border", "margin"),
    expand = NULL,
    scale = 1,
    show = FALSE,
    wait_ = TRUE
  ) {
    force(filename)
    force(selector)
    force(cliprect)
    force(region)
    force(expand)
    force(scale)
    force(show)
    force(wait_)

    region = match.arg(region)
    if (length(filename) == 0 && !show) {
      stop("Cannot have empty filename and show=FALSE")
    }

    if (!is.null(cliprect) && !(is.numeric(cliprect) && length(cliprect) == 4)) {
      stop("`cliprect` must be NULL or a numeric vector with 4 elements (for left, top, width, and height).")
    }

    if (is.null(expand)) {
      expand <- 0
    }
    if (!is.numeric(expand) ||
        !(length(expand) == 1 || length(expand) == 4)) {
      stop("`expand` must be NULL, or a numeric vector with 1 or 4 elements (for top, right, bottom, left)")
    }
    if (length(expand) == 1) {
      expand <- rep(expand, 4)
    }


    # These vars are used to store information gathered from one step to use
    # in a later step.
    visual_viewport <- NULL  # Initial viewport dimensions
    image_data      <- NULL
    overall_width   <- NULL
    overall_height  <- NULL
    root_node_id    <- NULL

    # Setup stuff for both selector and cliprect code paths.
    p <- self$Emulation$setScrollbarsHidden(hidden = TRUE, wait_ = FALSE)$
      then(function(value) {
        self$Page$getLayoutMetrics(wait_ = FALSE)
      })$
      then(function(value) {
        visual_viewport <<- value$visualViewport

        self$DOM$getDocument(wait_ = FALSE)
      })$
      then(function(value) {
        root_node_id <<- value$root$nodeId
        self$DOM$querySelector(value$root$nodeId, "html", wait_ = FALSE)
      })$
      then(function(value) {
        self$DOM$getBoxModel(value$nodeId, wait_ = FALSE)
      })$
      then(function(value) {
        overall_width  <<- value$model$width
        overall_height <<- value$model$height

        # Make viewport the same size as content -- seems to be necessary
        # on Chrome 75 for Mac, though it wasn't necessary for 72. Without
        # this, the screenshot will be the full height, but everything
        # outside the viewport area will be blank white.
        self$Emulation$setVisibleSize(
          width = overall_width,
          height = overall_height,
          wait_ = FALSE
        )

        promise(function(resolve, reject) {
          # TODO: Wait 0.5 second for resize to complete. Can we wait for an
          # event instead?
          later(function() resolve(TRUE), 0.5)
        })
      })


    if (is.null(cliprect)) {
      # This code path uses the selector instead of cliprect.
      p <- p$
        then(function(value) {
          find_selectors_bounds(self, root_node_id, selector, region)
        })$
        then(function(value) {
          # Note: `expand` values are top, right, bottom, left.
          xmin <- value$xmin - expand[4]
          xmax <- value$xmax + expand[2]
          ymin <- value$ymin - expand[1]
          ymax <- value$ymax + expand[3]

          # We need to make sure that we don't go beyond the bounds of the
          # page.
          xmin <- max(xmin, 0)
          xmax <- min(xmax, overall_width)
          ymin <- max(ymin, 0)
          ymax <- min(ymax, overall_height)

          self$Page$captureScreenshot(
            clip = list(
              x = xmin,
              y = ymin,
              width  = xmax - xmin,
              height = ymax - ymin,
              scale = scale / private$pixel_ratio
            ),
            fromSurface = TRUE,
            wait_ = FALSE
          )
        })$
        then(function(value) {
          image_data <<- value
        })

    } else {
      # If cliprect was provided, use it instead of selector
      p <- p$
        then(function(value) {
          self$Page$captureScreenshot(
            clip = list(
              x = cliprect[[1]],
              y = cliprect[[2]],
              width  = cliprect[[3]],
              height = cliprect[[4]],
              scale = scale / private$pixel_ratio
            ),
            fromSurface = TRUE,
            wait_ = FALSE
          )
        })$
        then(function(value) {
          image_data <<- value
        })
    }

    p <- p$
      then(function(value) {
        # Restore original viewport size
        self$Emulation$setVisibleSize(
          width = visual_viewport$clientWidth,
          height = visual_viewport$clientHeight,
          wait_ = FALSE
        )

        # Un-hide scrollbars
        self$Emulation$setScrollbarsHidden(hidden = FALSE, wait_ = FALSE)
      })$
      then(function(value) {
        temp_output <- FALSE
        if (is.null(filename)) {
          temp_output <- TRUE
          filename <- tempfile("chromote-screenshot-", fileext = ".png")
          on.exit(unlink(filename))
        }

        writeBin(jsonlite::base64_dec(image_data$data), filename)
        if (show) {
          showimage::show_image(filename)
        }

        if (temp_output) {
          invisible()
        } else {
          invisible(filename)
        }
      })$
      catch(function(err) {
        warning("An error occurred: ", err)
      })

    if (wait_) {
      self$wait_for(p)
    } else {
      p
    }
  }
)


ChromoteSession$set("public", "screenshot_pdf",
  function(
    filename = "screenshot.pdf",
    pagesize = "letter",
    margins = 0.5,
    units = c("in", "cm"),
    landscape = FALSE,
    display_header_footer = FALSE,
    print_background = FALSE,
    scale = 1,
    wait_ = TRUE
  ) {
    force(filename)
    force(pagesize)
    force(margins)
    force(units)
    force(landscape)
    force(display_header_footer)
    force(print_background)
    force(scale)
    force(wait_)

    page_sizes <- list(
      letter  = c(8.5,   11),
      legal   = c(8.5,   14),
      tabloid = c(11,    17),
      ledger  = c(17,    11),
      a0      = c(33.1,  46.8),
      a1      = c(23.4,  33.1),
      a2      = c(16.54, 23.4),
      a3      = c(11.7,  16.54),
      a4      = c(8.27,  11.7),
      a5      = c(5.83,  8.27),
      a6      = c(4.13,  5.83)
    )

    units <- match.arg(units)

    if (units == "cm") {
      margins <- margins / 2.54
    }

    if (is.character(pagesize)) {
      pagesize <- tolower(pagesize)
      pagesize <- match.arg(pagesize, names(page_sizes))
      pagesize <- page_sizes[[pagesize]]

    } else if (is.numeric(pagesize) && length(pagesize) == 2) {
      # User has passed in width and height values
      if (units == "cm") {
        pagesize <- pagesize / 2.54
      }

    } else {
      stop('`pagesize` must be one of "', paste(names(page_sizes), collapse = '", "'),
        '", or a two-element vector of width and height.')
    }

    if (length(margins) == 1) {
      margins <- rep(margins, 4)
    }
    if (length(margins) != 4) {
      stop('`margins` must be a single number, or a four-element numeric vector representing',
        ' the margins for top, right, bottom, and left, respectively.')
    }

    p <- self$Page$printToPDF(
        landscape           = landscape,
        displayHeaderFooter = display_header_footer,
        printBackground     = print_background,
        scale               = scale,
        paperWidth          = pagesize[[1]],
        paperHeight         = pagesize[[2]],
        marginTop           = margins[[1]],
        marginBottom        = margins[[3]],
        marginLeft          = margins[[4]],
        marginRight         = margins[[2]],
        wait_ = FALSE
      )$
      then(function(value) {
        writeBin(jsonlite::base64_dec(value$data), filename)
        filename
      })

    if (wait_) {
      invisible(self$wait_for(p))
    } else {
      p
    }
  }
)


# Find a bounding box that contains the elements selected by any number of
# selectors. Note that a selector can pick out more than one element.
find_selectors_bounds <- function(cm, root_node_id, selectors, region = "content") {
  ps <- lapply(selectors, function(selector) {
    cm$DOM$querySelectorAll(root_node_id, selector, wait_ = FALSE)$
      then(function(value) {
        # There can be multiple nodes for a given selector, so we need to
        # process all of them.
        ps <- lapply(value$nodeIds, function(nodeId) {
          cm$DOM$getBoxModel(nodeId, wait_ = FALSE)$
            catch(function(value) {
              # Can get an error, "Could not compute box model", if the element
              # is not visible. Just return NULL in this case.
              NULL
            })
        })

        promise_all(.list = ps)
      })$
      then(function(values) {
        # Could have gotten emtpy list for non-visible elements; remove them.
        values <- drop_nulls(values)

        lapply(values, function(value) {
          list(
            xmin = value$model[[region]][[1]],
            xmax = value$model[[region]][[3]],
            ymin = value$model[[region]][[2]],
            ymax = value$model[[region]][[6]]
          )
        })
      })
  })

  promise_all(.list = ps)$
    then(function(value) {
      value <- unlist(value, recursive = FALSE)
      if (length(value) == 0) {
        stop("Unable to find any visible elements for selectors.")
      }

      list(
        xmin = min(fetch_key_n(value, "xmin")),
        xmax = max(fetch_key_n(value, "xmax")),
        ymin = min(fetch_key_n(value, "ymin")),
        ymax = max(fetch_key_n(value, "ymax"))
      )
    })
}
