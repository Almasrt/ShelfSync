local _ = require("gettext")

local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")

local BookshelfRatingBridge = {}
BookshelfRatingBridge.__index = BookshelfRatingBridge

function BookshelfRatingBridge:new(o)
  return setmetatable(o or {}, self)
end

function BookshelfRatingBridge:onRatingChanged(filename, rating, title, authors)
  if type(filename) ~= "string" or filename == "" then return true end
  if rating ~= nil then
    rating = tonumber(rating)
    if not rating or rating < 1 or rating > 5 or rating % 1 ~= 0 then
      return true
    end
  end

  local engine = self.engine
  if not engine or not engine:isActive() then return true end

  self.state.rating_sync_pending = self.state.rating_sync_pending or {}
  if self.state.rating_sync_pending[filename] then return true end
  self.state.rating_sync_pending[filename] = true

  local function clear_pending()
    self.state.rating_sync_pending[filename] = nil
  end

  local function ask_to_send(linked_book_id)
    if not linked_book_id then
      clear_pending()
      return
    end

    local rating_label = rating ~= nil and (tostring(rating) .. " / 5") or _("cleared")
    UIManager:show(ConfirmBox:new {
      text = _("Send the Bookshelf rating to the linked StoryGraph book?")
        .. "\n\n" .. _("Rating: ") .. rating_label,
      ok_text = _("Send"),
      cancel_text = _("Cancel"),
      ok_callback = function()
        engine.wifi:withWifi(function(_wifi_enabled, wifi_error)
          if wifi_error then
            clear_pending()
            UIManager:show(InfoMessage:new {
              text = _("Could not connect to StoryGraph. The local rating was kept."),
              icon = "notice-warning",
            })
            return
          end

          local success, reason = engine.provider:submitBookshelfRating(
            filename, linked_book_id, rating
          )
          clear_pending()
          UIManager:show(InfoMessage:new {
            text = success and _("Rating sent to StoryGraph.")
              or (_("Could not send rating to StoryGraph: ") .. tostring(reason or _("Unknown error"))),
            icon = success and nil or "notice-warning",
            timeout = success and 3 or nil,
          })
        end)
      end,
      cancel_callback = clear_pending,
    })
  end

  local linked_book_id = engine.settings:readBookSetting(filename, "book_id")
    or engine.settings:readBookSetting(filename, "edition_id")
  if linked_book_id then
    ask_to_send(linked_book_id)
    return true
  end

  engine.provider:showBookshelfRatingLinkDialog(
    filename,
    title,
    authors,
    ask_to_send,
    clear_pending
  )
  return true
end

return BookshelfRatingBridge
