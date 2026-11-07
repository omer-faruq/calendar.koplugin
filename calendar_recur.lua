-- calendar_recur.lua — pure recurrence expansion (RFC-5545 subset). No KOReader deps.
local Recur = {}
local TZ = require("calendar_timezone")
local ICS = require("calendar_ics")

local MAX_ITER = 2000
local WDAY = { SU=1, MO=2, TU=3, WE=4, TH=5, FR=6, SA=7 }  -- os.date %w+1

local function parseRule(rrule, zone)
    local r = {}
    for k, v in (rrule .. ";"):gmatch("([^=;]+)=([^;]*);") do
        r[k:upper()] = v
    end
    r.INTERVAL = tonumber(r.INTERVAL) or 1
    if r.INTERVAL < 1 then r.INTERVAL = 1 end
    r.COUNT = tonumber(r.COUNT)
    if r.UNTIL then
        -- UNTIL is a date or date-time (often Z); reuse the same field parse.
        local y,mo,d,H,Mi,S = r.UNTIL:match("^(%d%d%d%d)(%d%d)(%d%d)T?(%d?%d?)(%d?%d?)(%d?%d?)Z?$")
        if y then
            r.UNTIL_TS = ICS.parseDateTime(r.UNTIL:find("T") and r.UNTIL
                or (r.UNTIL .. "T235959"), zone)
        end
    end
    if r.BYDAY then
        local days = {}
        for day in (r.BYDAY .. ","):gmatch("([^,]*),") do
            if WDAY[day] then days[#days + 1] = WDAY[day] end
        end
        r.BYDAY_SET = days
    end
    return r
end

-- Add n calendar units of the given frequency to an epoch, preserving
-- wall-clock time across DST (arithmetic done on broken-down local time).
local function addUnits(epoch, freq, n, zone)
    local t = TZ.date(epoch, zone)
    if freq == "DAILY" then
        t.day = t.day + n
    elseif freq == "WEEKLY" then
        t.day = t.day + n * 7
    elseif freq == "MONTHLY" then
        t.month = t.month + n
    elseif freq == "YEARLY" then
        t.year = t.year + n
    end
    t.isdst = nil
    return TZ.time(t, zone)
end

-- Start-of-week (as os epoch) containing `epoch`, week starting Monday.
local function weekStart(epoch, zone)
    local wday = TZ.date(epoch, zone).wday - 1
    local back = (wday == 0) and 6 or (wday - 1)  -- days back to Monday
    local t = TZ.date(epoch, zone)
    t.day = t.day - back
    t.isdst = nil
    return TZ.time(t, zone)
end

-- Set the time-of-day of `day_epoch` to match the h/m/s of `ref_epoch`.
local function withTimeOf(day_epoch, ref_epoch, zone)
    local d = TZ.date(day_epoch, zone)
    local r = TZ.date(ref_epoch, zone)
    d.hour, d.min, d.sec = r.hour, r.min, r.sec
    d.isdst = nil
    return TZ.time(d, zone)
end

function Recur.expand(event, window_start, window_end)
    local dur = event.dtend - event.dtstart
    local exset = {}
    for _, ex in ipairs(event.exdates or {}) do exset[ex] = true end

    local function emit(list, start_ts)
        if exset[start_ts] then return end               -- excluded by EXDATE
        local endt = start_ts + dur
        if endt > window_start and start_ts < window_end then
            list[#list + 1] = {
                uid = event.uid, summary = event.summary, location = event.location,
                description = event.description,
                all_day = event.all_day, dtstart = start_ts, dtend = endt,
            }
        end
    end

    -- Non-recurring
    if not event.rrule then
        local out = {}
        emit(out, event.dtstart)
        return out
    end

    local zone = event.timezone
    local r = parseRule(event.rrule, zone)
    local freq = (r.FREQ or "DAILY"):upper()
    local out = {}
    local count = 0            -- counts every generated occurrence (before EXDATE)

    -- Candidate generator: for WEEKLY+BYDAY, each period yields multiple days.
    local function periodStarts(period_anchor)
        if freq == "WEEKLY" and r.BYDAY_SET and #r.BYDAY_SET > 0 then
            local ws = weekStart(period_anchor, zone)
            local starts = {}
            for _, target in ipairs(r.BYDAY_SET) do   -- target: 1=Sun..7=Sat
                -- Monday's index in our 1..7 (Sun=1) space is 2; day offset from
                -- Monday = (target - 2) mod 7.
                local off = (target - 2) % 7
                local day = TZ.date(ws, zone)
                day.day = day.day + off
                day.isdst = nil
                starts[#starts + 1] = withTimeOf(TZ.time(day, zone), event.dtstart, zone)
            end
            table.sort(starts)
            return starts
        else
            return { period_anchor }
        end
    end

    local anchor = event.dtstart

    -- Fast-forward toward window_start for unbounded DAILY/WEEKLY series so a
    -- long-running event (e.g. a daily event started years ago) does not exhaust
    -- MAX_ITER before reaching the window. Only safe when COUNT is absent, since
    -- COUNT requires counting every skipped occurrence.
    if not r.COUNT and event.dtstart < window_start then
        local skip
        if freq == "DAILY" then
            skip = math.floor((window_start - event.dtstart) / (86400 * r.INTERVAL)) - 1
        elseif freq == "WEEKLY" then
            skip = math.floor((window_start - event.dtstart) / (7 * 86400 * r.INTERVAL)) - 1
        end
        if skip and skip > 0 then
            anchor = addUnits(event.dtstart, freq, skip * r.INTERVAL, zone)
        end
    end

    for _ = 1, MAX_ITER do
        local starts = periodStarts(anchor)
        for _, s in ipairs(starts) do
            if s >= event.dtstart then                 -- never before series start
                if r.UNTIL_TS and s > r.UNTIL_TS then goto done end
                if s >= window_end then goto done end  -- periods only advance forward
                count = count + 1                      -- counts EXDATE'd occ too
                emit(out, s)                           -- emit() itself skips EXDATE'd
                if r.COUNT and count >= r.COUNT then goto done end
            end
        end
        anchor = addUnits(anchor, freq, r.INTERVAL, zone)
        if anchor > window_end + 366 * 86400 then break end   -- absolute safety
    end
    ::done::
    table.sort(out, function(a, b) return a.dtstart < b.dtstart end)
    return out
end

return Recur
