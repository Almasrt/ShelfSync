-- wrapper around storygraph_api to add higher level methods
local _ = require("gettext")
local logger = require("shelfsync/lib/common/safe_logger")

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")

local Book = require("shelfsync/lib/common/book")

local BaseProvider = require("shelfsync/lib/common/base_provider")
local STORYGRAPH = require("shelfsync/lib/storygraph/constants")

local StoryGraph = setmetatable({}, { __index = BaseProvider })
StoryGraph.__index = StoryGraph

function StoryGraph:showChangeEditionDialog(callback)
  local editions = self.api:findEditions(self.settings:getLinkedBookId(), self.user:getId())
  self.dialog_manager:buildSearchDialog(
    "Select edition",
    editions,
    {
      book_id = self.settings:getLinkedBookId()
    },
    function(book)
      if book.book_id ~= self.settings:getLinkedBookId() then
        local success = self.api:switchEdition(self.settings:getLinkedBookId(), book.book_id)
        if not success then
          self.dialog_manager:showError("Failed to switch edition on StoryGraph. Please try again.")
          return
        end
      end
      self:linkBookManually(book)
      if callback then
        callback(book)
      end
    end
  )
end

function StoryGraph:linkBook(book, link_method, target_filename, options)
  local filename = target_filename or (self.ui.document and self.ui.document.file)
  if not filename then
    return false
  end

  -- 1. Fetch remote status (API handles redirection and audio filtering internally)
  local status, lookup_error = self.api:findUserBook(book.book_id)
  status = status or {}

  -- 2. If the final resolved edition is Audio, fail the linking process
  if status.is_audio then
    logger.warn("StoryGraph: Cannot link to an Audio edition.")
    UIManager:show(InfoMessage:new{
      text = _("StoryGraph: Cannot link to an Audio edition. Please select a text-based edition.")
    })
    return false
  end

  -- 3. If findUserBook resolved to a different (non-audio) edition, use that ID instead
  if status.id and status.id ~= book.book_id then
    logger.info("StoryGraph: Redirecting link to your active edition: " .. status.id)
    book.book_id = status.id
    book.pages = status.book_num_of_pages or book.pages
  end

  local delete = self:_deletedKeys(book, { "book_id", "edition_id", "edition_format", "pages", "title" })

  local new_settings = {
    book_id = book.book_id,
    edition_format = status.edition_format or Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    link_method = link_method,
    _delete = delete
  }

  -- 3. Save link information
  self.settings:updateBookSetting(filename, new_settings)
  self.state.book_status = status

  -- 4. Auto-Add to Library if no status was found on ANY edition. A failed
  -- lookup isn't proof of that, and adding the book could replace a status
  -- it already has (e.g. Read).
  if lookup_error then
    logger.warn("StoryGraph: Couldn't check the book's status, not adding it to Currently Reading: " .. tostring(lookup_error))
    UIManager:show(InfoMessage:new {
      text = _("Linked, but couldn't check the book's status on StoryGraph, so it wasn't marked as Currently Reading automatically. Use \"Update status\" to set it manually."),
      icon = "notice-warning",
    })
  elseif not (options and options.suppress_auto_reading_status) and not self.state.book_status.status_id then
    logger.info("StoryGraph: Book has no status on any edition, adding to Currently Reading automatically")
    local added = self.api:updateUserBook(book.book_id, STORYGRAPH.STATUS.READING)
    if added and added.status_id then
      self.state.book_status = added
    else
      -- The book stays linked locally either way (settings already saved
      -- above), but without this the failure was completely silent -- the
      -- book would just sit unsynced until the status-mismatch warning
      -- eventually caught it much later, with no link back to the cause.
      logger.warn("StoryGraph: Failed to automatically mark book as Currently Reading on StoryGraph")
      self.state.book_status = added or {}
      UIManager:show(InfoMessage:new {
        text = _("Linked, but couldn't automatically mark the book as Currently Reading on StoryGraph. Use \"Update status\" to set it manually."),
        icon = "notice-warning",
      })
    end
  end

  return true
end

function StoryGraph:showBookshelfRatingLinkDialog(filename, title, authors, on_linked, on_cancel)
  if type(filename) ~= "string" or filename == "" or type(title) ~= "string" or title == "" then
    UIManager:show(InfoMessage:new {
      text = _("Cannot search StoryGraph because this book has no usable title."),
      icon = "notice-warning",
    })
    if on_cancel then on_cancel() end
    return false
  end

  authors = type(authors) == "string" and authors or ""

  self.wifi:withWifi(function(_wifi_enabled, wifi_error)
    if wifi_error then
      UIManager:show(InfoMessage:new {
        text = _("Could not connect to StoryGraph to search for this book."),
        icon = "notice-warning",
      })
      if on_cancel then on_cancel() end
      return
    end

    local results, err = self.api:findBooks(title, authors, self.user:getId())
    if err then
      self.dialog_manager:showError(err)
      if on_cancel then on_cancel() end
      return
    end
    if not results or #results == 0 then
      UIManager:show(InfoMessage:new {
        text = _("No StoryGraph matches found. You can link this book manually from ShelfSync."),
        icon = "notice-warning",
      })
      if on_cancel then on_cancel() end
      return
    end

    self.dialog_manager:buildSearchDialog(
      _("Link this book to StoryGraph"),
      results,
      {},
      function(selected_book)
        local linked = self:linkBook(selected_book, "manual", filename, {
          suppress_auto_reading_status = true,
        })
        if linked and on_linked then
          on_linked(selected_book.book_id)
        elseif on_cancel then
          on_cancel()
        end
      end,
      function(search)
        local dialog = self.dialog_manager.search_dialog
        Trapper:wrap(function()
          local found, search_error = self.api:findBooks(search, authors, self.user:getId())
          if search_error then
            self.dialog_manager:showError(search_error)
          elseif dialog and self.dialog_manager.search_dialog == dialog then
            dialog:setItems(_("Link this book to StoryGraph"), found or {}, {})
          end
        end)
        return true
      end,
      title,
      on_cancel
    )
  end)
  return true
end

-- Remote progress in `update_type`'s unit, read from a cached book_status
-- table (e.g. self.state.book_status), used by SyncEngine to skip a
-- background write that would move progress backward.
function StoryGraph:getRemoteProgress(status, update_type)
  if update_type == "pages" then
    return tonumber(status and status.last_reached_pages) or 0
  end
  return tonumber(status and status.percent_finished) or 0
end

-- Overall remote completion percent (0-100), or nil if unknown. Used by
-- "Jump to position" and to seed the note dialog's remote-percent hint.
function StoryGraph:getRemotePercent(status)
  return tonumber(status and status.last_reached_percent) or 0
end

-- Writes a progress update to StoryGraph and returns the refreshed status, or
-- nil plus an error reason on failure. Also auto-marks the book Finished when
-- the write pushes it to 100% while still Currently Reading.
function StoryGraph:pushProgress(current_read, value, update_type, filename)
  if not current_read then
    return nil, "No active reading session found on StoryGraph"
  end

  local result = self.api:updatePage(current_read.id, value, current_read.started_at, update_type)
  if not result then
    return nil
  end

  if (tonumber(result.percent_finished) or 0) >= 100 and result.status_id == STORYGRAPH.STATUS.READING then
    local book_id = self.settings:readBookSetting(filename, "book_id")
    if book_id then
      local finished = self.api:updateUserBook(book_id, STORYGRAPH.STATUS.FINISHED)
      if finished then
        result = finished
        self:onMarkedFinished(book_id, filename)
      end
    end
  end

  return result
end

-- ReviewMenu entry point. StoryGraph has no standalone rating/text fields --
-- both are always part of a full review object -- so this round-trips
-- whatever review already exists (same pattern as onMarkedFinished above)
-- and only overwrites the fields the user actually set. Accepts the full
-- quarter-star value unrounded.
---@diagnostic disable-next-line: duplicate-set-field
function StoryGraph:submitReview(filename, rating, text)
  local cache_error = self.cache and self.cache:cacheUserBook(filename)
  if cache_error then
    return false, cache_error
  end

  local book_id = self.state.book_status and self.state.book_status.id
  if not book_id then
    return false, "No linked book found on StoryGraph"
  end

  local review_url = self.state.book_status.review_url
  local review = (review_url and self.api:getReview(review_url)) or {
    pace = "", driven = "", development = "", loveable = "",
    diverse = "", flaws = "", themes = "", thoughts = "", mood_ids = {}
  }
  if rating and rating > 0 then
    review.stars = rating
  end
  if text and text ~= "" then
    review.thoughts = text
  end

  return self.api:saveReview(book_id, review, review_url) == true
end

function StoryGraph:submitBookshelfRating(filename, expected_book_id, rating)
  if not filename or not expected_book_id then
    return false, "Book is not linked to StoryGraph"
  end

  local linked_book_id = self.settings:readBookSetting(filename, "book_id")
    or self.settings:readBookSetting(filename, "edition_id")
  if tostring(linked_book_id or "") ~= tostring(expected_book_id) then
    return false, "The local StoryGraph link changed before the rating was sent"
  end

  local status, lookup_error = self.api:findUserBook(expected_book_id, self.user:getId())
  if not status or not status.id or tostring(status.id) ~= tostring(expected_book_id) then
    return false, lookup_error or "The linked StoryGraph book could not be verified"
  end

  local review_url = status.review_url
  local review
  if review_url then
    review = self.api:getReview(review_url)
    if not review then
      return false, "Could not read the existing StoryGraph review; rating was not changed"
    end
  else
    review = {
      pace = "", driven = "", development = "", loveable = "",
      diverse = "", flaws = "", themes = "", thoughts = "", mood_ids = {},
    }
  end

  review.stars = tonumber(rating) or 0
  if self.api:saveReview(expected_book_id, review, review_url) ~= true then
    return false, "StoryGraph did not accept the rating"
  end
  return true
end

return StoryGraph
