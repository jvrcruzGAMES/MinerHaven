--- libcrypto - Pure Lua Cryptographic Primitives for CC:Tweaked
-- Provides SHA-256, HMAC-SHA256, CTR Stream Encryption, HKDF, and Pairing Code utilities.

local Crypto = {}

--------------------------------------------------------------------------------
-- Bitwise Operations Polyfill
--------------------------------------------------------------------------------

local band, bor, bxor, bnot, rshift, lshift, rrotate

if type(bit32) == "table" then
    band = bit32.band
    bor = bit32.bor
    bxor = bit32.bxor
    bnot = bit32.bnot
    rshift = bit32.rshift
    lshift = bit32.lshift
    rrotate = bit32.rrotate or function(x, n)
        n = n % 32
        return bor(rshift(x, n), lshift(x, 32 - n))
    end
elseif type(bit) == "table" then
    band = bit.band
    bor = bit.bor
    bxor = bit.bxor
    bnot = bit.bnot
    rshift = bit.rshift
    lshift = bit.lshift
    rrotate = bit.ror or function(x, n)
        n = n % 32
        return bor(rshift(x, n), lshift(x, 32 - n))
    end
else
    -- Pure Lua fallback for 32-bit bitwise math (used in non-CC environments like tests)
    local xort, andt, ort = {}, {}, {}
    for i = 0, 255 do
        xort[i] = {}
        andt[i] = {}
        ort[i] = {}
        for j = 0, 255 do
            local x, a, o = 0, 0, 0
            local p = 1
            local ti, tj = i, j
            for _ = 1, 8 do
                local bi, bj = ti % 2, tj % 2
                if bi ~= bj then x = x + p end
                if bi == 1 and bj == 1 then a = a + p end
                if bi == 1 or bj == 1 then o = o + p end
                ti = math.floor(ti / 2)
                tj = math.floor(tj / 2)
                p = p * 2
            end
            xort[i][j] = x
            andt[i][j] = a
            ort[i][j] = o
        end
    end

    local MOD = 4294967296
    local function to32(n) return n % MOD end

    local function bxor2(a, b)
        a, b = to32(a), to32(b)
        local a0, a1, a2, a3 = a % 256, math.floor(a / 256) % 256, math.floor(a / 65536) % 256, math.floor(a / 16777216) % 256
        local b0, b1, b2, b3 = b % 256, math.floor(b / 256) % 256, math.floor(b / 65536) % 256, math.floor(b / 16777216) % 256
        return xort[a0][b0] + xort[a1][b1] * 256 + xort[a2][b2] * 65536 + xort[a3][b3] * 16777216
    end

    local function band2(a, b)
        a, b = to32(a), to32(b)
        local a0, a1, a2, a3 = a % 256, math.floor(a / 256) % 256, math.floor(a / 65536) % 256, math.floor(a / 16777216) % 256
        local b0, b1, b2, b3 = b % 256, math.floor(b / 256) % 256, math.floor(b / 65536) % 256, math.floor(b / 16777216) % 256
        return andt[a0][b0] + andt[a1][b1] * 256 + andt[a2][b2] * 65536 + andt[a3][b3] * 16777216
    end

    local function bor2(a, b)
        a, b = to32(a), to32(b)
        local a0, a1, a2, a3 = a % 256, math.floor(a / 256) % 256, math.floor(a / 65536) % 256, math.floor(a / 16777216) % 256
        local b0, b1, b2, b3 = b % 256, math.floor(b / 256) % 256, math.floor(b / 65536) % 256, math.floor(b / 16777216) % 256
        return ort[a0][b0] + ort[a1][b1] * 256 + ort[a2][b2] * 65536 + ort[a3][b3] * 16777216
    end

    band = function(a, ...)
        local n = select("#", ...)
        local res = a
        for i = 1, n do res = band2(res, select(i, ...)) end
        return res
    end
    bor = function(a, ...)
        local n = select("#", ...)
        local res = a
        for i = 1, n do res = bor2(res, select(i, ...)) end
        return res
    end
    bxor = function(a, ...)
        local n = select("#", ...)
        local res = a
        for i = 1, n do res = bxor2(res, select(i, ...)) end
        return res
    end
    bnot = function(a) return to32(MOD - 1 - to32(a)) end
    rshift = function(a, n) return math.floor(to32(a) / (2 ^ n)) end
    lshift = function(a, n) return to32(to32(a) * (2 ^ n)) end
    rrotate = function(x, n)
        n = n % 32
        return bor(rshift(x, n), lshift(x, 32 - n))
    end
end

local function add32(...)
    local sum = 0
    local MOD = 4294967296
    local n = select("#", ...)
    for i = 1, n do
        sum = (sum + select(i, ...)) % MOD
    end
    return sum
end

--------------------------------------------------------------------------------
-- SHA-256
--------------------------------------------------------------------------------

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

--- Calculate raw 32-byte binary SHA-256 digest of input string.
-- @tparam string msg
-- @treturn string 32-byte binary string
function Crypto.sha256Raw(msg)
    msg = tostring(msg or "")
    local len = #msg
    local bitLen = len * 8

    -- Padding: 0x80, zeros, 64-bit big endian length
    local padLen = (56 - (len + 1) % 64) % 64
    local pad = "\128" .. string.rep("\0", padLen)
    local highBits = math.floor(bitLen / 4294967296)
    local lowBits = bitLen % 4294967296
    local lenBytes = string.char(
        band(rshift(highBits, 24), 0xFF),
        band(rshift(highBits, 16), 0xFF),
        band(rshift(highBits, 8), 0xFF),
        band(highBits, 0xFF),
        band(rshift(lowBits, 24), 0xFF),
        band(rshift(lowBits, 16), 0xFF),
        band(rshift(lowBits, 8), 0xFF),
        band(lowBits, 0xFF)
    )
    local padded = msg .. pad .. lenBytes

    local h0 = 0x6a09e667
    local h1 = 0xbb67ae85
    local h2 = 0x3c6ef372
    local h3 = 0xa54ff53a
    local h4 = 0x510e527f
    local h5 = 0x9b05688c
    local h6 = 0x1f83d9ab
    local h7 = 0x5be0cd19

    local w = {}
    for chunkStart = 1, #padded, 64 do
        for i = 0, 15 do
            local idx = chunkStart + i * 4
            local b1, b2, b3, b4 = padded:byte(idx, idx + 3)
            w[i] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
        end
        for i = 16, 63 do
            local s0 = bxor(rrotate(w[i - 15], 7), rrotate(w[i - 15], 18), rshift(w[i - 15], 3))
            local s1 = bxor(rrotate(w[i - 2], 17), rrotate(w[i - 2], 19), rshift(w[i - 2], 10))
            w[i] = add32(w[i - 16], s0, w[i - 7], s1)
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7

        for i = 0, 63 do
            local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = add32(h, S1, ch, K[i + 1], w[i])
            local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = add32(S0, maj)

            h = g
            g = f
            f = e
            e = add32(d, temp1)
            d = c
            c = b
            b = a
            a = add32(temp1, temp2)
        end

        h0 = add32(h0, a)
        h1 = add32(h1, b)
        h2 = add32(h2, c)
        h3 = add32(h3, d)
        h4 = add32(h4, e)
        h5 = add32(h5, f)
        h6 = add32(h6, g)
        h7 = add32(h7, h)
    end

    local function wordToBytes(x)
        return string.char(
            band(rshift(x, 24), 0xFF),
            band(rshift(x, 16), 0xFF),
            band(rshift(x, 8), 0xFF),
            band(x, 0xFF)
        )
    end

    return wordToBytes(h0) .. wordToBytes(h1) .. wordToBytes(h2) .. wordToBytes(h3)
        .. wordToBytes(h4) .. wordToBytes(h5) .. wordToBytes(h6) .. wordToBytes(h7)
end

--- Calculate hex-encoded SHA-256 digest.
-- @tparam string msg
-- @treturn string 64-char lowercase hex string
function Crypto.sha256(msg)
    local raw = Crypto.sha256Raw(msg)
    local hex = {}
    for i = 1, #raw do
        table.insert(hex, string.format("%02x", raw:byte(i)))
    end
    return table.concat(hex)
end

--------------------------------------------------------------------------------
-- HMAC-SHA256
--------------------------------------------------------------------------------

--- Calculate raw 32-byte binary HMAC-SHA256.
-- @tparam string key Secret key
-- @tparam string msg Data to sign
-- @treturn string 32-byte binary HMAC
function Crypto.hmacSha256Raw(key, msg)
    key = tostring(key or "")
    msg = tostring(msg or "")
    if #key > 64 then
        key = Crypto.sha256Raw(key)
    end
    if #key < 64 then
        key = key .. string.rep("\0", 64 - #key)
    end

    local o_key_pad = {}
    local i_key_pad = {}
    for i = 1, 64 do
        local b = key:byte(i)
        o_key_pad[i] = string.char(bxor(b, 0x5c))
        i_key_pad[i] = string.char(bxor(b, 0x36))
    end

    local inner = Crypto.sha256Raw(table.concat(i_key_pad) .. msg)
    return Crypto.sha256Raw(table.concat(o_key_pad) .. inner)
end

--- Calculate hex-encoded HMAC-SHA256 signature.
-- @tparam string key Secret key
-- @tparam string msg Data to sign
-- @treturn string 64-char lowercase hex string
function Crypto.hmacSha256(key, msg)
    local raw = Crypto.hmacSha256Raw(key, msg)
    local hex = {}
    for i = 1, #raw do
        table.insert(hex, string.format("%02x", raw:byte(i)))
    end
    return table.concat(hex)
end

--- Constant-time comparison between two strings to prevent timing attacks.
-- @tparam string a
-- @tparam string b
-- @treturn boolean
function Crypto.constantTimeEqual(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    if #a ~= #b then
        return false
    end
    local diff = 0
    for i = 1, #a do
        diff = bor(diff, bxor(a:byte(i), b:byte(i)))
    end
    return diff == 0
end

--- Verify an HMAC-SHA256 signature against data and key.
-- @tparam string key
-- @tparam string msg
-- @tparam string expectedSig Hex or raw signature
-- @treturn boolean
function Crypto.verifySignature(key, msg, expectedSig)
    if type(expectedSig) ~= "string" then
        return false
    end
    local expected = expectedSig:lower()
    local computed = Crypto.hmacSha256(key, msg)
    return Crypto.constantTimeEqual(computed, expected)
end

--------------------------------------------------------------------------------
-- CTR-Mode Stream Cipher (HMAC-SHA256 Keystream)
--------------------------------------------------------------------------------

--- Generate keystream of `len` bytes for given key and nonce using HMAC-CTR mode.
local function generateKeystream(key, nonce, len)
    local blocks = {}
    local needed = math.ceil(len / 32)
    for counter = 1, needed do
        local counterBytes = string.char(
            band(rshift(counter, 24), 0xFF),
            band(rshift(counter, 16), 0xFF),
            band(rshift(counter, 8), 0xFF),
            band(counter, 0xFF)
        )
        local block = Crypto.hmacSha256Raw(key, nonce .. counterBytes)
        table.insert(blocks, block)
    end
    return table.concat(blocks):sub(1, len)
end

--- Encrypt or decrypt string data with key and nonce using CTR keystream XOR.
-- Since CTR encryption is symmetrical: decrypt(key, encrypt(key, pt, nonce), nonce) == pt.
-- @tparam string key Symmetric key (binary or string)
-- @tparam string data Plaintext or ciphertext
-- @tparam string nonce Arbitrary nonce string (e.g. 8-16 bytes)
-- @treturn string Transformed binary string
function Crypto.cipher(key, data, nonce)
    data = tostring(data or "")
    nonce = tostring(nonce or "nonce")
    local ks = generateKeystream(key, nonce, #data)
    local out = {}
    for i = 1, #data do
        table.insert(out, string.char(bxor(data:byte(i), ks:byte(i))))
    end
    return table.concat(out)
end

Crypto.encrypt = Crypto.cipher
Crypto.decrypt = Crypto.cipher

--------------------------------------------------------------------------------
-- Key Derivation (HKDF-Extract-and-Expand)
--------------------------------------------------------------------------------

--- Derive symmetric key material from master secret and salt/context.
-- @tparam string secret Master secret or pairing code
-- @tparam string salt Salt string
-- @tparam string info Context info string
-- @tparam[opt=32] number length Output key length in bytes
-- @treturn string Binary key material
function Crypto.kdf(secret, salt, info, length)
    salt = salt or "minerhaven-salt"
    info = info or "minerhaven-kdf"
    length = length or 32

    -- HKDF Extract
    local prk = Crypto.hmacSha256Raw(salt, secret)

    -- HKDF Expand
    local t = ""
    local okm = {}
    local counter = 1
    while #table.concat(okm) < length do
        t = Crypto.hmacSha256Raw(prk, t .. info .. string.char(counter))
        table.insert(okm, t)
        counter = counter + 1
    end
    return table.concat(okm):sub(1, length)
end

--------------------------------------------------------------------------------
-- Random & Pairing Code Helpers
--------------------------------------------------------------------------------

local randSeedInitialized = false
local function ensureSeed()
    if not randSeedInitialized then
        local t = os.time()
        local c = os.clock and math.floor(os.clock() * 1000) or 0
        local id = (os.getComputerID and os.getComputerID()) or 1
        math.randomseed(t + c * 37 + id * 101)
        randSeedInitialized = true
    end
end

--- Generate pseudo-random bytes.
-- @tparam number n Number of bytes
-- @treturn string Binary string of length n
function Crypto.randomBytes(n)
    ensureSeed()
    local bytes = {}
    for _ = 1, n do
        table.insert(bytes, string.char(math.random(0, 255)))
    end
    return table.concat(bytes)
end

--- Generate a random hex token.
-- @tparam number bytesLength Number of random bytes
-- @treturn string Hex string
function Crypto.randomHex(bytesLength)
    bytesLength = bytesLength or 16
    local raw = Crypto.randomBytes(bytesLength)
    local hex = {}
    for i = 1, #raw do
        table.insert(hex, string.format("%02x", raw:byte(i)))
    end
    return table.concat(hex)
end

--- Generate a six-digit numeric pairing code (e.g. "482915").
-- @treturn string Six digit numeric string (000000 - 999999)
function Crypto.generatePairCode()
    ensureSeed()
    local num = math.random(0, 999999)
    return string.format("%06d", num)
end

--- Normalize a pairing code (strips spaces/dashes, validates 6 numeric digits).
-- @tparam string code
-- @treturn string|nil, string|nil Normalized 6-digit code or (nil, error)
function Crypto.normalizePairCode(code)
    if type(code) == "number" then
        code = tostring(code)
    end
    if type(code) ~= "string" then
        return nil, "Pair code must be a string or number"
    end
    local cleaned = code:gsub("[%s%-]", "")
    if #cleaned ~= 6 or not cleaned:match("^%d%d%d%d%d%d$") then
        return nil, "Pair code must be exactly 6 numeric digits"
    end
    return cleaned, nil
end

--- Format a 6-digit pair code for human readability (e.g. "482 915").
-- @tparam string code
-- @treturn string
function Crypto.formatPairCode(code)
    local norm = Crypto.normalizePairCode(code)
    if not norm then return tostring(code) end
    return norm:sub(1, 3) .. " " .. norm:sub(4, 6)
end

return Crypto
