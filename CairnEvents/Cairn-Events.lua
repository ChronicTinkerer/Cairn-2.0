-- Cairn-Events
-- Event routing through a single internal frame. Handles both WoW events
-- (auto-routed when the frame fires them) AND internal addon-to-addon
-- events (dispatched explicitly via :Fire). Handlers receive the event's
-- payload as positional args (no event-name prefix, no self).
--
-- WoW event:
--
--   local CE = LibStub("Cairn-Events")
--   CE:Subscribe("PLAYER_LOGIN", function() print("hello") end)
--   CE:Subscribe("UNIT_HEALTH", function(unit) print(unit) end)
--
-- Internal addon-to-addon event:
--
--   -- in publisher addon
--   CE:Fire("MyAddon:Ready", playerName, level)
--
--   -- in subscriber addon
--   CE:Subscribe("MyAddon:Ready", function(name, level) ... end)
--
-- Owner-based batch cleanup (useful at addon shutdown):
--
--   local sub = CE:Subscribe("UNIT_HEALTH", onHealth, myAddon)
--   ...
--   CE:UnsubscribeOwner(myAddon)
--
-- Public API:
--   local CE = LibStub("Cairn-Events")
--   CE:Subscribe(event, handler [, owner])  -> subscription
--   CE:Unsubscribe(subscription)
--   CE:UnsubscribeOwner(owner)
--   CE:Fire(event, ...)                     -- trigger subs explicitly
--   CE.handlers   -- { [event] = { sub, sub, ... } }   read-only for introspection
--
-- Handler signature:
--   function handler(...)   -- receives event args, NOT the event name
--
-- Design notes:
--   - One internal frame routes WoW events; lib calls RegisterEvent /
--     UnregisterEvent on it as subscribers come and go. RegisterEvent
--     failures are silent — an unknown event name is assumed to be an
--     internal event that will be triggered via :Fire.
--   - **No namespacing between WoW events and internal events.** They share
--     the same handlers table. Calling Fire("PLAYER_LOGIN") fires subs as
--     if WoW had triggered it. Use namespaced names like "MyAddon:Ready"
--     for internal events to avoid colliding with WoW event names.
--   - **No retro-fire.** If you need "subscribe to PLAYER_LOGIN and fire
--     immediately if it already passed", use Cairn-Addon's OnLogin.
--     Cairn-Events is for ongoing event routing.
--   - **Snapshot-during-dispatch.** Handlers can safely call Subscribe or
--     Unsubscribe during their own fire — we iterate a snapshot of the
--     subscriber list, not the live list. Small GC cost on every fire;
--     correctness > micro-perf.
--   - **Handler errors don't poison dispatch.** Each handler call is pcall'd;
--     errors go through geterrorhandler() (so BugGrabber sees them).
--
-- License: MIT. Author: ChronicTinkerer.

local LIB_MAJOR = "Cairn-Events"
local LIB_MINOR = 1

local Cairn_Events = LibStub:NewLibrary(LIB_MAJOR, LIB_MINOR)
if not Cairn_Events then return end


-- Preserve across MINOR upgrades.
Cairn_Events.handlers = Cairn_Events.handlers or {}


-- ---------------------------------------------------------------------------
-- Internal dispatch frame
-- ---------------------------------------------------------------------------
-- Anonymous CreateFrame is load-bearing: RegisterEvent on a NAMED frame can
-- trip ADDON_ACTION_FORBIDDEN on current Retail (memory:
-- wow_named_frame_register_event.md). Don't name this frame.

local listener = Cairn_Events._listener or CreateFrame("Frame")
Cairn_Events._listener = listener


-- Snapshot-during-dispatch. Real-world handlers DO unsubscribe themselves
-- and peers mid-fire (e.g. a one-shot listener that removes itself in the
-- callback). table.remove during pairs() is undefined behavior; iterating a
-- frozen copy is the cheap correct answer. Cost: one transient array per
-- fire. For frequent events (UNIT_HEALTH, COMBAT_LOG_EVENT_UNFILTERED) this
-- is the dominant overhead — acceptable, optimize only if profiling demands.
local function dispatch(event, ...)
    local subs = Cairn_Events.handlers[event]
    if not subs or #subs == 0 then return end

    local n = #subs
    local snapshot = {}
    for i = 1, n do snapshot[i] = subs[i] end

    for i = 1, n do
        local sub = snapshot[i]
        local ok, err = pcall(sub.handler, ...)
        if not ok then
            geterrorhandler()(("Cairn-Events: handler for %s threw: %s"):format(
                event, tostring(err)))
        end
    end
end

-- Re-attach on every load so MINOR upgrades pick up new closure scope
-- (closes over THIS Cairn_Events table). Safe to re-set unconditionally.
listener:SetScript("OnEvent", function(_, event, ...)
    dispatch(event, ...)
end)


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Subscribe accepts WoW event names AND arbitrary internal event names
-- transparently. WoW's RegisterEvent throws on unknown names — we swallow
-- that and treat the unknown case as "this is an internal event the consumer
-- will trigger via :Fire". This single-API design lets a consumer subscribe
-- to a flavor-specific WoW event without crashing on other flavors, AND it
-- doubles as the addon-to-addon message channel without a separate API.
function Cairn_Events:Subscribe(event, handler, owner)
    if type(event) ~= "string" or event == "" then
        error("Cairn-Events:Subscribe: event must be a non-empty string", 2)
    end
    if type(handler) ~= "function" then
        error("Cairn-Events:Subscribe: handler must be a function", 2)
    end

    local subs = self.handlers[event]
    if not subs then
        subs = {}
        self.handlers[event] = subs
        pcall(listener.RegisterEvent, listener, event)
    end

    local sub = { event = event, handler = handler, owner = owner }
    subs[#subs + 1] = sub
    return sub
end


-- Fire is the manual dispatch path. It works on ANY event name — including
-- real WoW event names, which is occasionally useful in tests but also a
-- footgun (a Fire("PLAYER_LOGIN") notifies our subscribers as if WoW had
-- raised it). Consumers using Fire for addon-to-addon messaging should
-- namespace their events ("MyAddon:Ready") to avoid stepping on WoW's
-- vocabulary.
function Cairn_Events:Fire(event, ...)
    if type(event) ~= "string" or event == "" then
        error("Cairn-Events:Fire: event must be a non-empty string", 2)
    end
    dispatch(event, ...)
end


-- Safe to call from inside a handler — the dispatcher snapshots the sub
-- list, so removal here only affects future fires, not the one in flight.
-- pcall on UnregisterEvent covers the internal-event case where the frame
-- never had this event registered in the first place (RegisterEvent silently
-- failed at Subscribe time).
function Cairn_Events:Unsubscribe(sub)
    if type(sub) ~= "table" or type(sub.event) ~= "string" then
        error("Cairn-Events:Unsubscribe: must pass the subscription returned by :Subscribe", 2)
    end

    local subs = self.handlers[sub.event]
    if not subs then return end

    for i = #subs, 1, -1 do
        if subs[i] == sub then
            table.remove(subs, i)
        end
    end

    if #subs == 0 then
        self.handlers[sub.event] = nil
        pcall(listener.UnregisterEvent, listener, sub.event)
    end
end


-- Owner-keyed batch removal. Designed for addon-shutdown / disable flows
-- where a consumer wants to wipe every subscription it owns without keeping
-- handle references around. Pass the addon table itself (or any consistent
-- token) as `owner` at Subscribe time.
function Cairn_Events:UnsubscribeOwner(owner)
    if owner == nil then
        error("Cairn-Events:UnsubscribeOwner: owner must be non-nil", 2)
    end

    for event, subs in pairs(self.handlers) do
        for i = #subs, 1, -1 do
            if subs[i].owner == owner then
                table.remove(subs, i)
            end
        end
        if #subs == 0 then
            self.handlers[event] = nil
            pcall(listener.UnregisterEvent, listener, event)
        end
    end
end


return Cairn_Events
