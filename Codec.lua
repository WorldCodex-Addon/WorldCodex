local _, ns = ...

-- Compact, safe (no loadstring) serializer + base64, with DEFLATE compression: the client's native
-- C_EncodingUtil when it produces raw DEFLATE, else LibDeflate when another addon loaded it.
-- Format: n<number>;  s<len>:<bytes>  T  F  { key value key value ... }
local C = {}
ns.Codec = C

local MAX_DEPTH = 12
local PREFIX = "WCX1:"
local OLD_PREFIX = "IDB1:" -- strings from before the rename are still accepted
-- LibDeflate runs in Lua: level 9 took seconds for large exports, level 5 is about six times faster
-- for strings about 10% longer.
local LIBDEFLATE_LEVEL = 5

local floor, huge, format, tostring, type, pairs = math.floor, math.huge, string.format, tostring, type, pairs

local function Yield()
    if ns.Yield then ns.Yield() end
end

-- Appends the serialized value to out[n + 1 ...] and returns the new n. Yields inside jobs.
local function SerValue(v, out, n, depth)
    local tv = type(v)
    if tv == "number" then
        if v ~= v or v == huge or v == -huge then v = 0 end
        if v == floor(v) and v > -1e14 and v < 1e14 then
            if v == 0 then v = 0 end -- no "-0"
            n = n + 1
            out[n] = "n" .. tostring(v) .. ";" -- integers below 1e14 print exactly with %.14g
        elseif v == floor(v) and v > -2 ^ 53 and v < 2 ^ 53 then
            n = n + 1
            out[n] = format("n%d;", v)
        else
            n = n + 1
            out[n] = "n" .. format("%.6g", v) .. ";"
        end
    elseif tv == "string" then
        n = n + 1
        out[n] = "s" .. #v .. ":" .. v
    elseif tv == "boolean" then
        n = n + 1
        out[n] = v and "T" or "F"
    elseif tv == "table" then
        if depth >= MAX_DEPTH then error("table too deep") end
        n = n + 1
        out[n] = "{"
        for k, val in pairs(v) do
            local tk, tval = type(k), type(val)
            if
                (tk == "number" or tk == "string") and (tval ~= "function" and tval ~= "userdata" and tval ~= "thread")
            then
                n = SerValue(k, out, n, depth + 1)
                n = SerValue(val, out, n, depth + 1)
                -- only between sections and records: deeper tables can be live data (a quest's
                -- choice list, an NPC's roles) that may gain keys while the job waits for a frame
                if depth <= 1 then Yield() end
            end
        end
        n = n + 1
        out[n] = "}"
    else
        n = n + 1
        out[n] = "F"
    end
    return n
end

function C.Serialize(v)
    local out = {}
    SerValue(v, out, 0, 0)
    return table.concat(out)
end

local function Parse(s, i, depth)
    local c = s:sub(i, i)
    if c == "n" then
        local j = s:find(";", i + 1, true)
        if not j then error("bad number") end
        local num = tonumber(s:sub(i + 1, j - 1))
        if not num then error("bad number") end
        return num, j + 1
    elseif c == "s" then
        local j = s:find(":", i + 1, true)
        if not j then error("bad string") end
        local len = tonumber(s:sub(i + 1, j - 1))
        if not len or len < 0 or j + len > #s then error("bad string length") end
        return s:sub(j + 1, j + len), j + len + 1
    elseif c == "T" then
        return true, i + 1
    elseif c == "F" then
        return false, i + 1
    elseif c == "{" then
        if depth >= MAX_DEPTH then error("table too deep") end
        local t = {}
        i = i + 1
        while true do
            if i > #s then error("unterminated table") end
            if s:sub(i, i) == "}" then return t, i + 1 end
            local k, v
            k, i = Parse(s, i, depth + 1)
            v, i = Parse(s, i, depth + 1)
            if type(k) == "table" or type(k) == "boolean" then error("bad key") end
            t[k] = v
        end
    end
    error("unexpected '" .. c .. "' at " .. i)
end

function C.Deserialize(s)
    if type(s) ~= "string" or s == "" then return nil, "empty" end
    local ok, v, nexti = pcall(Parse, s, 1, 0)
    if not ok then return nil, v end
    if nexti ~= #s + 1 then return nil, "trailing data" end
    return v
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64CHR, B64DEC = {}, {}
for i = 1, 64 do
    B64CHR[i - 1] = B64:sub(i, i)
    B64DEC[B64:byte(i)] = i - 1
end

function C.Base64Encode(data)
    local out, n = {}, 0
    local len = #data
    for i = 1, len, 3 do
        local a, b, c = data:byte(i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        n = n + 1
        out[n] = B64CHR[floor(v / 262144)]
            .. B64CHR[floor(v / 4096) % 64]
            .. (b and B64CHR[floor(v / 64) % 64] or "=")
            .. (c and B64CHR[v % 64] or "=")
        Yield()
    end
    return table.concat(out)
end

function C.Base64Decode(data)
    data = data:gsub("[^%w%+/=]", "")
    local out = {}
    for i = 1, #data, 4 do
        local q = { data:byte(i, i + 3) }
        local v = {}
        local pad = 0
        for j = 1, 4 do
            local ch = q[j]
            if ch == nil or ch == 61 then
                v[j] = 0
                pad = pad + 1
            else
                v[j] = B64DEC[ch]
                if not v[j] then return nil end
            end
        end
        local n = v[1] * 262144 + v[2] * 4096 + v[3] * 64 + v[4]
        local a = math.floor(n / 65536) % 256
        local b = math.floor(n / 256) % 256
        local c = n % 256
        if pad >= 2 then
            out[#out + 1] = string.char(a)
        elseif pad == 1 then
            out[#out + 1] = string.char(a, b)
        else
            out[#out + 1] = string.char(a, b, c)
        end
    end
    return table.concat(out)
end

local function Deflate()
    if LibStub then
        local ok, lib = pcall(LibStub, "LibDeflate", true)
        if ok and lib then return lib end
    end
    return nil
end
C.Deflate = Deflate

-- ---------------------------------------------------------------- native (C_EncodingUtil)

local nativeDeflate, nativeBase64 -- nil = not checked yet

local function Method() return Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate end

-- The client's own DEFLATE, checked once: share strings must stay raw DEFLATE streams as LibDeflate
-- writes them (merge.py and older addon versions read them that way), not zlib or gzip wrapped. The
-- low three bits of a raw stream's first byte are a block header (stored, fixed or dynamic block);
-- zlib (0x78...) and gzip (0x1f...) headers do not fit.
local function NativeDeflate()
    if nativeDeflate ~= nil then return nativeDeflate end
    nativeDeflate = false
    local E, method = C_EncodingUtil, Method()
    if not (E and E.CompressString and E.DecompressString and method ~= nil) then return false end
    local sample = string.rep("s10:WorldCodex{n1;n23;s2:md}", 40)
    local ok, comp = pcall(E.CompressString, sample, method)
    if not ok or type(comp) ~= "string" or comp == "" then return false end
    local header = comp:byte(1) % 8
    if header < 1 or header > 5 then return false end
    local okBack, back = pcall(E.DecompressString, comp, method)
    if not okBack or back ~= sample then return false end
    local lib = Deflate()
    if lib then
        local okLib, viaLib = pcall(lib.DecompressDeflate, lib, comp)
        if not okLib or viaLib ~= sample then return false end
    end
    nativeDeflate = true
    return true
end

local function NativeBase64()
    if nativeBase64 ~= nil then return nativeBase64 end
    nativeBase64 = false
    local E = C_EncodingUtil
    if not (E and E.EncodeBase64 and E.DecodeBase64) then return false end
    local sample = "WorldCodex\0\255\1x" -- 14 bytes: needs padding
    local ok, enc = pcall(E.EncodeBase64, sample)
    if not ok or enc ~= C.Base64Encode(sample) then return false end
    local okDec, dec = pcall(E.DecodeBase64, enc)
    if not okDec or dec ~= sample then return false end
    nativeBase64 = true
    return true
end

function C.Native() return NativeDeflate(), NativeBase64() end

local function Compress(raw)
    if NativeDeflate() then
        local ok, comp = pcall(C_EncodingUtil.CompressString, raw, Method())
        if ok and type(comp) == "string" and comp ~= "" then return comp end
    end
    local lib = Deflate()
    if lib then return lib:CompressDeflate(raw, { level = LIBDEFLATE_LEVEL }) end
    return nil
end

local function Decompress(bin)
    if NativeDeflate() then
        local ok, raw = pcall(C_EncodingUtil.DecompressString, bin, Method())
        if ok and type(raw) == "string" then return raw end
    end
    local lib = Deflate()
    if not lib then return nil, "compressed string needs LibDeflate" end
    local raw = lib:DecompressDeflate(bin)
    if not raw then return nil, "decompression failed" end
    return raw
end

local function ToBase64(data)
    if NativeBase64() then
        local ok, s = pcall(C_EncodingUtil.EncodeBase64, data)
        if ok and type(s) == "string" then return s end
    end
    return C.Base64Encode(data)
end

local function FromBase64(data)
    if NativeBase64() and not data:find("[^%w%+/=]") then
        local ok, s = pcall(C_EncodingUtil.DecodeBase64, data)
        if ok and type(s) == "string" then return s end
    end
    return C.Base64Decode(data)
end

-- Yields inside jobs (ns.RunJob); the compression itself is one call.
function C.Encode(tbl)
    local raw = C.Serialize(tbl)
    local comp = Compress(raw)
    if comp then return PREFIX .. "Z:" .. ToBase64(comp) end
    return PREFIX .. "R:" .. ToBase64(raw)
end

function C.Decode(str)
    if type(str) ~= "string" then return nil, "not a string" end
    str = str:gsub("%s", "")
    if str:sub(1, #OLD_PREFIX) == OLD_PREFIX then str = PREFIX .. str:sub(#OLD_PREFIX + 1) end
    if str:sub(1, #PREFIX) ~= PREFIX then return nil, "not a WorldCodex string" end
    local mode = str:sub(#PREFIX + 1, #PREFIX + 1)
    local bin = FromBase64(str:sub(#PREFIX + 3))
    if not bin then return nil, "bad encoding" end
    if mode == "Z" then
        local raw, err = Decompress(bin)
        if not raw then return nil, err end
        bin = raw
    elseif mode ~= "R" then
        return nil, "unknown mode"
    end
    return C.Deserialize(bin)
end

-- For tests: forget which native functions were found.
function C._ResetNative()
    nativeDeflate, nativeBase64 = nil, nil
end

return C
