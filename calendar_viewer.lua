-- calendar_viewer.lua — interactive full-screen calendar viewer.
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu           = require("ui/widget/menu")
local TextViewer     = require("ui/widget/textviewer")
local UIManager      = require("ui/uimanager")
local VerticalGroup  = require("ui/widget/verticalgroup")
local ButtonTable    = require("ui/widget/buttontable")
local View           = require("calendar_view")
local _              = require("calendar_l10n")
local Screen         = Device.screen

local Viewer = InputContainer:extend{
    store = nil, mode = "week", anchor = nil, week_start = 1, refresh_max_age_h = 12,
    regions = nil, body_dimen = nil,
}

function Viewer:init()
    self.anchor = self.anchor or os.time()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true -- hint for UIManager:_repaint()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = function() return self.body_dimen end } },
            Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
        }
    end
    -- Show cached data immediately; refresh in the next UI tick (with a
    -- visible message) only when the cache is stale AND we are already
    -- online, so opening the viewer never blocks on the network.
    self:rebuild()
    if self.store and self.store.isStale and self.store:isStale(self.refresh_max_age_h) then
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_nm and NetworkMgr and NetworkMgr:isConnected() then
            UIManager:nextTick(function() self:_refreshStale() end)
        end
    end
end

-- Blocking fetch with a visible message, then redraw. Returns the refresh
-- result (nil when the viewer was closed mid-flight).
function Viewer:_doRefresh(force)
    if self._closed or not self.store then return end
    local InfoMessage = require("ui/widget/infomessage")
    local info = InfoMessage:new{ text = _("Refreshing calendars…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok = false
    pcall(function() ok = self.store:refresh(force, self.refresh_max_age_h) end)
    UIManager:close(info)
    if self._closed then return end
    self:rebuild()
    UIManager:setDirty(self, "ui")
    return ok
end

function Viewer:_refreshStale()
    self:_doRefresh(false)
end

-- Manual sync from the button bar: force a refetch (ignore cache age), going
-- through runWhenOnline so KOReader offers to enable Wi-Fi if it is off —
-- appropriate for an explicit user action, unlike the automatic paths.
function Viewer:onSyncNow()
    if not self.store then return true end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then return true end
    NetworkMgr:runWhenOnline(function()
        local ok = self:_doRefresh(true)
        if ok == false then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = _("Could not refresh calendar.") })
        end
    end)
    return true
end

function Viewer:_shiftAnchor(dir)
    local t = os.date("*t", self.anchor); t.isdst = nil
    if self.mode == "day" or self.mode == "agenda" then t.day = t.day + dir
    elseif self.mode == "week" then t.day = t.day + dir * 7
    elseif self.mode == "month" then t.month = t.month + dir end
    self.anchor = os.time(t)
end

function Viewer:_setMode(mode)
    self.mode = mode
    -- Remember the viewer's own mode (separate from the sleep-screen mode).
    G_reader_settings:saveSetting("calendar_viewer_mode", mode)
    self:rebuild()
    self:_repaint()
end

-- E-ink: partial ("ui") refreshes accumulate ghosting; flush with a full
-- refresh every few navigations, like the reader does when turning pages.
function Viewer:_repaint()
    self._nav_count = (self._nav_count or 0) + 1
    UIManager:setDirty(self, self._nav_count % 6 == 0 and "full" or "ui")
end

function Viewer:rebuild()
    local W, H = self.dimen.w, self.dimen.h
    local win_start, win_end = View.windowFor(self.mode, self.anchor, self.week_start)
    local events = {}
    if self.store then
        pcall(function() events = self.store:eventsInWindow(win_start, win_end) end)
    end

    -- Mode buttons mark the active mode with brackets; the table is rebuilt
    -- on every mode change so the marker stays current.
    local function modeBtn(mode, label)
        return {
            text = self.mode == mode and ("[" .. label .. "]") or label,
            callback = function() self:_setMode(mode) end,
        }
    end
    local buttons = ButtonTable:new{
        width = W,
        buttons = {
            {
                modeBtn("day", _("Day")),
                modeBtn("week", _("Week")),
                modeBtn("month", _("Month")),
                modeBtn("agenda", _("Agenda")),
            },
            {
                { text = _("<"),     callback = function() self:onPrev() end },
                { text = _("Today"), callback = function() self:onToday() end },
                { text = _(">"),     callback = function() self:onNext() end },
                { text = _("Sync"),  callback = function() self:onSyncNow() end },
                { text = _("X"),     callback = function() self:onClose() end },
            },
        },
        show_parent = self,
    }
    local btn_h = buttons:getSize().h
    local body, regions = View.build(self.mode, self.anchor, events, W, H - btn_h, {
        week_start = self.week_start,
        last_sync  = self.store and self.store:lastSync() or nil,
        empty_text = _("No events"),
    })
    self.regions = regions or {}
    self.body_dimen = Geom:new{ x = 0, y = btn_h, w = W, h = H - btn_h }

    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, background = Blitbuffer.COLOR_WHITE,
        width = W, height = H,
        dimen = Geom:new{ w = W, h = H },
        VerticalGroup:new{ align = "left", buttons, body },
    }
end

-- Full detail for a single event instance, shown in a TextViewer — this is
-- the same detail screen day/agenda cells (one event per region) already
-- open directly.
function Viewer:_showEventDetail(inst)
    local title = inst.summary or _("Event")
    local lines = {}
    if inst.all_day then
        lines[#lines+1] = View.fdate("%A, %d %B %Y", inst.dtstart) .. " — " .. _("All day")
    else
        lines[#lines+1] = View.fdate("%A, %d %B %Y  %H:%M", inst.dtstart) .. "–" .. os.date("%H:%M", inst.dtend)
    end
    if inst.location and inst.location ~= "" then
        lines[#lines+1] = _("Location: ") .. inst.location
    end
    if inst.source and inst.source ~= "" then
        lines[#lines+1] = _("Calendar: ") .. inst.source
    end
    if inst.description and inst.description ~= "" then
        lines[#lines+1] = ""
        lines[#lines+1] = inst.description
    end
    UIManager:show(TextViewer:new{ title = title, text = table.concat(lines, "\n") })
end

-- Intermediate picker for a region bundling several events (a week/month day
-- cell, an hour slot with overlapping events): one tappable row per event,
-- each opening that event's detail via _showEventDetail.
function Viewer:_showDayList(region)
    local items = {}
    for _, inst in ipairs(region.events) do
        items[#items+1] = {
            text = View.formatTime(inst) .. "  " .. (inst.summary or ""),
            callback = function() self:_showEventDetail(inst) end,
        }
    end
    UIManager:show(Menu:new{
        title = region.day_start and View.fdate("%A, %d %B %Y", region.day_start) or _("Events"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.9),
        is_enable_shortcut = false,
    })
end

-- Content that doesn't fit the compact grid/timeline cells (full event text,
-- descriptions) is shown here instead, opened by tapping a cell/row.
function Viewer:_showRegionDetail(region)
    local events = region.events
    if not events or #events == 0 then return end

    if #events == 1 then
        self:_showEventDetail(events[1])
    else
        self:_showDayList(region)
    end
end

function Viewer:onTap(arg, ges)
    if not self.body_dimen or not self.body_dimen:contains(ges.pos) then return false end
    local lx = ges.pos.x - self.body_dimen.x
    local ly = ges.pos.y - self.body_dimen.y
    for _, r in ipairs(self.regions or {}) do
        if lx >= r.x and lx < r.x + r.w and ly >= r.y and ly < r.y + r.h then
            self:_showRegionDetail(r)
            break
        end
    end
    return true
end

function Viewer:onPrev() self:_shiftAnchor(-1); self:rebuild(); self:_repaint(); return true end
function Viewer:onNext() self:_shiftAnchor(1);  self:rebuild(); self:_repaint(); return true end

function Viewer:onToday()
    self.anchor = os.time()
    self:rebuild()
    self:_repaint()
    return true
end

-- Swipe left/right pages through periods, matching the reader's page-turn
-- muscle memory.
function Viewer:onSwipe(arg, ges)
    if ges.direction == "west" then return self:onNext() end
    if ges.direction == "east" then return self:onPrev() end
    return false
end

function Viewer:onClose()
    self._closed = true
    UIManager:close(self, "full")
    return true
end

return Viewer
