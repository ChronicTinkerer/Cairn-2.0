-- $Id: LibStub.lua 103 2014-10-16 03:02:50Z mikk $
-- LibStub is a simple versioning stub meant for use in Libraries.
-- Vendored here for standalone development. Idempotent: safe to load even if
-- the consumer addon already loaded its own copy.
-- See https://www.wowace.com/projects/libstub/ for details.

local LIBSTUB_MAJOR, LIBSTUB_MINOR = "LibStub", 2
local LibStub = _G[LIBSTUB_MAJOR]

-- Check to see is this version of the stub is obsolete
if not LibStub or LibStub.minor < LIBSTUB_MINOR then
    LibStub = LibStub or { libs = {}, minors = {} }
    _G[LIBSTUB_MAJOR] = LibStub
    LibStub.minor = LIBSTUB_MINOR

    -- LibStub:NewLibrary(major, minor)
    -- major (string) - the major version of the library
    -- minor (string or number) - the minor version of the library
    -- returns: a library object (newly-created if new, existing if up to date),
    --          and the existing library object if upgrading; nil if obsolete
    function LibStub:NewLibrary(major, minor)
        assert(type(major) == "string", "Bad argument #2 to `NewLibrary' (string expected)")
        minor = assert(tonumber(strmatch(minor or "", "%d+")),
            "Minor version must either be a number or contain a number.")

        local oldminor = self.minors[major]
        if oldminor and oldminor >= minor then return nil end
        self.minors[major], self.libs[major] = minor, self.libs[major] or {}
        return self.libs[major], oldminor
    end

    -- LibStub:GetLibrary(major, [silent])
    -- major (string) - the major version of the library
    -- silent (boolean) - if true, library is optional and nil is returned if not found
    -- returns: the library object, or nil + error if not found and silent is false
    function LibStub:GetLibrary(major, silent)
        if not self.libs[major] and not silent then
            error(("Cannot find a library instance of %q."):format(tostring(major)), 2)
        end
        return self.libs[major], self.minors[major]
    end

    -- LibStub:IterateLibraries(): iterates all libraries with pairs()
    function LibStub:IterateLibraries() return pairs(self.libs) end
    setmetatable(LibStub, { __call = LibStub.GetLibrary })
end
