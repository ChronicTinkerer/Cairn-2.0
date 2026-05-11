-- Cairn-Addon
-- Addon lifecycle wrapper. Gives every consumer the same three hooks:
-- OnInit (ADDON_LOADED for the consumer's own addon), OnLogin (PLAYER_LOGIN),
-- and OnDisable (PLAYER_LOGOUT, best-effort).
--
-- The defining feature is **retro-fire**: if a consumer assigns OnInit or
-- OnLogin after the matching event has already passed, the handler fires
-- immediately. This is the main pain point in the current Cairn-Addon-1.0:
-- load-on-demand addons that registered late had their OnLogin never fire,
-- which silently broke every consumer that did setup work there.
--
-- Public API:
--   local Cairn_Addon = LibStub("Cairn-Addon")
--   local addon = Cairn_Addon:New("MyAddon")
--   function addon:OnInit()    end   -- runs on or after ADDON_LOADED for "MyAddon"
--   function addon:OnLogin()   end   -- runs on or after PLAYER_LOGIN
--   function addon:OnDisable() end   -- runs on PLAYER_LOGOUT (best-effort)
--
-- Introspection (used by Forge_Registry):
--   Cairn_Addon.registry    -- table {[name] = instance, ...}
--   Cairn_Addon:Get(name)   -- returns the instance for name, or nil
--
-- Guarantees:
--   - OnInit always fires before OnLogin for a given addon.
--   - Each handler fires at most once per session.
--   - New() is idempotent: same name returns the same instance.
--   - Handler errors are caught (geterrorhandler()) so one bad handler
--     doesn't break dispatch for the rest.
--
-- License: MIT. Author: ChronicTinkerer.

local LIB_MAJOR = "Cairn-Addon"
local LIB_MINOR = 1

local Cairn_Addon = LibStub:NewLibrary(LIB_MAJOR, LIB_MINOR)
if not Cairn_Addon then return end  -- already loaded at this MINOR or newer


-- Internal state. Preserved across MINOR upgrades because LibStub returns
-- the same table on upgrade and `or {}` only initializes once.
Cairn_Addon.registry      = Cairn_Addon.registry      or {}
Cairn_Addon._loginFired   = Cairn_Addon._loginFired   or false


-- C_AddOns.IsAddOnLoaded landed on Retail; bare-global IsAddOnLoaded still
-- exists on Classic flavors. Bind once so call sites don't branch.
local IsLoaded =
    (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded


-- ---------------------------------------------------------------------------
-- Dispatch primitives
-- ---------------------------------------------------------------------------

-- One bad consumer handler must not break dispatch for the rest. pcall the
-- call and route any throw through geterrorhandler so BugGrabber and friends
-- still surface it.
local function safeCall(addon, key)
    local handler = rawget(addon, key)
    if type(handler) ~= "function" then return end
    local ok, err = pcall(handler, addon)
    if not ok then
        geterrorhandler()(("Cairn-Addon: %s:%s threw: %s"):format(
            rawget(addon, "_name") or "<unknown>", key, tostring(err)))
    end
end


-- Idempotent OnInit dispatch. _initFired is the latch — once set, repeated
-- calls (e.g. from late metatable retro-fire OR the event listener) are
-- no-ops. The contract is "at most once per session per addon".
local function fireInit(addon)
    if rawget(addon, "_initFired") then return end
    rawset(addon, "_initFired", true)
    safeCall(addon, "OnInit")
end


-- Same idempotent latch as fireInit, plus an explicit OnInit-first ordering
-- so OnLogin handlers can assume their addon's init code has completed even
-- if assignment order was Login-then-Init at the consumer site.
local function fireLogin(addon)
    if rawget(addon, "_loginFired") then return end
    rawset(addon, "_loginFired", true)
    fireInit(addon)
    safeCall(addon, "OnLogin")
end


-- ---------------------------------------------------------------------------
-- Per-instance metatable — the retro-fire mechanism
-- ---------------------------------------------------------------------------

-- The defining trick: __newindex on first assignment of OnInit / OnLogin
-- checks whether the matching event already happened, and if so fires the
-- handler synchronously. After the first write the key lives on the instance
-- directly, so subsequent writes bypass the metatable (Lua semantics) and
-- can't re-fire — exactly the desired "at most once" behavior.
--
-- OnDisable intentionally has no retro-fire path: PLAYER_LOGOUT is a
-- terminal event we can't replay.
local AddonMeta = {
    __newindex = function(addon, key, value)
        rawset(addon, key, value)

        if key == "OnInit" then
            -- _initSeen tracks "ADDON_LOADED for this addon has been observed"
            -- (set by the event listener) OR "we detected it as already-loaded
            -- at New() via the IsLoaded probe". Either path means OnInit
            -- assignment is late and the handler should fire now.
            if rawget(addon, "_initSeen") then
                fireInit(addon)
            end
        elseif key == "OnLogin" then
            if Cairn_Addon._loginFired then
                fireLogin(addon)
            end
        end
    end,
}


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Idempotent on `name` so the addon's main file can call New() unconditionally
-- without worrying about whether an earlier load already created the instance
-- (relevant for /reload paths and dev workflows that re-source files).
--
-- The IsLoaded probe at the end matters for one specific case: Cairn-Addon
-- itself loaded AFTER the consumer's ADDON_LOADED already fired. Without it,
-- the consumer's OnInit handler assignment would have no retro-fire trigger
-- and the handler would never run.
function Cairn_Addon:New(name)
    if type(name) ~= "string" or name == "" then
        error("Cairn-Addon:New: name must be a non-empty string", 2)
    end

    local existing = self.registry[name]
    if existing then return existing end

    local addon = setmetatable({ _name = name }, AddonMeta)
    self.registry[name] = addon

    if IsLoaded and IsLoaded(name) then
        rawset(addon, "_initSeen", true)
    end

    return addon
end


function Cairn_Addon:Get(name)
    return self.registry[name]
end


-- ---------------------------------------------------------------------------
-- Event listener
-- ---------------------------------------------------------------------------
-- One frame, three Blizzard events, fanned out to per-addon handlers.
--
-- Anonymous CreateFrame is load-bearing: RegisterEvent on a NAMED frame can
-- trip ADDON_ACTION_FORBIDDEN on current Retail (memory:
-- wow_named_frame_register_event.md). Don't name this frame.

local listener = Cairn_Addon._listener or CreateFrame("Frame")
Cairn_Addon._listener = listener
listener:UnregisterAllEvents()  -- safe on MINOR upgrades; we re-register below
listener:RegisterEvent("ADDON_LOADED")
listener:RegisterEvent("PLAYER_LOGIN")
listener:RegisterEvent("PLAYER_LOGOUT")
listener:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        local addon = Cairn_Addon.registry[arg1]
        if addon then
            rawset(addon, "_initSeen", true)
            fireInit(addon)
        end
    elseif event == "PLAYER_LOGIN" then
        Cairn_Addon._loginFired = true
        for _, addon in pairs(Cairn_Addon.registry) do
            fireLogin(addon)
        end
    elseif event == "PLAYER_LOGOUT" then
        for _, addon in pairs(Cairn_Addon.registry) do
            safeCall(addon, "OnDisable")
        end
    end
end)


return Cairn_Addon
