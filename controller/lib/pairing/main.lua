--- libpairing - Controller-Side Pairing & Worker Fleet Management
-- Initiates 6-digit numeric pairing handshake, manages paired workers and encryption keys.

local Crypto = dofile("lib/crypto/main.lua")
local Workernet = dofile("lib/workernet/main.lua")

local Pairing = {}
Pairing.CONFIG_FILE = "controller/pairing.cfg"

--- Load controller pairing configuration from disk.
-- @tparam[opt] string path
-- @treturn table
function Pairing.loadConfig(path)
    path = path or Pairing.CONFIG_FILE
    if not fs.exists(path) then
        return { workers = {} }
    end
    local f = fs.open(path, "r")
    if not f then return { workers = {} } end
    local content = f.readAll()
    f.close()
    local data = Workernet.unserialize(content)
    if type(data) == "table" and data.workers then
        return data
    end
    return { workers = {} }
end

--- Save controller pairing configuration to disk.
-- @tparam table cfg
-- @tparam[opt] string path
-- @treturn boolean
function Pairing.saveConfig(cfg, path)
    path = path or Pairing.CONFIG_FILE
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(Workernet.serialize(cfg))
    f.close()
    return true
end

--- Register all saved worker sessions into a Workernet node.
-- @tparam table net Workernet Node instance
-- @treturn number count Number of loaded sessions
function Pairing.loadSessionsIntoNode(net)
    local cfg = Pairing.loadConfig()
    local count = 0
    for workerId, info in pairs(cfg.workers) do
        if info.session_key then
            net:setSessionKey(tonumber(workerId), info.session_key)
            count = count + 1
        end
    end
    return count
end

--- Unpair a specific worker.
-- @tparam number workerId
-- @tparam[opt] table net Node instance to clear session from
-- @treturn boolean
function Pairing.unpairWorker(workerId, net)
    local cfg = Pairing.loadConfig()
    if cfg.workers[workerId] or cfg.workers[tostring(workerId)] then
        cfg.workers[workerId] = nil
        cfg.workers[tostring(workerId)] = nil
        Pairing.saveConfig(cfg)
        if net then
            net:clearSession(workerId)
        end
        return true
    end
    return false
end

--- Pair a new worker using a 6-digit numeric pairing code.
-- @tparam table net Workernet Node instance
-- @tparam string|number rawCode 6-digit pairing code shown on worker
-- @tparam[opt=15] number timeout Seconds to wait for handshake
-- @treturn boolean Success
-- @treturn number|string workerId or error message
function Pairing.pair(net, rawCode, timeout)
    local pairCode, err = Crypto.normalizePairCode(rawCode)
    if not pairCode then
        return false, err
    end
    timeout = timeout or 15

    local cNonce = Crypto.randomHex(8)
    local signData = string.format("pair_req:%d:%s", net.localId, cNonce)
    local sig = Crypto.hmacSha256(pairCode, signData)

    local pairReqPacket = {
        type = "pair_req",
        controller_id = net.localId,
        nonce = cNonce,
        sig = sig
    }

    local deadline = os.clock and (os.clock() + timeout) or (os.time() + timeout)
    local lastTransmit = 0

    while true do
        local now = os.clock and os.clock() or os.time()
        if now >= deadline then
            return false, "Pairing timed out: No matching worker replied"
        end

        -- Retransmit pair_req every 0.8 seconds until ack received
        if now - lastTransmit >= 0.8 then
            net:transmitRaw(net.pairChannel, pairReqPacket)
            lastTransmit = now
        end

        local rawMsg, fromId, channel = net:pullMessage(0.3)
        if rawMsg and type(rawMsg) == "table" and rawMsg.type == "pair_ack" then
            if rawMsg.c_nonce == cNonce then
                local workerId = tonumber(rawMsg.worker_id)
                local wNonce = rawMsg.nonce
                local expectedSignData = string.format("pair_ack:%d:%s:%s", workerId, wNonce, cNonce)

                if Crypto.verifySignature(pairCode, expectedSignData, rawMsg.sig) then
                    -- Derive session key
                    local sessionKey = Crypto.kdf(pairCode, cNonce .. wNonce, "minerhaven_session_v1", 32)

                    -- Register worker
                    local cfg = Pairing.loadConfig()
                    cfg.workers[workerId] = {
                        worker_id = workerId,
                        session_key = sessionKey,
                        paired_at = os.time and os.time() or 0,
                        name = "Turtle " .. workerId
                    }
                    Pairing.saveConfig(cfg)
                    net:setSessionKey(workerId, sessionKey)

                    return true, workerId
                end
            end
        end
    end
end

return Pairing
