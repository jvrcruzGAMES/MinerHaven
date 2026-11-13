--- libworkernet - Secure Transport Protocol for MinerHaven
-- Handles packet framing, encryption, HMAC signatures, sequence numbers, and replay protection.

local function loadFile(path)
    local clean = path:gsub("^/+", "")
    local ok, res = pcall(dofile, clean)
    if ok then return res end
    local ok2, res2 = pcall(dofile, "/" .. clean)
    if ok2 then return res2 end
    error("Could not load file: " .. path)
end

local Crypto = loadFile("lib/crypto/main.lua")

local Workernet = {}
Workernet.DEFAULT_CHANNEL = 4821
Workernet.PAIR_CHANNEL = 4820
Workernet.PROTOCOL_VERSION = 1

--------------------------------------------------------------------------------
-- Serialization Helper
--------------------------------------------------------------------------------

local function serialize(val)
    if type(textutils) == "table" and textutils.serialize then
        return textutils.serialize(val, { compact = true })
    end
    -- Fallback serializer for plain Lua testing environments
    local t = type(val)
    if t == "number" or t == "boolean" then
        return tostring(val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local parts = {}
        for k, v in pairs(val) do
            local kStr
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                kStr = k
            else
                kStr = "[" .. serialize(k) .. "]"
            end
            table.insert(parts, kStr .. "=" .. serialize(v))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif t == "nil" then
        return "nil"
    else
        error("Unsupported serialization type: " .. t)
    end
end

local function unserialize(str)
    if type(str) ~= "string" or str == "" then return nil end
    if type(textutils) == "table" and textutils.unserialize then
        return textutils.unserialize(str)
    end
    -- Fallback unserializer
    local func = loadstring and loadstring("return " .. str) or load("return " .. str)
    if func then
        local ok, res = pcall(func)
        if ok then return res end
    end
    return nil
end

Workernet.serialize = serialize
Workernet.unserialize = unserialize

--------------------------------------------------------------------------------
-- Network Node Class
--------------------------------------------------------------------------------

local Node = {}
Node.__index = Node

--- Find wrapped modem peripheral on any side or top/bottom.
local function findModem(preferredSide)
    if preferredSide and peripheral and peripheral.getType(preferredSide) == "modem" then
        return peripheral.wrap(preferredSide), preferredSide
    end
    if peripheral and peripheral.find then
        local p = peripheral.find("modem")
        if p then
            for _, side in ipairs(peripheral.getNames()) do
                if peripheral.getType(side) == "modem" then
                    return p, side
                end
            end
            return p, "unknown"
        end
    end
    return nil, nil
end

--- Create a new Workernet Node.
-- @tparam[opt] table opts Configuration options:
--   - modem: Wrapped modem or nil to auto-discover
--   - modemSide: Preferred side
--   - channel: Data channel (default: 4821)
--   - pairChannel: Pairing channel (default: 4820)
--   - localId: Local computer ID (default: os.getComputerID())
-- @treturn table Node instance
function Workernet.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Node)

    self.modem = opts.modem
    self.modemSide = opts.modemSide
    self.channel = opts.channel or Workernet.DEFAULT_CHANNEL
    self.pairChannel = opts.pairChannel or Workernet.PAIR_CHANNEL
    self.localId = opts.localId or (os.getComputerID and os.getComputerID()) or 0

    -- Sessions: remoteId -> { key = "...", rxSeq = 0, txSeq = 0 }
    self.sessions = {}
    -- Replay protection cache: remoteId -> { [seq] = timestamp }
    self.seenSequences = {}
    self.txSeq = 1

    return self
end

--- Auto-discover and open modem channels.
-- @treturn boolean Success
-- @treturn string|nil Error message
function Node:open()
    if not self.modem then
        self.modem, self.modemSide = findModem(self.modemSide)
    end
    if not self.modem then
        return false, "No modem attached or detected"
    end

    if not self.modem.isOpen(self.channel) then
        self.modem.open(self.channel)
    end
    if not self.modem.isOpen(self.pairChannel) then
        self.modem.open(self.pairChannel)
    end
    return true
end

--- Close opened channels.
function Node:close()
    if self.modem then
        if self.modem.isOpen(self.channel) then self.modem.close(self.channel) end
        if self.modem.isOpen(self.pairChannel) then self.modem.close(self.pairChannel) end
    end
end

--- Set or update the cryptographic session key for a remote node ID.
-- @tparam number remoteId Remote computer ID
-- @tparam string sessionKey Binary or hex key
function Node:setSessionKey(remoteId, sessionKey)
    self.sessions[remoteId] = {
        key = sessionKey,
        rxSeq = 0,
        txSeq = 0
    }
    self.seenSequences[remoteId] = {}
end

--- Get session info for a remote node ID.
function Node:getSession(remoteId)
    return self.sessions[remoteId]
end

--- Remove session key for a remote node ID.
function Node:clearSession(remoteId)
    self.sessions[remoteId] = nil
    self.seenSequences[remoteId] = nil
end

--- Transmit a raw packet over the specified channel.
-- @tparam number channel
-- @tparam table packet
-- @treturn boolean Success
function Node:transmitRaw(channel, packet)
    if not self.modem then
        local ok, err = self:open()
        if not ok then return false, err end
    end
    local ok, err = pcall(function()
        self.modem.transmit(channel, self.channel, packet)
    end)
    return ok, err
end

--- Encrypt, sign, and send a message table to a paired target node.
-- @tparam number targetId Computer ID of the destination
-- @tparam table payload Data table to send
-- @treturn boolean Success
-- @treturn string|nil Error
function Node:send(targetId, payload)
    local session = self.sessions[targetId]
    if not session or not session.key then
        return false, "No paired session key for node " .. tostring(targetId)
    end

    self.txSeq = self.txSeq + 1
    local seq = self.txSeq
    local nonce = Crypto.randomHex(8)
    local plainText = serialize(payload)
    local cipherText = Crypto.encrypt(session.key, plainText, nonce)

    -- Sign packet header + ciphertext
    local signData = string.format("%d:%d:%d:%d:%s:%s",
        Workernet.PROTOCOL_VERSION, self.localId, targetId, seq, nonce, cipherText)
    local sig = Crypto.hmacSha256(session.key, signData)

    local packet = {
        _v = Workernet.PROTOCOL_VERSION,
        from = self.localId,
        to = targetId,
        seq = seq,
        nonce = nonce,
        data = cipherText,
        sig = sig
    }

    return self:transmitRaw(self.channel, packet)
end

--- Broadcast an encrypted message to all paired sessions.
-- @tparam table payload
-- @treturn number count Number of nodes sent to
function Node:broadcast(payload)
    local count = 0
    for remoteId, _ in pairs(self.sessions) do
        local ok = self:send(remoteId, payload)
        if ok then count = count + 1 end
    end
    return count
end

--- Unpack, authenticate, and decrypt an incoming packet table.
-- @tparam table packet Raw packet table received from modem
-- @treturn table|nil Decrypted payload table
-- @treturn number|nil Sender ID
-- @treturn string|nil Error reason if invalid
function Node:unpackPacket(packet)
    if type(packet) ~= "table" then
        return nil, nil, "Invalid packet format (not a table)"
    end
    if packet._v ~= Workernet.PROTOCOL_VERSION then
        return nil, nil, "Protocol version mismatch"
    end
    if packet.to ~= self.localId and packet.to ~= -1 then
        return nil, nil, "Packet destination not for this node"
    end

    local fromId = packet.from
    local session = self.sessions[fromId]
    if not session or not session.key then
        return nil, fromId, "No active session key for sender " .. tostring(fromId)
    end

    -- Replay protection check
    local seq = tonumber(packet.seq)
    if not seq then
        return nil, fromId, "Missing sequence number"
    end
    local seen = self.seenSequences[fromId]
    if seen and seen[seq] then
        return nil, fromId, "Replay attack detected (duplicate sequence " .. seq .. ")"
    end

    -- Verify HMAC signature
    local signData = string.format("%d:%d:%d:%d:%s:%s",
        packet._v, packet.from, packet.to, packet.seq, packet.nonce, packet.data)
    if not Crypto.verifySignature(session.key, signData, packet.sig) then
        return nil, fromId, "Signature verification failed"
    end

    -- Decrypt ciphertext
    local plainText = Crypto.decrypt(session.key, packet.data, packet.nonce)
    local payload = unserialize(plainText)
    if type(payload) ~= "table" then
        return nil, fromId, "Decrypted payload failed to deserialize"
    end

    -- Record sequence number to prevent replays
    if not seen then
        seen = {}
        self.seenSequences[fromId] = seen
    end
    seen[seq] = os.time and os.time() or 1

    return payload, fromId, nil
end

--- Pull modem message event with timeout and return decrypted payload if valid.
-- @tparam[opt=0.5] number timeout Seconds to wait
-- @treturn table|nil payload
-- @treturn number|nil fromId
-- @treturn number|nil channel
function Node:pullMessage(timeout)
    local timerId
    if timeout and timeout > 0 and os.startTimer then
        timerId = os.startTimer(timeout)
    end

    while true do
        local event, p1, p2, p3, p4, p5
        if os.pullEvent then
            event, p1, p2, p3, p4, p5 = os.pullEvent()
        else
            return nil, nil, "os.pullEvent not available in environment"
        end

        if event == "timer" and p1 == timerId then
            return nil, nil, "timeout"
        elseif event == "modem_message" then
            local side, channel, replyChannel, message, distance = p1, p2, p3, p4, p5
            if channel == self.channel then
                local payload, fromId, err = self:unpackPacket(message)
                if payload then
                    return payload, fromId, channel
                end
            elseif channel == self.pairChannel then
                -- Raw pairing packet returned directly for pairing handlers
                return message, message and message.from or nil, channel
            end
        end
    end
end

return Workernet
