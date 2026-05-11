-- Cairn-Callback
-- CallbackHandler-1.0 compatibility shim. Registers under both Cairn-Callback
-- AND CallbackHandler-1.0 LibStub MAJORs so any existing addon (ElvUI,
-- LibActionButton, LibSharedMedia, HereBeDragons, AceEvent consumers, etc.)
-- that does LibStub("CallbackHandler-1.0") gets a working implementation.
--
--   local CC = LibStub("Cairn-Callback")    -- or LibStub("CallbackHandler-1.0")
--   local cb = CC:New(myLib)
--
--   -- Consumer registers callbacks (myLib is the target of :New)
--   myLib.RegisterCallback(consumer, "MyLib_SomeEvent", "OnSomeEvent")
--   myLib.RegisterCallback(consumer, "MyLib_SomeEvent", function(event, ...) end)
--   myLib.RegisterCallback(consumer, "MyLib_SomeEvent", fnOrMethod, "myarg")
--
--   -- Library fires
--   cb:Fire("MyLib_SomeEvent", arg1, arg2)
--
-- Dispatch routes (matches upstream CallbackHandler-1.0 exactly):
--   - Function:          fn(eventName, ...)
--   - Method string:     consumer:Method(eventName, ...)
--   - With arg (fn):     fn(arg, eventName, ...)
--   - With arg (method): consumer:Method(arg, eventName, ...)
--
-- Public API:
--   CC:New(target [, registerName, unregisterName, unregisterAllName, OnUsed, OnUnused])
--     Installs on target:
--       target[registerName]      (default "RegisterCallback")
--       target[unregisterName]    (default "UnregisterCallback")
--       target[unregisterAllName] (default "UnregisterAllCallbacks")
--     Returns: registry object with :Fire(eventName, ...)
--
--   OnUsed(target, eventName)   -- optional; fires when an event gets its first sub
--   OnUnused(target, eventName) -- optional; fires when an event's last sub leaves
--
--   CC.instances   -- { [target] = registry }  for Forge_Registry introspection
--
-- Compatibility notes:
--   - Registered under CallbackHandler-1.0 at MINOR=1 so any other shim or
--     upstream copy with a higher MINOR replaces us. Per memory
--     `cairn_callbackhandler_shim_breaks_elvui.md`, dropping our MINOR to 1
--     is what fixes the ElvUI unitframe-init race.
--   - Snapshot-during-Fire so consumers can safely Unregister themselves
--     (or peers) from inside a callback without confusing the iterator.
--   - Callback errors are pcall-isolated and routed to geterrorhandler.
--
-- License: MIT. Author: ChronicTinkerer.

local LIB_MAJOR = "Cairn-Callback"
local LIB_MINOR = 1

local Cairn_Callback = LibStub:NewLibrary(LIB_MAJOR, LIB_MINOR)
if not Cairn_Callback then return end


-- Preserved across MINOR upgrades.
Cairn_Callback.instances = Cairn_Callback.instances or {}


-- ---------------------------------------------------------------------------
-- Registry instance methods
-- ---------------------------------------------------------------------------

local RegistryMethods = {}

-- Fire is the hot path. Three subscriber shapes are possible (function /
-- method-string / {handler, arg} table) and we have to dispatch each with
-- the correct calling convention to match upstream CallbackHandler-1.0
-- exactly — third-party libs (ElvUI, LibActionButton, AceComm consumers)
-- depend on it. Get this wrong and unitframes break.
--
-- Snapshot-during-fire mirrors the same pattern in Cairn-Events: real-
-- world callbacks register/unregister themselves and peers mid-fire, and
-- iterating the live table during mutation is undefined behavior.
function RegistryMethods:Fire(eventName, ...)
    if type(eventName) ~= "string" then
        error("Cairn-Callback registry :Fire: eventName must be a string", 2)
    end
    local handlers = self._events[eventName]
    if not handlers then return end

    local consumers, entries = {}, {}
    local n = 0
    for consumer, entry in pairs(handlers) do
        n = n + 1
        consumers[n] = consumer
        entries[n] = entry
    end

    for i = 1, n do
        local consumer = consumers[i]
        local entry    = entries[i]
        local kind     = type(entry)

        -- Function form: fn(eventName, ...)
        if kind == "function" then
            local ok, err = pcall(entry, eventName, ...)
            if not ok then
                geterrorhandler()(("Cairn-Callback: %s handler threw: %s"):format(eventName, tostring(err)))
            end

        -- Method-string form: consumer:method(eventName, ...)
        elseif kind == "string" then
            local m = consumer[entry]
            if type(m) == "function" then
                local ok, err = pcall(m, consumer, eventName, ...)
                if not ok then
                    geterrorhandler()(("Cairn-Callback: %s handler threw: %s"):format(eventName, tostring(err)))
                end
            end

        -- With-arg form: arg goes BEFORE eventName in the dispatch.
        -- Upstream convention — don't swap the order.
        elseif kind == "table" then
            local fn  = entry[1]
            local arg = entry[2]
            if type(fn) == "function" then
                local ok, err = pcall(fn, arg, eventName, ...)
                if not ok then
                    geterrorhandler()(("Cairn-Callback: %s handler threw: %s"):format(eventName, tostring(err)))
                end
            else
                local m = consumer[fn]
                if type(m) == "function" then
                    local ok, err = pcall(m, consumer, arg, eventName, ...)
                    if not ok then
                        geterrorhandler()(("Cairn-Callback: %s handler threw: %s"):format(eventName, tostring(err)))
                    end
                end
            end
        end
    end
end

local RegistryMeta = { __index = RegistryMethods }


-- ---------------------------------------------------------------------------
-- Internal: registry creation
-- ---------------------------------------------------------------------------
-- Lives as a free function (not a method) so the CallbackHandler-1.0 shim
-- can call it without caring about its own `self`. Cairn-Callback:New is a
-- one-liner that delegates here; the shim's :New does the same. Identical
-- behavior, no duplication.

local function makeRegistry(target, regName, unregName, unregAllName, onUsed, onUnused)
    if type(target) ~= "table" then
        error("Cairn-Callback:New: target must be a table", 3)
    end
    regName      = regName      or "RegisterCallback"
    unregName    = unregName    or "UnregisterCallback"
    unregAllName = unregAllName or "UnregisterAllCallbacks"

    local registry = setmetatable({
        _target   = target,
        _events   = {},
        _onUsed   = onUsed,
        _onUnused = onUnused,
    }, RegistryMeta)


    target[regName] = function(consumer, eventName, methodOrFn, arg)
        if type(consumer) ~= "table" then
            error(regName .. ": consumer must be a table", 2)
        end
        if type(eventName) ~= "string" or eventName == "" then
            error(regName .. ": eventName must be a non-empty string", 2)
        end
        if methodOrFn == nil then
            error(regName .. ": method-name string or callback function required", 2)
        end
        local moKind = type(methodOrFn)
        if moKind ~= "function" and moKind ~= "string" then
            error(regName .. ": handler must be a function or method-name string", 2)
        end

        local handlers = registry._events[eventName]
        local wasEmpty = handlers == nil
        if not handlers then
            handlers = {}
            registry._events[eventName] = handlers
        end

        if arg ~= nil then
            handlers[consumer] = { methodOrFn, arg }
        else
            handlers[consumer] = methodOrFn
        end

        if wasEmpty and onUsed then
            local ok, err = pcall(onUsed, target, eventName)
            if not ok then
                geterrorhandler()(("Cairn-Callback: OnUsed threw: %s"):format(tostring(err)))
            end
        end
    end


    target[unregName] = function(consumer, eventName)
        if type(consumer) ~= "table" then
            error(unregName .. ": consumer must be a table", 2)
        end
        if type(eventName) ~= "string" then
            error(unregName .. ": eventName must be a string", 2)
        end
        local handlers = registry._events[eventName]
        if not handlers then return end
        if handlers[consumer] == nil then return end
        handlers[consumer] = nil
        if next(handlers) == nil then
            registry._events[eventName] = nil
            if onUnused then
                local ok, err = pcall(onUnused, target, eventName)
                if not ok then
                    geterrorhandler()(("Cairn-Callback: OnUnused threw: %s"):format(tostring(err)))
                end
            end
        end
    end


    target[unregAllName] = function(consumer)
        if type(consumer) ~= "table" then
            error(unregAllName .. ": consumer must be a table", 2)
        end
        for eventName, handlers in pairs(registry._events) do
            if handlers[consumer] then
                handlers[consumer] = nil
                if next(handlers) == nil then
                    registry._events[eventName] = nil
                    if onUnused then
                        local ok, err = pcall(onUnused, target, eventName)
                        if not ok then
                            geterrorhandler()(("Cairn-Callback: OnUnused threw: %s"):format(tostring(err)))
                        end
                    end
                end
            end
        end
    end


    Cairn_Callback.instances[target] = registry
    return registry
end


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function Cairn_Callback:New(target, regName, unregName, unregAllName, onUsed, onUnused)
    return makeRegistry(target, regName, unregName, unregAllName, onUsed, onUnused)
end


-- ---------------------------------------------------------------------------
-- CallbackHandler-1.0 compatibility shim
-- ---------------------------------------------------------------------------
-- MINOR=1 means we LOSE to any other CallbackHandler-1.0 registration with
-- a higher MINOR. We provide a working fallback when nothing else has
-- registered yet (e.g. consumer addon load before ElvUI's bundled copy).
--
-- Per memory `cairn_callbackhandler_shim_breaks_elvui.md`: NEVER use a high
-- MINOR here. ElvUI's unitframe init races if our shim wins.

do
    local shim = LibStub:NewLibrary("CallbackHandler-1.0", 1)
    if shim then
        function shim:New(target, regName, unregName, unregAllName, onUsed, onUnused)
            return makeRegistry(target, regName, unregName, unregAllName, onUsed, onUnused)
        end
    end
end


return Cairn_Callback
