-- Cairn-Hooks
-- Pre/Post/Wrap hook helpers for instrumenting addon functions. Useful for
-- dev tools (Forge_Inspector, Forge_BugCatcher) and addons that need to
-- observe or transform calls into other addons' APIs.
--
--   local CH = LibStub("Cairn-Hooks")
--
--   -- Post: my fn runs AFTER the original; original's return values pass through.
--   local h = CH:Post(MyAddon, "ProcessQueue", function(self, item)
--       print("processed", item)
--   end)
--
--   -- Pre: my fn runs BEFORE the original; return value is ignored.
--   CH:Pre(MyAddon, "Login", function() print("about to login") end)
--
--   -- Wrap: my fn REPLACES the original; the original is passed as the
--   --       first arg so the consumer chooses whether/when to call it.
--   CH:Wrap(MyAddon, "Save", function(orig, self, ...)
--       print("intercepted save")
--       return orig(self, ...)   -- call through (or don't)
--   end)
--
--   CH:Unhook(h)             -- remove one hook
--   CH:UnhookOwner(owner)    -- batch remove all hooks tagged with `owner`
--
-- Hook handle is opaque — pass it back to :Unhook. Owner is any value
-- (typically your addon table) used as a key for batch removal.
--
-- Public API:
--   CH:Pre (target, methodName, fn [, owner]) -> handle
--   CH:Post(target, methodName, fn [, owner]) -> handle
--   CH:Wrap(target, methodName, fn [, owner]) -> handle
--   CH:Unhook(handle)
--   CH:UnhookOwner(owner)
--   CH._registry   -- flat array of installed hooks (read-only for Forge_Registry)
--
-- Semantics:
--   - Multiple hooks compose. Last-installed wraps outermost. Both Pre and
--     Post on the same method? Both run. Pre/Post + Wrap? Wrap controls the
--     middle, Pre runs before the whole chain, Post runs after.
--   - Original return values are preserved through Pre and Post wrappers
--     (including multi-value returns and embedded nils — we use select("#")
--     instead of naïve `{...}` table-pack).
--   - Pre/Post errors are pcall-isolated and surface via geterrorhandler.
--     Wrap errors propagate — Wrap is the "I take responsibility" mode.
--   - On the LAST unhook for a (target, method) pair, the target's original
--     function is restored as-is (no leftover wrapper).
--   - Wrapping a Blizzard secure function WILL taint it. Use Post (or
--     `hooksecurefunc` directly) for secure post-hooks.
--
-- License: MIT. Author: ChronicTinkerer.

local LIB_MAJOR = "Cairn-Hooks"
local LIB_MINOR = 1

local Cairn_Hooks = LibStub:NewLibrary(LIB_MAJOR, LIB_MINOR)
if not Cairn_Hooks then return end


-- Preserve state across MINOR upgrades.
Cairn_Hooks._registry = Cairn_Hooks._registry or {}
-- _chains[target][methodName] = chain  (two-level table; target table is the key)
Cairn_Hooks._chains   = Cairn_Hooks._chains   or {}


-- ---------------------------------------------------------------------------
-- Internal: error-isolated invocation
-- ---------------------------------------------------------------------------

local function safeCall(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        geterrorhandler()(("Cairn-Hooks: %s threw: %s"):format(label, tostring(err)))
    end
end


-- ---------------------------------------------------------------------------
-- Internal: wrapper builders
-- ---------------------------------------------------------------------------
-- Each builder takes the inner function (next layer down in the chain) and
-- the consumer's hook fn, returning a new function to assign to
-- target[methodName]. Composing builders in install order is what creates
-- the chain — see rebuildDispatcher below.

local function wrapPre(inner, fn)
    return function(...)
        safeCall("Pre hook", fn, ...)
        return inner(...)
    end
end

-- The two-step `afterInner(inner(...))` dance preserves the original args
-- across the post-hook call while still passing inner's return values
-- through to the outer caller unchanged. Three constraints made this tricky:
--   1. The post hook needs the original ARGS (not inner's returns).
--   2. The outer caller needs inner's RETURNS (not the original args).
--   3. Multi-return values may contain nils in the middle, which `{...}`
--      table-pack truncates at — hence select("#") + unpack(..., 1, n).
local function wrapPost(inner, fn)
    return function(...)
        local n = select("#", ...)
        local args = { ... }

        local function afterInner(...)
            safeCall("Post hook", fn, unpack(args, 1, n))
            return ...
        end

        return afterInner(inner(...))
    end
end

-- Wrap is the "you take responsibility" mode. The hook fn receives the
-- inner function as its first arg and decides whether/how/when to call it.
-- No pcall here — if a Wrap hook throws, that's a consumer bug that should
-- propagate. Pre/Post are observation/instrumentation; Wrap is replacement.
local function wrapWrap(inner, fn)
    return function(...)
        return fn(inner, ...)
    end
end


-- ---------------------------------------------------------------------------
-- Internal: chain management
-- ---------------------------------------------------------------------------

-- Rebuilt from scratch on every hook add/remove because that's the simplest
-- way to make Unhook work cleanly — we don't need to surgically extract
-- a wrapper from a closure chain, we just regenerate the whole stack.
-- O(N) per change where N is the number of hooks on that target; in
-- practice N is tiny (usually 1-3).
--
-- The composition order is "oldest installed = innermost wrapper", which
-- means the newest hook runs FIRST on entry and LAST on exit. Matches the
-- standard hook-chain expectation.
local function rebuildDispatcher(chain)
    local current = chain.originalFn
    for _, hook in ipairs(chain.hooks) do
        if hook.kind == "Pre" then
            current = wrapPre(current, hook.fn)
        elseif hook.kind == "Post" then
            current = wrapPost(current, hook.fn)
        elseif hook.kind == "Wrap" then
            current = wrapWrap(current, hook.fn)
        end
    end
    chain.target[chain.methodName] = current
end


-- Two-level nesting (target -> methodName -> chain) handles the typical
-- case of multiple methods on the same target each carrying their own hook
-- chain. The originalFn captured here is the function as it existed BEFORE
-- any Cairn-Hooks installation — if external code re-assigns the method
-- later, our wrapper still calls the function we captured. Matches WoW's
-- hooksecurefunc semantics; document, don't fix.
local function ensureChain(self, target, methodName)
    local byTable = self._chains[target]
    if not byTable then
        byTable = {}
        self._chains[target] = byTable
    end
    local chain = byTable[methodName]
    if not chain then
        local originalFn = target[methodName]
        if type(originalFn) ~= "function" then
            error(("Cairn-Hooks: target[%q] is not a function"):format(methodName), 3)
        end
        chain = {
            target     = target,
            methodName = methodName,
            originalFn = originalFn,
            hooks      = {},
        }
        byTable[methodName] = chain
    end
    return chain
end


local function installHook(self, kind, target, methodName, fn, owner)
    if type(target) ~= "table" then
        error(("Cairn-Hooks :%s: target must be a table"):format(kind), 3)
    end
    if type(methodName) ~= "string" or methodName == "" then
        error(("Cairn-Hooks :%s: methodName must be a non-empty string"):format(kind), 3)
    end
    if type(fn) ~= "function" then
        error(("Cairn-Hooks :%s: hook fn must be a function"):format(kind), 3)
    end

    local chain = ensureChain(self, target, methodName)
    local hook = {
        kind       = kind,
        target     = target,
        methodName = methodName,
        fn         = fn,
        owner      = owner,
        chain      = chain,
    }
    chain.hooks[#chain.hooks + 1] = hook
    rebuildDispatcher(chain)

    self._registry[#self._registry + 1] = hook
    return hook
end


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function Cairn_Hooks:Pre(target, methodName, fn, owner)
    return installHook(self, "Pre", target, methodName, fn, owner)
end

function Cairn_Hooks:Post(target, methodName, fn, owner)
    return installHook(self, "Post", target, methodName, fn, owner)
end

function Cairn_Hooks:Wrap(target, methodName, fn, owner)
    return installHook(self, "Wrap", target, methodName, fn, owner)
end


-- Two-phase removal: chain.hooks + flat _registry. The "last unhook restores
-- target[methodName] to its original function" branch is important — it
-- means consumers who install + remove a single hook leave NO trace on the
-- target. Critical for dev tools that probe state nondestructively.
function Cairn_Hooks:Unhook(hook)
    if type(hook) ~= "table" or not hook.chain or hook.kind == nil then
        error("Cairn-Hooks:Unhook: must pass a hook handle returned by :Pre/:Post/:Wrap", 2)
    end

    local chain = hook.chain

    for i = #chain.hooks, 1, -1 do
        if chain.hooks[i] == hook then
            table.remove(chain.hooks, i)
        end
    end

    for i = #self._registry, 1, -1 do
        if self._registry[i] == hook then
            table.remove(self._registry, i)
        end
    end

    if #chain.hooks == 0 then
        chain.target[chain.methodName] = chain.originalFn
        local byTable = self._chains[chain.target]
        if byTable then
            byTable[chain.methodName] = nil
            if next(byTable) == nil then
                self._chains[chain.target] = nil
            end
        end
    else
        rebuildDispatcher(chain)
    end
end


-- Collect-then-remove pattern is required because Unhook mutates _registry,
-- which we're iterating. Collecting a snapshot of matching hooks first
-- decouples the iteration from the mutation.
function Cairn_Hooks:UnhookOwner(owner)
    if owner == nil then
        error("Cairn-Hooks:UnhookOwner: owner must be non-nil", 2)
    end
    local toRemove = {}
    for i = 1, #self._registry do
        if self._registry[i].owner == owner then
            toRemove[#toRemove + 1] = self._registry[i]
        end
    end
    for _, hook in ipairs(toRemove) do
        self:Unhook(hook)
    end
end


return Cairn_Hooks
