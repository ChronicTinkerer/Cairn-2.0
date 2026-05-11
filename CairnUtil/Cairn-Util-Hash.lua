-- Cairn-Util-Hash
-- Attaches the `Hash` sub-namespace to Cairn-Util. Pure-Lua MD5 today; SHA
-- and other digests get added here as consumers materialize.
--
-- Consumer view:
--
--   local CU = LibStub("Cairn-Util")
--   local hex = CU.Hash.MD5("hello")        --> 32-char lowercase hex
--   local raw = CU.Hash.MD5Raw("hello")     --> 16 raw bytes
--
-- Underlying implementation is vendored AF_MD5 (kikito md5.lua + enderneko's
-- WoW compatibility tweaks, MIT licensed — see AF_MD5.lua for the full
-- attribution). This file is just the typed-API wrapper.
--
-- License: MIT (Cairn-Util-Hash's own code). The vendored AF_MD5 retains
-- its original MIT notice intact.
-- Author: ChronicTinkerer.

local Cairn_Util = LibStub and LibStub("Cairn-Util", true)
if not Cairn_Util then
    -- Cairn-Util's main file must load first. If we got here without it,
    -- the .toc is misordered — fail loud rather than silently no-op.
    error("Cairn-Util-Hash: Cairn-Util main lib is not loaded. " ..
          "Ensure Cairn-Util.lua is listed in the .toc before Cairn-Util-Hash.lua.")
end


Cairn_Util.Hash = Cairn_Util.Hash or {}


-- AF_MD5 is the vendored implementation. Retrieve once per call rather than
-- caching at file scope — a re-load (different MINOR) might swap the
-- registered impl while Cairn-Util-Hash stays the same. The cost of one
-- extra LibStub lookup per hash call is negligible against the MD5
-- computation itself.
local function getMD5()
    local md5 = LibStub and LibStub("AF_MD5", true)
    if not md5 then
        error("Cairn-Util.Hash.MD5: AF_MD5 vendored lib is not loaded. " ..
              "Check that AF_MD5.lua is listed in the .toc.", 3)
    end
    return md5
end


-- Hash.MD5(input) -> 32-char lowercase hex digest.
-- Use for fingerprinting / dedupe / identity. NOT a cryptographic primitive;
-- MD5 is broken for security purposes. The "ID for a chunk of content"
-- use case is the legitimate one.
function Cairn_Util.Hash.MD5(input)
    if type(input) ~= "string" then
        error("Cairn-Util.Hash.MD5: input must be a string", 2)
    end
    return getMD5().sumhexa(input)
end


-- Hash.MD5Raw(input) -> 16 raw bytes.
-- The undisplayable form, useful when embedding the digest in a binary
-- stream. Most consumers want the hex variant instead.
function Cairn_Util.Hash.MD5Raw(input)
    if type(input) ~= "string" then
        error("Cairn-Util.Hash.MD5Raw: input must be a string", 2)
    end
    return getMD5().sum(input)
end
