-- Cairn-Slash
-- Slash command registry with nested subcommand routing and recursive
-- auto-help.
--
-- Leaf commands:
--   local slash = LibStub("Cairn-Slash"):Register("Forge", "/forge", {
--       aliases = { "/fg" },
--   })
--   slash:Sub("logs", openLogs, "open Forge_Logs")
--
-- Nested subcommands:
--   local dev = slash:Sub("dev", "developer tools")    -- group, no handler
--   dev:Sub("locale", setLocale, "set locale override")
--   dev:Sub("logs",   devLogs,   "open dev logs viewer")
--
-- Root-level fallback (and any node-level fallback):
--   slash:Default(function(msg) print("unknown: " .. msg) end)
--
-- A node can have BOTH a handler and nested subs:
--   local db = slash:Sub("db", showDb, "show DB state")
--   db:Sub("reset", resetDb, "reset to defaults")
--   -- /forge db          -> showDb("")
--   -- /forge db reset    -> resetDb("")
--   -- /forge db zzz      -> showDb("zzz")
--
-- Public API:
--   local CS = LibStub("Cairn-Slash")
--   CS:Register(name, slash, opts)  -> root instance
--   CS:Get(name)                    -- registered lookup
--   CS.registry                     -- { [name] = root instance }
--
-- Instance methods (chainable; available on every node — root and subs):
--   instance:Sub(name, handler, description)   -- leaf:  handler is a function
--   instance:Sub(name, description)            -- group: description is a string
--   instance:Sub(name)                         -- group with no description
--   instance:Default(handler)                  -- set this node's handler
--   instance:GetSubs()                         -- { [name] = sub node }
--
-- Dispatch rules:
--   - Walk the tree as far as msg's leading tokens match nested sub names.
--   - At the deepest matched node, call that node's `_handler` (set via
--     :Sub's handler arg, or :Default on the node itself) with the unmatched
--     remainder of msg as `rest`.
--   - If the matched node has no `_handler`, the auto-help fallback prints
--     every reachable sub from that node as a full slash path.
--
-- Auto-help is recursive: from the matched node, we enumerate ALL descendant
-- subs and print their full slash paths. No way to end up with an incomplete
-- help view because of nested commands hiding behind a group.
--
-- License: MIT. Author: ChronicTinkerer.

local LIB_MAJOR = "Cairn-Slash"
local LIB_MINOR = 2

local Cairn_Slash = LibStub:NewLibrary(LIB_MAJOR, LIB_MINOR)
if not Cairn_Slash then return end


Cairn_Slash.registry = Cairn_Slash.registry or {}


-- ---------------------------------------------------------------------------
-- Node methods (mounted via metatable __index on every node — root + subs)
-- ---------------------------------------------------------------------------

local SlashMethods = {}
local SlashMeta = { __index = SlashMethods }


-- _fullSlash is computed once at construction time so auto-help can emit
-- the full slash path of any node without walking up _parent each time.
-- Worth the duplication: help generation runs on every fallback dispatch.
local function newNode(parent, name, handler, description)
    return setmetatable({
        _name        = name,
        _fullSlash   = parent._fullSlash .. " " .. name,
        _handler     = handler,
        _description = description,
        _subs        = {},
        _parent      = parent,
    }, SlashMeta)
end


-- Overloaded by type of the second arg. The point is that the consumer
-- never has to pick a different method for "leaf" vs "group" — both look
-- the same at the call site, the lib disambiguates internally:
--
--   :Sub("foo", fn, "desc")  -- leaf with handler
--   :Sub("foo", "desc")      -- group, description only
--   :Sub("foo")              -- bare group
--
-- Re-registering an existing name is idempotent and acts as a setter for
-- handler / description if a newer value is supplied. This lets a consumer
-- declare a group first then later attach a handler without API ceremony.
function SlashMethods:Sub(name, handlerOrDescription, description)
    if type(name) ~= "string" or name == "" then
        error("Cairn-Slash :Sub: name must be a non-empty string", 2)
    end

    local handler
    if type(handlerOrDescription) == "function" then
        handler = handlerOrDescription
        -- third arg is description (or nil)
    elseif type(handlerOrDescription) == "string" then
        if description ~= nil then
            error("Cairn-Slash :Sub: cannot pass description twice", 2)
        end
        description = handlerOrDescription
    elseif handlerOrDescription ~= nil then
        error("Cairn-Slash :Sub: second arg must be a function, string, or nil", 2)
    end

    if description ~= nil and type(description) ~= "string" then
        error("Cairn-Slash :Sub: description must be a string", 2)
    end

    local existing = self._subs[name]
    if existing then
        if handler ~= nil then existing._handler = handler end
        if description ~= nil then existing._description = description end
        return existing
    end

    local sub = newNode(self, name, handler, description)
    self._subs[name] = sub
    return sub
end


-- :Default exists so consumers can attach a handler AFTER a group node was
-- already created (e.g. group declared first for sub-tree definition, then
-- behavior added later). It's the same _handler slot that :Sub's function
-- form sets — there's only one handler per node — so this is also the way
-- to "reassign" a handler after the fact.
function SlashMethods:Default(handler)
    if type(handler) ~= "function" then
        error("Cairn-Slash :Default: handler must be a function", 2)
    end
    self._handler = handler
    return self
end


-- Returned table is the LIVE _subs map, not a copy. Consumers walking it
-- mid-modification should snapshot first. Used by Forge_Registry for
-- introspection; mutate at your own risk.
function SlashMethods:GetSubs()
    return self._subs
end


-- ---------------------------------------------------------------------------
-- Dispatch + auto-help
-- ---------------------------------------------------------------------------

-- Recursive walk. The auto-help requirement is "show EVERY reachable sub,
-- not just the immediate level" so consumers don't get a misleading partial
-- view when a sub-tree exists.
local function collectPaths(node, lines)
    for _, sub in pairs(node._subs) do
        lines[#lines + 1] = { path = sub._fullSlash, description = sub._description }
        collectPaths(sub, lines)
    end
end


-- pairs() iteration order is undefined; sort the collected paths so a user
-- running /forge twice gets the same help layout both times. Alignment via
-- maxLen pad keeps descriptions visually columned regardless of path length.
local function printHelp(node)
    local lines = {}
    collectPaths(node, lines)
    table.sort(lines, function(a, b) return a.path < b.path end)

    print(("|cffffaa00%s|r commands:"):format(node._fullSlash))
    if #lines == 0 then
        print("  (no subcommands registered)")
        return
    end

    -- Align descriptions on the longest path
    local maxLen = 0
    for _, line in ipairs(lines) do
        if #line.path > maxLen then maxLen = #line.path end
    end
    local fmt = "  %-" .. maxLen .. "s  %s"
    for _, line in ipairs(lines) do
        if line.description then
            print(fmt:format(line.path, line.description))
        else
            print("  " .. line.path)
        end
    end
end


-- dispatch(node, msg)
-- Walks as deep as tokens match, calls deepest matched node's handler with
-- the unmatched remainder. Three notable behaviors:
--
--   1. /forge dev locale enUS   → matches "dev" then "locale"; locale's
--      handler gets "enUS" as msg
--   2. /forge dev zzz            → matches "dev"; "zzz" doesn't match any
--      of dev's subs, so dev's handler gets "zzz" as msg
--   3. /forge dev (no rest)      → matches "dev"; if dev has a handler it
--      gets "" as msg, else auto-help fires for dev's subtree
--
-- The pcall around the handler call is the standard "one bad consumer
-- shouldn't break the slash UI" pattern.
local function dispatch(node, msg)
    msg = msg or ""

    local subName, rest = msg:match("^(%S+)%s*(.*)$")
    if subName and node._subs[subName] then
        return dispatch(node._subs[subName], rest or "")
    end

    if node._handler then
        local ok, err = pcall(node._handler, msg)
        if not ok then
            geterrorhandler()(("Cairn-Slash: %s handler threw: %s"):format(
                node._fullSlash, tostring(err)))
        end
        return
    end

    printHelp(node)
end


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Register is the only entry-point onto the lib; everything else hangs off
-- the returned root node via chained :Sub/:Default calls. Aliases route
-- to the same dispatcher, so /forge and /fg are indistinguishable from the
-- user's perspective. The CAIRN_SLASH_ prefix on the SLASH_/SlashCmdList
-- keys is what keeps multiple consumers' slash commands from colliding in
-- WoW's global slash registry.
function Cairn_Slash:Register(name, slashStr, opts)
    if type(name) ~= "string" or name == "" then
        error("Cairn-Slash:Register: name must be a non-empty string", 2)
    end
    if type(slashStr) ~= "string" or not slashStr:match("^/") then
        error("Cairn-Slash:Register: slash must be a string starting with '/'", 2)
    end
    if opts ~= nil and type(opts) ~= "table" then
        error("Cairn-Slash:Register: opts must be a table or nil", 2)
    end

    local existing = self.registry[name]
    if existing then return existing end

    local aliases = opts and opts.aliases or {}
    if type(aliases) ~= "table" then
        error("Cairn-Slash:Register: opts.aliases must be a list of strings", 2)
    end
    for i, alias in ipairs(aliases) do
        if type(alias) ~= "string" or not alias:match("^/") then
            error(("Cairn-Slash:Register: alias #%d must be a string starting with '/'"):format(i), 2)
        end
    end

    local root = setmetatable({
        _name      = name,
        _fullSlash = slashStr,
        _aliases   = aliases,
        _handler   = nil,
        _subs      = {},
        _parent    = nil,
    }, SlashMeta)

    local key = "CAIRN_SLASH_" .. name:upper()
    _G["SLASH_" .. key .. "1"] = slashStr
    for i, alias in ipairs(aliases) do
        _G["SLASH_" .. key .. (i + 1)] = alias
    end
    _G.SlashCmdList[key] = function(msg) dispatch(root, msg) end

    self.registry[name] = root
    return root
end


-- Cairn_Slash:Get(name)
function Cairn_Slash:Get(name)
    return self.registry[name]
end


return Cairn_Slash
