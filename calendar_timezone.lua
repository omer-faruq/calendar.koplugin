-- Calendar arithmetic is performed on UTC-shaped wall-clock values.
local TZ = {}
local unpack = unpack or table.unpack

-- KOReader uses LuaJIT on Unix. Fall back to the device's zoneinfo database
-- when an ICS producer omits VTIMEZONE. Restore process state before returning.
local ok, ffi = pcall(require, 'ffi')
if ok then
    pcall(ffi.cdef, [[
        char *getenv(const char *name);
        int setenv(const char *name, const char *value, int overwrite);
        int unsetenv(const char *name);
        void tzset(void);
    ]])
end
function TZ.system(id)
    if not ok or id:find('..',1,true) or id:sub(1,1) == '/' then return nil end
    for _, root in ipairs{'/usr/share/zoneinfo/', '/usr/lib/zoneinfo/', '/etc/zoneinfo/'} do
        local f = io.open(root .. id, 'rb')
        if f then
            local magic = f:read(4)
            f:close()
            if magic == 'TZif' then return {system=root .. id} end
        end
    end
end
local function inZone(zone, fn)
    local old = ffi.C.getenv('TZ')
    old = old ~= nil and ffi.string(old) or nil
    assert(ffi.C.setenv('TZ', ':' .. zone.system, 1) == 0)
    ffi.C.tzset()
    local success, result = pcall(fn)
    if old then ffi.C.setenv('TZ',old,1) else ffi.C.unsetenv('TZ') end
    ffi.C.tzset()
    if not success then error(result) end
    return result
end

function TZ.utc(t)
    local y, m = t.year, t.month
    y = y + math.floor((m - 1) / 12)
    m = (m - 1) % 12 + 1
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yo = y - era * 400
    local mp = m + (m > 2 and -3 or 9)
    local days = era * 146097 + yo * 365 + math.floor(yo / 4)
        - math.floor(yo / 100) + math.floor((153 * mp + 2) / 5)
        + t.day - 1 - 719468
    return days * 86400 + (t.hour or 0) * 3600 + (t.min or 0) * 60 + (t.sec or 0)
end

function TZ.fields(value)
    local y,m,d,h,n,s = value:match('^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z?$')
    if not y then return nil end
    return {year=tonumber(y), month=tonumber(m), day=tonumber(d),
        hour=tonumber(h), min=tonumber(n), sec=tonumber(s)}
end

local weekdays = {SU=0, MO=1, TU=2, WE=3, TH=4, FR=5, SA=6}
local function offset(value)
    local sign,h,m,s = value:match('^([+-])(%d%d)(%d%d)(%d*)$')
    if not sign then return nil end
    return (sign == '-' and -1 or 1) * (tonumber(h)*3600 + tonumber(m)*60 + (tonumber(s) or 0))
end

function TZ.parse(lines)
    local zones, zone, rule = {}, nil, nil
    for _, line in ipairs(lines) do
        local key, value = line:match('^([^:;]+)[^:]*:(.*)$')
        if key == 'BEGIN' and value == 'VTIMEZONE' then zone = {rules={}}
        elseif zone then
            if key == 'TZID' then zone.id = value
            elseif key == 'BEGIN' and (value == 'STANDARD' or value == 'DAYLIGHT') then rule = {dates={}}
            elseif key == 'END' and (value == 'STANDARD' or value == 'DAYLIGHT') then
                if rule and rule.start and rule.from and rule.to then zone.rules[#zone.rules+1] = rule end
                rule = nil
            elseif key == 'END' and value == 'VTIMEZONE' then
                if zone.id then zones[zone.id] = zone end
                zone = nil
            elseif rule then
                if key == 'DTSTART' then rule.start = TZ.fields(value)
                elseif key == 'TZOFFSETFROM' then rule.from = offset(value)
                elseif key == 'TZOFFSETTO' then rule.to = offset(value)
                elseif key == 'RRULE' then
                    rule.rrule = {}
                    for k,v in (value..';'):gmatch('([^=;]+)=([^;]*);') do rule.rrule[k] = v end
                elseif key == 'RDATE' then
                    for v in value:gmatch('[^,]+') do
                        local t = TZ.fields(v)
                        if t then rule.dates[#rule.dates+1] = t end
                    end
                end
            end
        end
    end
    return zones
end

local function transitions(zone, year)
    local out = {}
    local function add(rule, t)
        out[#out+1] = {at=TZ.utc(t)-rule.from, from=rule.from, to=rule.to}
    end
    for _, rule in ipairs(zone.rules) do
        add(rule, rule.start)
        for _, t in ipairs(rule.dates or {}) do add(rule, t) end
        local r = rule.rrule
        if r and r.FREQ == 'YEARLY' then
            for y = math.max(rule.start.year, year-2), year+1 do
                local t = {year=y, month=tonumber(r.BYMONTH) or rule.start.month,
                    day=tonumber(r.BYMONTHDAY) or rule.start.day,
                    hour=rule.start.hour, min=rule.start.min, sec=rule.start.sec}
                if t.day < 0 then
                    t.day = 1
                    local nextmonth = {year=y, month=t.month+1, day=1}
                    t.day = (TZ.utc(nextmonth)-TZ.utc{year=y,month=t.month,day=1})/86400 + tonumber(r.BYMONTHDAY) + 1
                end
                if r.BYDAY then
                    local n, day = r.BYDAY:match('^([+-]?%d+)(%u%u)$')
                    n = tonumber(n)
                    if n and weekdays[day] then
                        t.day = 1
                        if n < 0 then
                            t.day = (TZ.utc{year=y,month=t.month+1,day=1}-TZ.utc{year=y,month=t.month,day=1})/86400
                            local w = (math.floor(TZ.utc(t)/86400)+4)%7
                            t.day = t.day - (w-weekdays[day])%7 + (n+1)*7
                        else
                            local w = (math.floor(TZ.utc(t)/86400)+4)%7
                            t.day = 1 + (weekdays[day]-w)%7 + (n-1)*7
                        end
                    end
                end
                local at = TZ.utc(t)-rule.from
                local until_t = r.UNTIL and TZ.fields(r.UNTIL)
                if TZ.utc(t) >= TZ.utc(rule.start) and (not until_t or at <= TZ.utc(until_t)) then add(rule,t) end
            end
        end
    end
    table.sort(out, function(a,b) return a.at < b.at end)
    return out
end

function TZ.offset(zone, epoch)
    local ts = transitions(zone, os.date('!*t',epoch).year)
    local result = ts[1] and ts[1].from or 0
    for _, t in ipairs(ts) do
        if t.at > epoch then break end
        result = t.to
    end
    return result
end

function TZ.time(t, zone)
    if not zone then t.isdst=nil; return os.time(t) end
    if zone.system then return inZone(zone, function() t.isdst=nil; return os.time(t) end) end
    local wall = TZ.utc(t)
    -- Test both offsets around a transition; choose the first occurrence in a fold.
    local candidates = {}
    for _, r in ipairs(zone.rules) do
        for _, off in ipairs{r.from,r.to} do
            local epoch = wall-off
            if TZ.offset(zone,epoch) == off then candidates[#candidates+1] = epoch end
        end
    end
    if #candidates > 0 then return math.min(unpack(candidates)) end
    return wall-TZ.offset(zone,wall-86400)
end

function TZ.date(epoch, zone)
    if zone and zone.system then return inZone(zone, function() return os.date('*t',epoch) end) end
    return os.date(zone and '!*t' or '*t', epoch + (zone and TZ.offset(zone,epoch) or 0))
end

TZ.UTC = {rules={{start={year=1970,month=1,day=1},from=0,to=0}}}
return TZ
