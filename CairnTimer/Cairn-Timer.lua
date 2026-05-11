-- Cairn-Timer
-- Timing primitives: one-shot delays, repeating intervals, debounce, and a
-- stopwatch. All built on C_Timer (and GetTime for the stopwatch). Timer
-- handles support ownership tracking so consumers can batch-cancel.
--
--   local CT = LibStub("Cairn-Timer")
--
--   CT:After(5, Cleanup)                          -- one-shot
--   CT:Every(1, Update, { owner = MyAddon })      -- repeats forever
--   CT:Every(1, Update, { count = 5 })            -- repeats exactly 5x
--   CT:Debounce("refresh", 0.2, Render)           -- collapse rapid calls
--
--   local sw = CT:Stopwatch()                     -- starts immediately
--   sw:Read()                                      -- elapsed seconds (still running)
--   sw:Lap("phase1")                               -- named checkpoint
--   sw:Stop()                                      -- stop + return final
--   sw:Laps()                                      -- { [name] = elapsed }
--   sw:Reset()                                     -- restart from zero
--
--   CT:CancelOwner(MyAddon)                       -- batch-cancel all timers
--                                                  -- tagged with MyAddon
--
-- Public API (lib):
--   CT:After    (delay, fn [, opts])  -> handle    -- opts: owner
--   CT:Every    (delay, fn [, opts])  -> handle    -- opts: owner, count
--   CT:Debounce (key, delay, fn [, opts]) -> handle -- opts: owner
--   CT:Stopwatch()                    -> stopwatch
--   CT:CancelOwner(owner)
--   CT.timers       -- flat array of active After/Every/Debounce handles
--   CT.byOwner      -- { [owner] = { handle, handle, ... } }
--
-- Public API (timer handle):
--   handle:Cancel()
--   handle:IsCancelled()                          -> boolean
--   handle.delay, handle.fn, handle.owner, handle.repeating,
--   handle.count, handle.fired                    (read-only fields)
--
-- Public API (stopwatch):
--   sw:Read()                                     -> seconds since start
--   sw:Lap([name])                                -- record checkpoint
--   sw:Laps()                                     -> { [name] = elapsed }
--   sw:Stop()                                     -> final elapsed (stops the watch)
--   sw:Reset()                                    -- start over
--   sw:IsStopped()                                -> boolean
--
-- Semantics:
--   - After: one-shot. After firing OR after Cancel, the handle is untracked.
--   - Every: repeating. With opts.count it auto-cancels after N fires. Without,
--     it runs until cancelled. There's no consumer-side forward-reference
--     dance; the lib handles the bookkeeping.
--   - Debounce: rapid calls with the same key cancel any pending timer and
--     schedule a fresh one. Only the FINAL call (after `delay` of quiet)
--     fires `fn`. The key identifies the debounce slot — choose a stable
--     string per logical "thing to debounce" (e.g. "MyAddon:RefreshBars").
--   - Errors in callbacks are pcall-isolated and routed to geterrorhandler().
--     A throwing Every tick does NOT stop subsequent ticks.
--   - Cancel is idempotent.
--
-- License: MIT. Author: ChronicTinkerer.

local LIB_MAJOR = "Cairn-Timer"
local LIB_MINOR = 1

local Cairn_Timer = LibStub:NewLibrary(LIB_MAJOR, LIB_MINOR)
if not Cairn_Timer then return end


Cairn_Timer.timers     = Cairn_Timer.timers     or {}
Cairn_Timer.byOwner    = Cairn_Timer.byOwner    or {}
Cairn_Timer._debounces = Cairn_Timer._debounces or {}  -- {[key] = handle}


-- ---------------------------------------------------------------------------
-- Internal: tracking
-- ---------------------------------------------------------------------------

local function track(handle)
    local self = Cairn_Timer
    self.timers[#self.timers + 1] = handle

    local owner = handle.owner
    if owner ~= nil then
        local bucket = self.byOwner[owner]
        if not bucket then
            bucket = {}
            self.byOwner[owner] = bucket
        end
        bucket[#bucket + 1] = handle
    end
end


-- Three structures track each timer: the flat .timers list (introspection),
-- the per-owner bucket (batch cancel), and the _debounces key-map (only for
-- Debounce timers). Untrack has to clean all three or we'll either keep
-- references that prevent GC, leak owner buckets, or leave a stale debounce
-- entry that breaks subsequent Debounce calls with the same key.
local function untrack(handle)
    local self = Cairn_Timer

    for i = #self.timers, 1, -1 do
        if self.timers[i] == handle then
            table.remove(self.timers, i)
        end
    end

    local owner = handle.owner
    if owner ~= nil then
        local bucket = self.byOwner[owner]
        if bucket then
            for i = #bucket, 1, -1 do
                if bucket[i] == handle then
                    table.remove(bucket, i)
                end
            end
            if #bucket == 0 then
                self.byOwner[owner] = nil
            end
        end
    end

    -- Only clear _debounces[key] if the active entry there is US — a newer
    -- Debounce call with the same key may have already replaced this entry.
    if handle.debounceKey and self._debounces[handle.debounceKey] == handle then
        self._debounces[handle.debounceKey] = nil
    end
end


-- ---------------------------------------------------------------------------
-- Internal: handle methods (shared metatable)
-- ---------------------------------------------------------------------------

local HandleMethods = {}

function HandleMethods:Cancel()
    if self.cancelled then return end
    self.cancelled = true
    untrack(self)
end

function HandleMethods:IsCancelled()
    return self.cancelled == true
end

local HandleMeta = { __index = HandleMethods }


-- ---------------------------------------------------------------------------
-- Internal: tick scheduling
-- ---------------------------------------------------------------------------

local function safeCall(handle)
    local ok, err = pcall(handle.fn)
    if not ok then
        geterrorhandler()(("Cairn-Timer: callback threw: %s"):format(tostring(err)))
    end
end


local scheduleTick   -- forward declaration


-- Both fire paths check `cancelled` BEFORE invoking the callback because
-- C_Timer.After can't be cancelled at the Blizzard level — a callback we
-- scheduled before :Cancel was called will still fire. The pre-check is
-- what makes Cancel actually stop pending ticks.
--
-- They also re-check `cancelled` AFTER the callback. Why: the callback
-- itself might have called handle:Cancel() (e.g. a custom self-terminating
-- loop), in which case we must NOT mark cancelled or reschedule.
local function fireOnce(handle)
    if handle.cancelled then return end
    safeCall(handle)
    handle.fired = (handle.fired or 0) + 1
    if not handle.cancelled then
        handle.cancelled = true
        untrack(handle)
    end
end


-- Auto-cancel at count is the "consumer doesn't have to write the counter"
-- payoff. Without it the consumer would need a closure-captured forward
-- reference to call self:Cancel() — that pattern was rejected explicitly
-- in the design review (memory: cairn_simplicity_applies_to_consumer.md).
local function fireRepeating(handle)
    if handle.cancelled then return end
    safeCall(handle)
    handle.fired = (handle.fired or 0) + 1

    if handle.count and handle.fired >= handle.count then
        if not handle.cancelled then
            handle.cancelled = true
            untrack(handle)
        end
        return
    end

    if not handle.cancelled then
        scheduleTick(handle)
    end
end


scheduleTick = function(handle)
    C_Timer.After(handle.delay, function()
        if handle.repeating then
            fireRepeating(handle)
        else
            fireOnce(handle)
        end
    end)
end


-- ---------------------------------------------------------------------------
-- Internal: validation
-- ---------------------------------------------------------------------------

local function validateOpts(opts, methodLabel, allowCount)
    if opts == nil then return nil, nil end
    if type(opts) ~= "table" then
        error(("Cairn-Timer:%s: opts must be a table or nil"):format(methodLabel), 3)
    end
    if opts.count ~= nil then
        if not allowCount then
            error(("Cairn-Timer:%s: opts.count is only valid on :Every"):format(methodLabel), 3)
        end
        if type(opts.count) ~= "number" or opts.count < 1 or opts.count ~= math.floor(opts.count) then
            error(("Cairn-Timer:%s: opts.count must be a positive integer"):format(methodLabel), 3)
        end
    end
    return opts.owner, opts.count
end


local function newHandle(delay, fn, opts, repeating, methodLabel, debounceKey)
    if type(delay) ~= "number" or delay < 0 then
        error(("Cairn-Timer:%s: delay must be a non-negative number"):format(methodLabel), 3)
    end
    if type(fn) ~= "function" then
        error(("Cairn-Timer:%s: fn must be a function"):format(methodLabel), 3)
    end

    local owner, count = validateOpts(opts, methodLabel, repeating)

    local handle = setmetatable({
        delay        = delay,
        fn           = fn,
        owner        = owner,
        repeating    = repeating,
        count        = count,
        fired        = 0,
        cancelled    = false,
        debounceKey  = debounceKey,   -- nil for After/Every; set for Debounce
    }, HandleMeta)

    track(handle)
    scheduleTick(handle)
    return handle
end


-- ---------------------------------------------------------------------------
-- Public API: timing primitives
-- ---------------------------------------------------------------------------

function Cairn_Timer:After(delay, fn, opts)
    return newHandle(delay, fn, opts, false, "After", nil)
end


function Cairn_Timer:Every(delay, fn, opts)
    return newHandle(delay, fn, opts, true, "Every", nil)
end


-- Each call cancels the pending timer for this key and schedules a fresh
-- one. The "fire X seconds after the LAST call" semantics emerge from this
-- naturally: a burst of N calls leaves only the final timer alive, the
-- prior N-1 having been replaced before they could fire.
--
-- Choose stable keys per logical "thing to debounce" (e.g.
-- "MyAddon:RefreshBars"). Using consumer-supplied keys instead of
-- generated tokens keeps the API one-arg simple at the call site.
function Cairn_Timer:Debounce(key, delay, fn, opts)
    if type(key) ~= "string" or key == "" then
        error("Cairn-Timer:Debounce: key must be a non-empty string", 2)
    end
    local existing = self._debounces[key]
    if existing and not existing.cancelled then
        existing:Cancel()
    end
    local handle = newHandle(delay, fn, opts, false, "Debounce", key)
    self._debounces[key] = handle
    return handle
end


-- Snapshot first because :Cancel mutates the bucket (via untrack), which
-- we'd be iterating. Same defensive pattern as Cairn-Events / Cairn-Hooks.
function Cairn_Timer:CancelOwner(owner)
    if owner == nil then
        error("Cairn-Timer:CancelOwner: owner must be non-nil", 2)
    end
    local bucket = self.byOwner[owner]
    if not bucket then return end
    local copy = {}
    for i = 1, #bucket do copy[i] = bucket[i] end
    for _, h in ipairs(copy) do h:Cancel() end
end


-- ---------------------------------------------------------------------------
-- Public API: stopwatch
-- ---------------------------------------------------------------------------

local StopwatchMethods = {}

function StopwatchMethods:Read()
    if self._stopped then
        return self._stopTime - self._startTime
    end
    return GetTime() - self._startTime
end

function StopwatchMethods:Lap(name)
    if name ~= nil and type(name) ~= "string" then
        error("Cairn-Timer Stopwatch :Lap: name must be a string or nil", 2)
    end
    local key = name or (#self._lapsOrdered + 1)
    local elapsed = self:Read()
    self._laps[key] = elapsed
    self._lapsOrdered[#self._lapsOrdered + 1] = { name = key, elapsed = elapsed }
    return elapsed
end

function StopwatchMethods:Laps()
    -- Return a shallow copy so the consumer can't mutate our internal table
    local copy = {}
    for k, v in pairs(self._laps) do copy[k] = v end
    return copy
end

function StopwatchMethods:Stop()
    if not self._stopped then
        self._stopped = true
        self._stopTime = GetTime()
    end
    return self._stopTime - self._startTime
end

function StopwatchMethods:Reset()
    self._startTime   = GetTime()
    self._stopped     = false
    self._stopTime    = nil
    self._laps        = {}
    self._lapsOrdered = {}
end

function StopwatchMethods:IsStopped()
    return self._stopped == true
end

local StopwatchMeta = { __index = StopwatchMethods }


function Cairn_Timer:Stopwatch()
    return setmetatable({
        _startTime   = GetTime(),
        _stopped     = false,
        _stopTime    = nil,
        _laps        = {},
        _lapsOrdered = {},
    }, StopwatchMeta)
end


return Cairn_Timer
