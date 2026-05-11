-- Cairn-Util
-- A collection of small utilities organized into named sub-namespaces.
-- The main lib file is just a registration skeleton; each category lives in
-- its own file under the same folder and attaches itself to this lib's
-- table at load time.
--
-- Consumer view:
--
--   local CU = LibStub("Cairn-Util")
--   CU.Hash.MD5("hello")              -- defined in Cairn-Util-Hash.lua
--   CU.Math.Clamp(x, 0, 1)            -- defined in Cairn-Util-Math.lua (future)
--   CU.String.IsBlank(s)              -- defined in Cairn-Util-String.lua (future)
--
-- File layout for adding a new category:
--
--   1. Create Cairn-Util-<Category>.lua in this folder.
--   2. In the file: grab the lib via LibStub("Cairn-Util"), attach a
--      sub-table (`CU.<Category> = CU.<Category> or {}`), define functions
--      under it.
--   3. Add the new file to the .toc AFTER Cairn-Util.lua (so the lib is
--      registered first) and after any vendored deps it needs.
--
-- Sizing rule (from OBJECTIVES.md): the COLLECTION can grow as needed,
-- but Cairn-Util only earns its keep as a place for helpers that are too
-- small to justify their own lib. If a category file grows past ~300 lines
-- of its own code (vendored algorithms don't count), that's a signal to
-- split it into a dedicated Cairn-<Name> lib instead of stuffing it here.
--
-- License: MIT. Author: ChronicTinkerer.

local LIB_MAJOR = "Cairn-Util"
local LIB_MINOR = 1

local Cairn_Util = LibStub:NewLibrary(LIB_MAJOR, LIB_MINOR)
if not Cairn_Util then return end


return Cairn_Util
