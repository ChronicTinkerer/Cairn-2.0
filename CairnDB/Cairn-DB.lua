-- Cairn-DB
-- SavedVariables wrapper with default merging and named profiles.
--
-- The simple case is one line:
--
--   local db = LibStub("Cairn-DB"):New("MyAddonDB", {
--       global  = { sharedKey = 1 },
--       profile = { perProfileKey = "hello" },
--   })
--
--   print(db.global.sharedKey)          --> 1
--   print(db.profile.perProfileKey)     --> "hello"
--
-- The consumer's .toc must declare `## SavedVariables: MyAddonDB` for the
-- table to actually persist between sessions. We can't enforce that from a
-- library, but the lib will still work in-session if it's missing.
--
-- Public API:
--   local Cairn_DB = LibStub("Cairn-DB")
--   local db = Cairn_DB:New(savedVarName, defaults)   -- create instance
--   db.global       -- shared table (data shared across every character)
--   db.profile      -- per-profile table (defaults to profile "Default")
--   db:SetProfile(name)  -- switch profile (creates if missing, applies defaults)
--   db:GetProfile()      -- returns current profile name
--   Cairn_DB:Get(name)   -- returns the registered instance, or nil
--   Cairn_DB.instances   -- { [savedVarName] = db, ... } (for Forge_Registry)
--
-- Design notes:
--   - SavedVariables are loaded BEFORE the consumer's .lua files execute,
--     so there's no "wait for init" timing concern. New() returns a fully
--     usable db.
--   - Defaults merge is non-destructive: keys already present in the saved
--     data are preserved; only missing keys are filled from defaults.
--   - Defaults are NOT retro-applied if the consumer changes the defaults
--     table between sessions — that's an intentional limitation. Use a
--     migration pass in your consumer's OnInit/OnLogin if you need that.
--   - Unknown keys in `defaults` (anything other than `global` or `profile`)
--     raise an error. Catches typos loud rather than silently dropping data.
--   - db.profile is a real field updated by :SetProfile(), NOT a metatable
--     getter. Faster access; the "don't cache db.profile across profile
--     switches" gotcha is small and documented.
--
-- License: MIT. Author: ChronicTinkerer.

local LIB_MAJOR = "Cairn-DB"
local LIB_MINOR = 1

local Cairn_DB = LibStub:NewLibrary(LIB_MAJOR, LIB_MINOR)
if not Cairn_DB then return end


-- Internal state. Preserved across MINOR upgrades (LibStub returns same
-- table on upgrade; `or {}` only initializes once).
Cairn_DB.instances = Cairn_DB.instances or {}


local DEFAULT_PROFILE = "Default"

-- Whitelisted defaults keys. Unknown keys (e.g. typo `defualts.profile`)
-- error loudly at New() rather than silently dropping data. Extending this
-- set is a deliberate API change — don't expand it without a real consumer
-- need.
local ALLOWED_DEFAULT_KEYS = { global = true, profile = true }


-- ---------------------------------------------------------------------------
-- Non-destructive default merge
-- ---------------------------------------------------------------------------

-- Existing saved values always win over defaults. Tables recurse so we
-- don't blow away a nested user setting just because a sibling sub-key got
-- a new default. Called at New() time and again on SetProfile so newly-
-- created profiles inherit the full defaults shape — including any keys
-- added to defaults across versions.
local function mergeDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then
                target[k] = {}
            end
            mergeDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
end


-- ---------------------------------------------------------------------------
-- Instance methods
-- ---------------------------------------------------------------------------

local DBMethods = {}

-- Switching profile is an opt-in via SetProfile rather than a __index getter
-- so `db.profile` stays cheap (direct field, not metatable lookup). The
-- tradeoff: capturing `local p = db.profile` BEFORE a SetProfile call leaves
-- `p` pointing at the OLD profile. Document; don't change.
--
-- We re-run mergeDefaults on every SetProfile (including switching back to
-- a profile that already exists) so a new defaults key added in a future
-- release lands in every profile the consumer touches.
function DBMethods:SetProfile(name)
    if type(name) ~= "string" or name == "" then
        error("Cairn-DB :SetProfile: name must be a non-empty string", 2)
    end

    local sv = rawget(self, "_sv")
    sv.profiles[name] = sv.profiles[name] or {}

    local defs = rawget(self, "_defaults")
    if defs and defs.profile then
        mergeDefaults(sv.profiles[name], defs.profile)
    end

    sv.currentProfile = name
    rawset(self, "profile", sv.profiles[name])
end

function DBMethods:GetProfile()
    return rawget(self, "_sv").currentProfile
end

local DBMeta = { __index = DBMethods }


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Idempotent on name. Two .lua files in the same addon can both call New()
-- without coordinating; both get the same instance back. If they pass
-- different `defaults`, the second call's defaults are silently ignored —
-- consumer is expected to consolidate defaults at one call site.
--
-- Pitfall: the consumer's .toc MUST declare `## SavedVariables: <name>`.
-- Without it the table still works in-session, but nothing persists across
-- reloads. We can't detect this from the lib side; doc it and move on.
function Cairn_DB:New(name, defaults)
    if type(name) ~= "string" or name == "" then
        error("Cairn-DB:New: savedVarName must be a non-empty string", 2)
    end

    local existing = self.instances[name]
    if existing then return existing end

    if defaults ~= nil then
        if type(defaults) ~= "table" then
            error("Cairn-DB:New: defaults must be a table or nil", 2)
        end
        for k in pairs(defaults) do
            if not ALLOWED_DEFAULT_KEYS[k] then
                error(("Cairn-DB:New: unknown defaults key %q (allowed: global, profile)"):format(tostring(k)), 2)
            end
        end
    end

    -- Shape the saved-vars container. The `or {}` chain is doing two jobs:
    -- creating fresh shape on first-ever load, AND tolerating older saves
    -- that may pre-date a structural field (e.g. an early version without
    -- the `profiles` table).
    _G[name] = _G[name] or {}
    local sv = _G[name]
    sv.global         = sv.global         or {}
    sv.profiles       = sv.profiles       or {}
    sv.currentProfile = sv.currentProfile or DEFAULT_PROFILE
    sv.profiles[sv.currentProfile] = sv.profiles[sv.currentProfile] or {}

    if defaults then
        if defaults.global  then mergeDefaults(sv.global,  defaults.global)  end
        if defaults.profile then mergeDefaults(sv.profiles[sv.currentProfile], defaults.profile) end
    end

    -- Build the instance.
    local db = setmetatable({
        _name     = name,
        _defaults = defaults,
        _sv       = sv,
        global    = sv.global,
        profile   = sv.profiles[sv.currentProfile],
    }, DBMeta)

    self.instances[name] = db
    return db
end


-- Cairn_DB:Get(savedVarName)
function Cairn_DB:Get(name)
    return self.instances[name]
end


return Cairn_DB
