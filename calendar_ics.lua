-- calendar_ics.lua — pure iCalendar (RFC-5545 subset) parser. No KOReader deps.
local ICS = {}
local TZ = require("calendar_timezone")

-- Parse an iCalendar date or date-time value.
-- Returns (epoch_seconds, all_day_bool).
function ICS.parseDateTime(str, zone)
    -- date-only: YYYYMMDD
    local y, m, d = str:match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if y then
        -- isdst left unset (not false): forcing "standard time" here shifts
        -- the epoch by the DST offset in zones observing it (e.g. an August
        -- date in Europe/Lisbon), pushing all-day dtend an hour past the
        -- following midnight and leaking the event into the next day.
        local t = { year=tonumber(y), month=tonumber(m), day=tonumber(d),
                    hour=0, min=0, sec=0 }
        return os.time(t), true
    end
    -- date-time: YYYYMMDDTHHMMSS with optional trailing Z (UTC)
    local Y, Mo, D, H, Mi, S, Z = str:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)(Z?)$")
    if Y then
        local t = { year=tonumber(Y), month=tonumber(Mo), day=tonumber(D),
                    hour=tonumber(H), min=tonumber(Mi), sec=tonumber(S) }
        local epoch = TZ.time(t, zone)
        if Z == "Z" then
            -- UTC conversion must not depend on the device's current DST.
            epoch = TZ.utc(t)
        end
        return epoch, false
    end
    return nil, false
end

-- Parse an RFC-5545 DURATION value (e.g. "PT1H30M", "P2D", "-P1DT12H") into
-- seconds. Months are not valid in durations, so any "M" after the "T" is
-- minutes. Returns nil for values that are not durations.
function ICS.parseDuration(str)
    local sign, body = str:match("^([+%-]?)P(.*)$")
    if not body then return nil end
    local date_part, time_part = body:match("^([^T]*)T?(.*)$")
    local secs = 0
    local w = date_part:match("(%d+)W"); if w then secs = secs + tonumber(w) * 604800 end
    local d = date_part:match("(%d+)D"); if d then secs = secs + tonumber(d) * 86400 end
    local h = time_part:match("(%d+)H"); if h then secs = secs + tonumber(h) * 3600 end
    local m = time_part:match("(%d+)M"); if m then secs = secs + tonumber(m) * 60 end
    local s = time_part:match("(%d+)S"); if s then secs = secs + tonumber(s) end
    return sign == "-" and -secs or secs
end

-- Split a "NAME;PARAM=..;PARAM=..:VALUE" content line into name, params, value.
local function splitLine(line)
    local head, value = line:match("^([^:]+):(.*)$")
    if not head then return nil end
    local name = head:match("^([^;]+)")
    return name:upper(), head, value
end

local function unescape(v)
    v = v:gsub("\\n", "\n"):gsub("\\N", "\n")
    v = v:gsub("\\,", ","):gsub("\\;", ";"):gsub("\\\\", "\\")
    return v
end

-- Unfold folded lines (a line beginning with space or tab continues the prior).
local function unfold(text)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if (line:sub(1,1) == " " or line:sub(1,1) == "\t") and #out > 0 then
            out[#out] = out[#out] .. line:sub(2)
        else
            out[#out + 1] = line
        end
    end
    return out
end

function ICS.parse(text)
    local events = {}
    local lines = unfold(text)
    local zones = TZ.parse(lines)
    local function zoneFor(head, value)
        if value:sub(-1) == "Z" then return TZ.UTC end
        local id = head:match(';TZID="([^"]+)"') or head:match(';TZID=([^;]+)')
        if id and not zones[id] then zones[id] = TZ.system(id) end
        if id and not zones[id] then
            error("Calendar: missing VTIMEZONE definition for TZID " .. id)
        end
        return id and zones[id] or nil
    end
    local cur = nil
    -- Depth of nested components inside the current VEVENT (VALARM etc.).
    -- Their properties must not leak into the event: a Google reminder's
    -- VALARM carries its own "SUMMARY:Alarm notification", which would
    -- otherwise overwrite the event's real title.
    local sub_depth = 0
    for _, line in ipairs(lines) do
        local name, head, value = splitLine(line)
        if name == "BEGIN" and value == "VEVENT" then
            cur = { summary = "", exdates = {} }
            sub_depth = 0
        elseif name == "END" and value == "VEVENT" then
            if cur then
                cur.uid = cur.uid or ("noid-" .. tostring(#events + 1))
                if cur.dtstart then
                    if not cur.dtend then
                        if cur.duration then
                            cur.dtend = cur.dtstart + cur.duration
                        else
                            cur.dtend = cur.all_day and (cur.dtstart + 86400) or cur.dtstart
                        end
                    end
                    events[#events + 1] = cur
                end
            end
            cur = nil
        elseif cur and name == "BEGIN" then
            sub_depth = sub_depth + 1
        elseif cur and name == "END" then
            if sub_depth > 0 then sub_depth = sub_depth - 1 end
        elseif cur and sub_depth == 0 and name then
            if name == "UID" then
                cur.uid = value
            elseif name == "SUMMARY" then
                cur.summary = unescape(value)
            elseif name == "LOCATION" then
                cur.location = unescape(value)
            elseif name == "DESCRIPTION" then
                cur.description = unescape(value)
            elseif name == "DTSTART" then
                cur.timezone = zoneFor(head, value)
                local epoch, all_day = ICS.parseDateTime(value, cur.timezone)
                cur.dtstart = epoch
                cur.all_day = all_day
            elseif name == "DTEND" then
                local epoch = ICS.parseDateTime(value, zoneFor(head, value))
                cur.dtend = epoch
            elseif name == "DURATION" then
                cur.duration = ICS.parseDuration(value)
            elseif name == "RECURRENCE-ID" then
                local epoch = ICS.parseDateTime(value, zoneFor(head, value))
                if epoch then cur.recurrence_id = epoch end
            elseif name == "RRULE" then
                cur.rrule = value
            elseif name == "EXDATE" then
                for part in (value .. ","):gmatch("([^,]*),") do
                    if part ~= "" then
                        local epoch = ICS.parseDateTime(part, zoneFor(head, part))
                        if epoch then cur.exdates[#cur.exdates + 1] = epoch end
                    end
                end
            end
        end
    end
    return events
end

return ICS
