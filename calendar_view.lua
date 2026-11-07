-- calendar_view.lua — pure date helpers + KOReader widget builders.
-- KOReader is required lazily inside the builder functions so the pure date
-- helpers load in plain Lua (e.g. for tests run outside KOReader).
local View = {}

-- Plugin-local translations; degrades to identity outside KOReader, so this
-- module still loads in plain Lua. Named L (not _) because loops below use
-- `_` as a throwaway variable, which would shadow it.
local L = require("calendar_l10n")

-- Minimal "%1" substitution; KOReader's T lives in ffi/util, which is not
-- available in plain Lua.
local function tmpl(s, v)
    return (s:gsub("%%1", tostring(v)))
end

-- os.date wrapper that renders weekday/month names (%a %A %b %B) through
-- KOReader's datetime translation tables, so dates follow the UI language in
-- every KOReader locale. Outside KOReader it is plain (English) os.date.
function View.fdate(fmt, ts)
    local ok, datetime = pcall(require, "datetime")
    if ok and type(datetime) == "table" then
        local map = {
            ["%a"] = datetime.shortDayOfWeekTranslation,
            ["%A"] = datetime.longDayOfWeekTranslation,
            ["%b"] = datetime.shortMonthTranslation,
            ["%B"] = datetime.longMonthTranslation,
        }
        fmt = fmt:gsub("%%[aAbB]", function(tok)
            local name = os.date(tok, ts)
            local t = map[tok]
            if t and t[name] then return t[name] end
            -- KOReader keeps long weekday names keyed by the SHORT English
            -- name (shortDayOfWeekToLongTranslation["Sat"] = "Saturday"
            -- translated); there is no table keyed by the long name.
            if tok == "%A" then
                local t2 = datetime.shortDayOfWeekToLongTranslation
                local short = os.date("%a", ts)
                if t2 and t2[short] then return t2[short] end
            end
            return name
        end)
    end
    return os.date(fmt, ts)
end

local function midnight(epoch)
    local t = os.date("*t", epoch)
    t.hour, t.min, t.sec, t.isdst = 0, 0, 0, nil
    return os.time(t)
end

local function addDays(epoch, n)
    local t = os.date("*t", epoch); t.day = t.day + n; t.isdst = nil
    return os.time(t)
end

function View.dayBounds(epoch)
    local ds = midnight(epoch)
    return ds, addDays(ds, 1)
end

function View.weekBounds(epoch, week_start)
    week_start = week_start or 1  -- 1 = Monday
    local wday = tonumber(os.date("%w", epoch))  -- 0=Sun..6=Sat
    local iso = (wday == 0) and 7 or wday         -- 1=Mon..7=Sun
    local back = (iso - week_start) % 7
    local ws = addDays(midnight(epoch), -back)
    return ws, addDays(ws, 7)
end

function View.monthBounds(epoch)
    local t = os.date("*t", epoch)
    t.day, t.hour, t.min, t.sec, t.isdst = 1, 0, 0, 0, nil
    local ms = os.time(t)
    local tn = os.date("*t", ms); tn.month = tn.month + 1; tn.isdst = nil
    return ms, os.time(tn)
end

function View.windowFor(mode, anchor, week_start)
    if mode == "day" then
        return View.dayBounds(anchor)
    elseif mode == "week" then
        return View.weekBounds(anchor, week_start)
    elseif mode == "month" then
        return View.monthBounds(anchor)
    else -- agenda: 14 days from the anchor's day start
        local ds = midnight(anchor)
        return ds, addDays(ds, 14)
    end
end

-- One bucket per calendar day in [win_start, win_end); each event appears on
-- every day it overlaps.
function View.groupByDay(instances, win_start, win_end)
    local groups = {}
    local cur = midnight(win_start)
    while cur < win_end do
        local nxt = addDays(cur, 1)
        local bucket = { day_start = cur, events = {} }
        for _, inst in ipairs(instances) do
            if inst.dtstart < nxt and inst.dtend > cur then
                bucket.events[#bucket.events + 1] = inst
            end
        end
        groups[#groups + 1] = bucket
        cur = nxt
    end
    return groups
end

-- Bucket a single day's instances by hour-of-day (0..23), separating all-day
-- events into their own list.
function View.groupByHour(instances, day_start)
    local day_end = addDays(day_start, 1)
    local all_day, hours = {}, {}
    for h = 0, 23 do hours[h] = {} end
    for _, inst in ipairs(instances) do
        if inst.dtstart < day_end and inst.dtend > day_start then
            if inst.all_day then
                all_day[#all_day + 1] = inst
            else
                local h = tonumber(os.date("%H", math.max(inst.dtstart, day_start)))
                hours[h][#hours[h] + 1] = inst
            end
        end
    end
    return all_day, hours
end

-- Full weeks of grid cells covering the month containing `anchor`, so a
-- calendar grid can be drawn with whole rows (5 or 6 * 7 cells). Cells
-- outside the month are marked in_month = false.
function View.monthGridDays(anchor, week_start)
    week_start = week_start or 1
    local ms, me = View.monthBounds(anchor)
    local wday = tonumber(os.date("%w", ms))
    local iso = (wday == 0) and 7 or wday
    local back = (iso - week_start) % 7
    local cur = addDays(ms, -back)

    local days = {}
    while true do
        days[#days + 1] = { date = cur, in_month = (cur >= ms and cur < me) }
        cur = addDays(cur, 1)
        if cur >= me and #days % 7 == 0 then break end
    end
    return days
end

function View.formatTime(inst)
    if inst.all_day then return L("All day") end
    return os.date("%H:%M", inst.dtstart)
end

-- ---- Widget builders (manual verification) --------------------------------
-- Each mode gets its own layout. Every builder returns (widget, regions):
--   widget  - a FrameContainer sized to (width, height), ready to display.
--   regions - array of { x, y, w, h, day_start, events } in widget-local
--             coordinates, used by the viewer to resolve taps to events.

local function headerText(mode, win_start, win_end)
    if mode == "day" then return View.fdate("%A, %d %B %Y", win_start) end
    if mode == "week" then return View.fdate("%d %b", win_start) .. " - " .. View.fdate("%d %b %Y", win_end - 1) end
    if mode == "month" then return View.fdate("%B %Y", win_start) end
    return tmpl(L("Agenda from %1"), View.fdate("%d %b %Y", win_start))
end

local function lastSyncText(ts)
    return tmpl(L("Last synced %1"), View.fdate("%d %b %H:%M", ts))
end

-- White-on-black text bar used to highlight "today" headers and the current
-- hour. Zero padding so it occupies exactly the text's height and layout
-- accounting in the builders is unaffected.
local function invertedText(text, face)
    local Blitbuffer     = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local TextWidget     = require("ui/widget/textwidget")
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_BLACK,
        TextWidget:new{ text = text, face = face, fgcolor = Blitbuffer.COLOR_WHITE },
    }
end

local function eventLine(inst)
    local line = View.formatTime(inst) .. "  " .. (inst.summary or "")
    if inst.location and inst.location ~= "" then line = line .. "  -  " .. inst.location end
    return line
end

function View.buildDay(anchor, instances, width, height, opts)
    opts = opts or {}
    local Blitbuffer     = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local VerticalGroup  = require("ui/widget/verticalgroup")
    local VerticalSpan   = require("ui/widget/verticalspan")
    local HorizontalGroup= require("ui/widget/horizontalgroup")
    local TextWidget     = require("ui/widget/textwidget")
    local TextBoxWidget  = require("ui/widget/textboxwidget")
    local LineWidget     = require("ui/widget/linewidget")
    local Geom           = require("ui/geometry")
    local Font           = require("ui/font")
    local Screen         = require("device").screen

    -- FrameContainer:getSize() measures its content, not its explicit
    -- width/height, so a HorizontalGroup/VerticalGroup positioning fixed-size
    -- siblings needs them wrapped in a plain WidgetContainer (whose getSize()
    -- does honor an explicit dimen) to lay out correctly.
    local function fixedBox(w, h, inner)
        return WidgetContainer:new{ dimen = Geom:new{ w = w, h = h }, inner }
    end

    local pad = Screen:scaleBySize(10)
    local inner_w = width - pad * 2
    local title_face = Font:getFace("tfont", 20)
    local head_face  = Font:getFace("smallinfofontbold", 16)
    local body_face  = Font:getFace("infofont", 16)

    local win_start, win_end = View.dayBounds(anchor)
    local all_day, hours = View.groupByHour(instances, win_start)

    local vg = VerticalGroup:new{ align = "left" }
    local regions = {}
    local y = pad

    local title_w = TextWidget:new{ text = headerText("day", win_start, win_end), face = title_face }
    vg[#vg+1] = title_w
    y = y + title_w:getSize().h
    vg[#vg+1] = VerticalSpan:new{ width = math.floor(pad/2) }
    y = y + math.floor(pad/2)

    if #all_day > 0 then
        local all_day_label = L("All day")
        local lines = {}
        for _, inst in ipairs(all_day) do lines[#lines+1] = all_day_label .. "  " .. (inst.summary or "") end
        local box = TextBoxWidget:new{ text = table.concat(lines, "\n"), face = body_face, width = inner_w }
        vg[#vg+1] = box
        local h = box:getSize().h
        regions[#regions+1] = { x = pad, y = y, w = inner_w, h = h, day_start = win_start, events = all_day }
        y = y + h
        vg[#vg+1] = VerticalSpan:new{ width = math.floor(pad/2) }
        y = y + math.floor(pad/2)
    end

    -- Visible hour range: always cover a normal waking day, widen for events
    -- that fall outside it so nothing is hidden.
    local first_h, last_h = 6, 23
    for h = 0, 23 do
        if #hours[h] > 0 then
            if h < first_h then first_h = h end
            if h > last_h then last_h = h end
        end
    end
    local nb_hours = last_h - first_h + 1
    local timeline_h = math.max(height - y, nb_hours)
    local row_h = math.floor(timeline_h / nb_hours)
    local label_w = Screen:scaleBySize(50)

    -- When viewing today, highlight the current hour's label.
    local now = os.time()
    local cur_h = (now >= win_start and now < win_end) and tonumber(os.date("%H", now)) or nil

    local timeline = VerticalGroup:new{ align = "left" }
    for h = first_h, last_h do
        local label_text = string.format("%02d:00", h)
        local label = fixedBox(label_w, row_h,
            h == cur_h and invertedText(label_text, head_face)
                       or TextWidget:new{ text = label_text, face = head_face })
        local sep = LineWidget:new{
            background = Blitbuffer.COLOR_GRAY, dimen = Geom:new{ w = Screen:scaleBySize(1), h = row_h } }
        local text = table.concat((function()
            local lines = {}
            for _, inst in ipairs(hours[h]) do lines[#lines+1] = eventLine(inst) end
            return lines
        end)(), "\n")
        local cell = TextBoxWidget:new{
            text = text, face = body_face, width = inner_w - label_w - Screen:scaleBySize(6),
            height = row_h, height_overflow_show_ellipsis = true,
        }
        local row = HorizontalGroup:new{ align = "top", label, sep, cell }
        timeline[#timeline+1] = row
        regions[#regions+1] = { x = pad, y = y, w = inner_w, h = row_h, day_start = win_start, hour = h, events = hours[h] }
        y = y + row_h
    end
    vg[#vg+1] = timeline

    if opts.last_sync then
        vg[#vg+1] = VerticalSpan:new{ width = math.floor(pad/2) }
        vg[#vg+1] = TextWidget:new{ text = lastSyncText(opts.last_sync), face = head_face }
    end

    local widget = FrameContainer:new{
        bordersize = 0, padding = pad, background = Blitbuffer.COLOR_WHITE,
        width = width, height = height, dimen = Geom:new{ w = width, h = height },
        vg,
    }
    return widget, regions
end

function View.buildWeek(anchor, instances, width, height, opts)
    opts = opts or {}
    local Blitbuffer     = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local VerticalGroup  = require("ui/widget/verticalgroup")
    local VerticalSpan   = require("ui/widget/verticalspan")
    local TextWidget     = require("ui/widget/textwidget")
    local TextBoxWidget  = require("ui/widget/textboxwidget")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local Geom           = require("ui/geometry")
    local Font           = require("ui/font")
    local Screen         = require("device").screen

    local pad = Screen:scaleBySize(10)
    local inner_w = width - pad * 2
    local title_face = Font:getFace("tfont", 20)
    local head_face  = Font:getFace("smallinfofontbold", 16)
    local body_face  = Font:getFace("infofont", 15)

    local win_start, win_end = View.weekBounds(anchor, opts.week_start)
    local groups = View.groupByDay(instances, win_start, win_end)
    local today = midnight(os.time())

    local vg = VerticalGroup:new{ align = "left" }
    local regions = {}
    local y = pad

    local title_w = TextWidget:new{ text = headerText("week", win_start, win_end), face = title_face }
    vg[#vg+1] = title_w
    y = y + title_w:getSize().h
    vg[#vg+1] = VerticalSpan:new{ width = math.floor(pad/2) }
    y = y + math.floor(pad/2)

    local gap = pad
    local inset = Screen:scaleBySize(8)
    local border = math.max(1, Screen:scaleBySize(1))
    local footer
    if opts.last_sync then
        footer = TextWidget:new{ text = lastSyncText(opts.last_sync), face = head_face }
    end
    local footer_h = footer and (footer:getSize().h + gap) or 0
    local columns = width > height and 3 or 2
    local rows = math.ceil(#groups / columns)
    local grid_h = math.max(rows, height - pad - y - footer_h)
    local usable_h = grid_h - gap * (rows - 1)
    local index = 1
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top" }
        local count = math.min(columns, #groups - index + 1)
        local usable_w = inner_w - gap * (count - 1)
        local card_h = math.floor(usable_h * r / rows) - math.floor(usable_h * (r - 1) / rows)
        local x = pad
        for c = 1, count do
            local g = groups[index]
            local card_w = math.floor(usable_w * c / count) - math.floor(usable_w * (c - 1) / count)
            local is_today = g.day_start == today
            local stroke = is_today and border * 2 or border
            local content_w = math.max(1, card_w - 2 * (inset + stroke))
            local head_text = View.fdate("%a  %d %b", g.day_start)
            local head = is_today and invertedText(head_text, head_face)
                or TextWidget:new{ text = head_text, face = head_face, max_width = content_w }
            local lines = {}
            for _, inst in ipairs(g.events) do lines[#lines+1] = eventLine(inst) end
            local body = TextBoxWidget:new{
                text = #lines > 0 and table.concat(lines, "\n") or (opts.empty_text or L("No events")),
                face = body_face, width = content_w,
                height = math.max(1, card_h - 2 * (inset + stroke) - head:getSize().h - math.floor(gap/2)),
                height_overflow_show_ellipsis = true,
            }
            local card = FrameContainer:new{
                width = card_w, height = card_h, margin = 0, padding = inset,
                bordersize = stroke,
                color = is_today and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_B,
                background = Blitbuffer.COLOR_WHITE,
                VerticalGroup:new{ align = "left", head,
                    VerticalSpan:new{ width = math.floor(gap/2) }, body },
            }
            -- Explicit dimensions keep short/empty cards aligned with full ones.
            row[#row+1] = WidgetContainer:new{
                dimen = Geom:new{ w = card_w, h = card_h }, card,
            }
            regions[#regions+1] = {
                x = x, y = y, w = card_w, h = card_h,
                day_start = g.day_start, events = g.events,
            }
            x = x + card_w + gap
            if c < count then row[#row+1] = HorizontalSpan:new{ width = gap } end
            index = index + 1
        end
        vg[#vg+1] = row
        y = y + card_h
        if r < rows then
            vg[#vg+1] = VerticalSpan:new{ width = gap }
            y = y + gap
        end
    end

    if opts.last_sync then
        vg[#vg+1] = VerticalSpan:new{ width = gap }
        vg[#vg+1] = footer
    end

    local widget = FrameContainer:new{
        bordersize = 0, padding = pad, background = Blitbuffer.COLOR_WHITE,
        width = width, height = height, dimen = Geom:new{ w = width, h = height },
        vg,
    }
    return widget, regions
end

function View.buildMonth(anchor, instances, width, height, opts)
    opts = opts or {}
    local Blitbuffer     = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local VerticalGroup  = require("ui/widget/verticalgroup")
    local HorizontalGroup= require("ui/widget/horizontalgroup")
    local VerticalSpan   = require("ui/widget/verticalspan")
    local TextWidget     = require("ui/widget/textwidget")
    local Size           = require("ui/size")
    local Geom           = require("ui/geometry")
    local Font           = require("ui/font")
    local Screen         = require("device").screen

    -- FrameContainer:getSize() measures its content, not its explicit
    -- width/height, so a HorizontalGroup/VerticalGroup positioning fixed-size
    -- siblings needs them wrapped in a plain WidgetContainer (whose getSize()
    -- does honor an explicit dimen) to lay out correctly.
    local function fixedBox(w, h, inner)
        return WidgetContainer:new{ dimen = Geom:new{ w = w, h = h }, inner }
    end

    local pad = Screen:scaleBySize(10)
    local inner_w = width - pad * 2
    local title_face   = Font:getFace("tfont", 20)
    local head_face    = Font:getFace("smallinfofontbold", 15)
    local daynum_face  = Font:getFace("smallinfofontbold", 15)
    local muted_face   = Font:getFace("smallinfofont", 15)
    local event_face   = Font:getFace("x_smallinfofont", 13)

    local win_start, win_end = View.monthBounds(anchor)
    local groups = View.groupByDay(instances, win_start, win_end)
    local by_day = {}
    for _, g in ipairs(groups) do by_day[g.day_start] = g.events end

    local days = View.monthGridDays(anchor, opts.week_start)
    local rows_n = #days / 7
    local today = midnight(os.time())

    local vg = VerticalGroup:new{ align = "left" }
    local regions = {}
    local y = pad

    local title_w = TextWidget:new{ text = headerText("month", win_start, win_end), face = title_face }
    vg[#vg+1] = title_w
    y = y + title_w:getSize().h
    vg[#vg+1] = VerticalSpan:new{ width = math.floor(pad/2) }
    y = y + math.floor(pad/2)

    -- Weekday label row, ordered to match the grid's week_start.
    local wd_row = HorizontalGroup:new{ align = "top" }
    local cell_w = math.floor(inner_w / 7)
    local wd_row_h = head_face.size + Screen:scaleBySize(6)
    for i = 1, 7 do
        local w = (i == 7) and (inner_w - cell_w * 6) or cell_w
        wd_row[#wd_row+1] = fixedBox(w, wd_row_h,
            TextWidget:new{ text = View.fdate("%a", days[i].date), face = head_face })
    end
    vg[#vg+1] = wd_row
    y = y + wd_row:getSize().h

    local footer_h = 0
    if opts.last_sync then footer_h = Screen:scaleBySize(24) + math.floor(pad/2) end
    local grid_h = math.max(height - y - footer_h, rows_n)
    local cell_h = math.floor(grid_h / rows_n)

    local idx = 1
    for _row = 1, rows_n do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 1, 7 do
            local d = days[idx]
            local w = (c == 7) and (inner_w - cell_w * 6) or cell_w
            local events = by_day[d.date] or {}
            local is_today = d.in_month and d.date == today

            local cell_vg = VerticalGroup:new{ align = "left" }
            cell_vg[#cell_vg+1] = TextWidget:new{
                text = os.date("%d", d.date),
                face = d.in_month and daynum_face or muted_face,
                fgcolor = (not d.in_month) and Blitbuffer.COLOR_DARK_GRAY or nil,
            }
            local max_lines = 3
            for i, inst in ipairs(events) do
                if i > max_lines then
                    cell_vg[#cell_vg+1] = TextWidget:new{
                        text = tmpl(L("+%1 more"), #events - max_lines + 1), face = event_face,
                        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                    }
                    break
                end
                cell_vg[#cell_vg+1] = TextWidget:new{
                    text = (inst.all_day and "" or (os.date("%H:%M", inst.dtstart) .. " ")) .. (inst.summary or ""),
                    face = event_face, max_width = w - Screen:scaleBySize(6), truncate_with_ellipsis = true,
                }
            end

            local cell = fixedBox(w, cell_h, FrameContainer:new{
                bordersize = is_today and Size.border.thick or Size.border.thin,
                padding = Screen:scaleBySize(2),
                color = is_today and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_B,
                background = d.in_month and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_GRAY_E,
                width = w, height = cell_h,
                cell_vg,
            })
            row[#row+1] = cell
            regions[#regions+1] = {
                x = pad + (c - 1) * cell_w, y = y, w = w, h = cell_h,
                day_start = d.date, events = events,
            }
            idx = idx + 1
        end
        vg[#vg+1] = row
        y = y + cell_h
    end

    if opts.last_sync then
        vg[#vg+1] = VerticalSpan:new{ width = math.floor(pad/2) }
        vg[#vg+1] = TextWidget:new{ text = lastSyncText(opts.last_sync), face = head_face }
    end

    local widget = FrameContainer:new{
        bordersize = 0, padding = pad, background = Blitbuffer.COLOR_WHITE,
        width = width, height = height, dimen = Geom:new{ w = width, h = height },
        vg,
    }
    return widget, regions
end

function View.buildAgenda(anchor, instances, width, height, opts)
    opts = opts or {}
    local Blitbuffer     = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local VerticalGroup  = require("ui/widget/verticalgroup")
    local VerticalSpan   = require("ui/widget/verticalspan")
    local TextWidget     = require("ui/widget/textwidget")
    local TextBoxWidget  = require("ui/widget/textboxwidget")
    local Geom           = require("ui/geometry")
    local Font           = require("ui/font")
    local Screen         = require("device").screen

    local pad = Screen:scaleBySize(12)
    local inner_w = width - pad * 2
    local title_face = Font:getFace("tfont", 22)
    local head_face  = Font:getFace("smallinfofont", 18)
    local body_face  = Font:getFace("infofont", 18)

    local win_start, win_end = View.windowFor("agenda", anchor)

    local vg = VerticalGroup:new{ align = "left" }
    local regions = {}
    local y = pad

    local title_w = TextWidget:new{ text = headerText("agenda", win_start, win_end), face = title_face }
    vg[#vg+1] = title_w
    y = y + title_w:getSize().h
    vg[#vg+1] = VerticalSpan:new{ width = pad }
    y = y + pad

    local groups = View.groupByDay(instances, win_start, win_end)
    local today = midnight(os.time())
    local any = false
    for _, g in ipairs(groups) do
        if #g.events > 0 then
            any = true
            local head_text = View.fdate("%a %d %b", g.day_start)
            local head = g.day_start == today and invertedText(head_text, head_face)
                                              or TextWidget:new{ text = head_text, face = head_face }
            vg[#vg+1] = head
            y = y + head:getSize().h
            for _, inst in ipairs(g.events) do
                local box = TextBoxWidget:new{ text = eventLine(inst), face = body_face, width = inner_w }
                vg[#vg+1] = box
                local h = box:getSize().h
                regions[#regions+1] = { x = pad, y = y, w = inner_w, h = h, day_start = g.day_start, events = { inst } }
                y = y + h
            end
            vg[#vg+1] = VerticalSpan:new{ width = math.floor(pad/2) }
            y = y + math.floor(pad/2)
        end
    end

    if not any then
        local w = TextWidget:new{ text = opts.empty_text or L("No events"), face = body_face }
        vg[#vg+1] = w
        y = y + w:getSize().h
    end

    if opts.last_sync then
        vg[#vg+1] = VerticalSpan:new{ width = pad }
        vg[#vg+1] = TextWidget:new{
            text = lastSyncText(opts.last_sync), face = head_face }
    end

    local widget = FrameContainer:new{
        bordersize = 0, padding = pad,
        background = Blitbuffer.COLOR_WHITE,
        width = width, height = height,
        dimen = Geom:new{ w = width, h = height },
        vg,
    }
    return widget, regions
end

-- Dispatches to the mode-specific builder. Returns (widget, regions); see
-- the per-mode builders above for the regions format.
function View.build(mode, anchor, instances, width, height, opts)
    if mode == "day" then return View.buildDay(anchor, instances, width, height, opts) end
    if mode == "week" then return View.buildWeek(anchor, instances, width, height, opts) end
    if mode == "month" then return View.buildMonth(anchor, instances, width, height, opts) end
    return View.buildAgenda(anchor, instances, width, height, opts)
end

return View
