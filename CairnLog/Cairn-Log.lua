-- Cairn-Log
-- Categorized ring-buffer log shared across every consumer of the lib.
-- One source-level logger per addon, with optional category sub-loggers.
-- Forge_Logs reads from the shared buffer to render its UI.
--
--   local CL  = LibStub("Cairn-Log")
--   local log = CL:New("MyAddon")
--
--   log:Info("loaded successfully")
--   log:Warn("connection slow")
--   log:Error("got %d errors", 5)              -- string.format args
--   log:Debug("user clicked %s", buttonName)
--
--   -- Category sub-logger (no category on the parent stays uncategorized)
--   local netLog = log:Category("net")
--   netLog:Warn("packet dropped")               -- entry has category = "net"
--
--   -- Singleton operations on the shared buffer
--   for _, e in ipairs(CL:GetEntries({ level = "WARN", limit = 50 })) do
--       print(e.timestamp, e.source, e.category, e.level, e.message)
--   end
--   CL:SetChatEchoLevel("WARN")     -- WARN/ERROR also print()
--   CL:Clear()                       -- empty the buffer
--   CL:SetCapacity(2000)             -- ring-buffer size (default 1000)
--
-- Entry shape (read-only convention; do not mutate):
--   { timestamp, source, category, level, message }
--
-- Levels (built-in, ordered by rank):
--   DEBUG (1)  <  INFO (2)  <  WARN (3)  <  ERROR (4)
--   Custom level strings are accepted via :Log(level, ...) — they get rank 0
--   so they never trigger the chat-echo threshold automatically.
--
-- Design notes:
--   - One shared ring buffer for the entire process. Consumers all log into
--     it; Forge_Logs reads from it. This is what makes "Forge_Logs replaces
--     Cairn.Dashboard" work — one place to look.
--   - Ring is fixed size; old entries roll off as new ones arrive. No
--     manual cleanup. Default capacity 1000 entries.
--   - Persistence is out of scope for this lib. The buffer is in-memory and
--     dies on /reload. Wrap with Cairn-DB if you want SavedVariables-backed
--     log history.
--   - Chat echo is opt-in. Default is silent (log-only). Set a threshold
--     level and matching+higher entries also fire `print()` with a colored
--     prefix.
--
-- Public API (lib):
--   CL:New(name)            -> root logger    -- idempotent on `name`
--   CL:Get(name)                              -- registry lookup
--   CL.loggers                                -- { [name] = root logger }
--   CL.entries                                -- the ring buffer (read-only)
--   CL:GetEntries(filter)                     -- {source,category,level,since,limit}
--   CL:Clear()
--   CL:SetChatEchoLevel(level_or_nil)
--   CL:SetCapacity(n)
--   CL.LEVELS                                 -- {DEBUG=1, INFO=2, WARN=3, ERROR=4}
--
-- Public API (instance, both root and sub):
--   log:Debug(fmt, ...)
--   log:Info (fmt, ...)
--   log:Warn (fmt, ...)
--   log:Error(fmt, ...)
--   log:Log(level, fmt, ...)                  -- custom level string
--   log:Category(name) -> sub-logger          -- shares source, fixed category
--
-- License: MIT. Author: ChronicTinkerer.

local LIB_MAJOR = "Cairn-Log"
local LIB_MINOR = 1

local Cairn_Log = LibStub:NewLibrary(LIB_MAJOR, LIB_MINOR)
if not Cairn_Log then return end


-- Preserve state across MINOR upgrades.
Cairn_Log.loggers     = Cairn_Log.loggers     or {}
Cairn_Log.entries     = Cairn_Log.entries     or {}
Cairn_Log._capacity   = Cairn_Log._capacity   or 1000
Cairn_Log._head       = Cairn_Log._head       or 1
Cairn_Log._count      = Cairn_Log._count      or 0
Cairn_Log._echoLevel  = Cairn_Log._echoLevel  -- nil unless SetChatEchoLevel'd

Cairn_Log.LEVELS = Cairn_Log.LEVELS or {
    DEBUG = 1,
    INFO  = 2,
    WARN  = 3,
    ERROR = 4,
}

local LEVEL_COLOR = {
    DEBUG = "|cff888888",
    INFO  = "|cffffffff",
    WARN  = "|cffffaa00",
    ERROR = "|cffff5555",
}


-- ---------------------------------------------------------------------------
-- Internal: ring-buffer push
-- ---------------------------------------------------------------------------

-- Unknown levels get rank 0 so a custom :Log("AUDIT", ...) call doesn't
-- accidentally meet the chat-echo threshold of a known level.
local function rankOf(level)
    return Cairn_Log.LEVELS[level] or 0
end


-- Ring write: a head pointer + count counter, no eviction sweep. New
-- entries overwrite the oldest slot in place once the buffer is full, so
-- sustained logging has steady-state cost (no allocations beyond the entry
-- itself, no GC churn from queue reshuffling).
--
-- Chat echo is inline rather than queued because the threshold check is
-- cheap and queueing would just delay visibility.
local function pushEntry(source, category, level, message)
    local entry = {
        timestamp = (time and time()) or 0,
        source    = source,
        category  = category,
        level     = level,
        message   = message,
    }

    local idx = Cairn_Log._head
    Cairn_Log.entries[idx] = entry

    idx = idx + 1
    if idx > Cairn_Log._capacity then idx = 1 end
    Cairn_Log._head = idx

    if Cairn_Log._count < Cairn_Log._capacity then
        Cairn_Log._count = Cairn_Log._count + 1
    end

    local echo = Cairn_Log._echoLevel
    if echo and rankOf(level) >= rankOf(echo) then
        local color = LEVEL_COLOR[level] or "|cffffffff"
        print(string.format("%s[%s]|r %s%s: %s",
            color, level,
            source,
            category and ("/" .. category) or "",
            message))
    end
end


-- Single-arg call path skips the string.format pass so consumers can log a
-- raw message containing % without escaping (e.g. `log:Info("100% loaded")`).
-- A failing format call is caught and stringified into the message rather
-- than thrown — losing a log line to a bad format string is the WORST
-- possible failure mode for a logging library.
local function formatMessage(fmt, ...)
    if fmt == nil then return "" end
    if select("#", ...) == 0 then
        return tostring(fmt)
    end
    local ok, result = pcall(string.format, fmt, ...)
    if ok then return result end
    return tostring(fmt) .. " [format-error: " .. tostring(result) .. "]"
end


-- ---------------------------------------------------------------------------
-- Logger instance methods (root + sub share the same metatable)
-- ---------------------------------------------------------------------------

local LoggerMethods = {}

local function logAt(self, level, fmt, ...)
    pushEntry(self._source, self._category, level, formatMessage(fmt, ...))
end

function LoggerMethods:Debug(fmt, ...) logAt(self, "DEBUG", fmt, ...) end
function LoggerMethods:Info (fmt, ...) logAt(self, "INFO",  fmt, ...) end
function LoggerMethods:Warn (fmt, ...) logAt(self, "WARN",  fmt, ...) end
function LoggerMethods:Error(fmt, ...) logAt(self, "ERROR", fmt, ...) end

-- Escape hatch for custom level names (e.g. "AUDIT", "TRACE"). Custom levels
-- get rank 0, which means they never satisfy a chat-echo threshold of WARN+
-- — by design, so an experimental level can't accidentally spam chat.
function LoggerMethods:Log(level, fmt, ...)
    if type(level) ~= "string" or level == "" then
        error("Cairn-Log :Log: level must be a non-empty string", 2)
    end
    logAt(self, level, fmt, ...)
end

-- Sub-loggers share the source's identity but tag entries with a category
-- so Forge_Logs can filter. Not registered separately — only the root
-- loggers appear in Cairn_Log.loggers. This keeps the registry view clean
-- (one entry per addon, not one per category).
function LoggerMethods:Category(name)
    if type(name) ~= "string" or name == "" then
        error("Cairn-Log :Category: name must be a non-empty string", 2)
    end
    return setmetatable({
        _source   = self._source,
        _category = name,
    }, getmetatable(self))
end

local LoggerMeta = { __index = LoggerMethods }


-- ---------------------------------------------------------------------------
-- Public API (lib-level)
-- ---------------------------------------------------------------------------

-- Idempotent on `name`. Many addons have multiple .lua files that all want
-- to grab the same logger; each file's :New() returns the same instance
-- without coordination.
function Cairn_Log:New(name)
    if type(name) ~= "string" or name == "" then
        error("Cairn-Log:New: name must be a non-empty string", 2)
    end
    local existing = self.loggers[name]
    if existing then return existing end

    local logger = setmetatable({
        _source   = name,
        _category = nil,
    }, LoggerMeta)

    self.loggers[name] = logger
    return logger
end


function Cairn_Log:Get(name)
    return self.loggers[name]
end


-- Reads the ring buffer in REVERSE write order (newest first) because
-- that's what every consumer of log data actually wants — "show me the
-- recent stuff first". Filter is AND'd across all provided keys.
--
-- `level` filter is rank-based (MINIMUM level), not exact match — so
-- filter.level = "WARN" returns WARN + ERROR. category filter IS exact
-- (nil categories only match a nil category filter, which can't be expressed
-- in the API today; leave the key out to match all categories).
function Cairn_Log:GetEntries(filter)
    filter = filter or {}
    if type(filter) ~= "table" then
        error("Cairn-Log:GetEntries: filter must be a table or nil", 2)
    end

    local results = {}
    local count   = self._count
    if count == 0 then return results end

    local capacity = self._capacity
    local start = self._head - 1
    if start < 1 then start = capacity end

    local limit    = filter.limit or math.huge
    local minRank  = filter.level and rankOf(filter.level) or 0
    local source   = filter.source
    local category = filter.category
    local since    = filter.since
    local hasCatFilter = filter.category ~= nil

    local emitted = 0
    for i = 1, count do
        local idx = start - (i - 1)
        while idx < 1 do idx = idx + capacity end
        local e = self.entries[idx]
        if e then
            local include = true
            if source   and e.source   ~= source   then include = false end
            if hasCatFilter and e.category ~= category then include = false end
            if since    and e.timestamp < since    then include = false end
            if filter.level and rankOf(e.level) < minRank then include = false end

            if include then
                emitted = emitted + 1
                results[emitted] = e
                if emitted >= limit then break end
            end
        end
    end

    return results
end


function Cairn_Log:Clear()
    for i = 1, self._capacity do
        self.entries[i] = nil
    end
    self._head  = 1
    self._count = 0
end


function Cairn_Log:SetChatEchoLevel(level)
    if level ~= nil then
        if type(level) ~= "string" or level == "" then
            error("Cairn-Log:SetChatEchoLevel: level must be a string or nil", 2)
        end
    end
    self._echoLevel = level
end


-- Shrink semantics are crude on purpose: we cap _count and reset _head
-- rather than rebuild the ring to preserve the newest N entries. A
-- consumer shrinking the buffer is making a deliberate "I want a smaller
-- footprint" choice; losing recent history is acceptable. The alternative
-- (preserving the newest entries) would require a full scan + reshuffle on
-- every shrink call, which isn't worth the engineering for this edge case.
function Cairn_Log:SetCapacity(n)
    if type(n) ~= "number" or n < 1 then
        error("Cairn-Log:SetCapacity: capacity must be a positive number", 2)
    end
    n = math.floor(n)
    self._capacity = n
    if self._count > n then self._count = n end
    if self._head  > n then self._head  = 1 end
end


return Cairn_Log
