--- libdevice - Worker-Side Pairing & Device Management
-- Generates 6-digit pairing code, advertises pairing state, completes cryptographic handshake.

local Crypto = dofile("lib/crypto/main.lua")
local Workernet = dofile("lib/workernet/main.lua")

local Device = {}
Device.CONFIG_FILE = "worker/pairing.cfg"

--- Load pairing configuration from disk.
-- @tparam[opt] string path
-- @treturn table|nil
function Device.loadConfig(path)
    path = path or Device.CONFIG_FILE
    if not fs.exists(path) then
        return nil
    end
    local f = fs.open(path, "r")
    if not f then return nil end
    local content = f.readAll()
    f.close()
    return Workernet.unserialize(content)
end

--- Save pairing configuration to disk.
-- @tparam table cfg
-- @tparam[opt] string path
-- @treturn boolean
function Device.saveConfig(cfg, path)
    path = path or Device.CONFIG_FILE
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

--- Check if device is currently paired.
-- @treturn boolean
-- @treturn table|nil Config
function Device.isPaired()
    local cfg = Device.loadConfig()
    if cfg and cfg.paired and cfg.controller_id and cfg.session_key then
        return true, cfg
    end
    return false, nil
end

--- Unpair this device and delete pairing config.
function Device.unpair()
    if fs.exists(Device.CONFIG_FILE) then
        fs.delete(Device.CONFIG_FILE)
    end
end

--- Start pairing mode on worker.
-- Generates a 6-digit pair code, listens for controller pair_req, completes handshake.
-- @tparam table net Workernet Node instance
-- @tparam[opt] function onCodeGenerated Callback(code) when code is ready
-- @tparam[opt=300] number timeout Seconds before pairing mode expires
-- @treturn boolean Success
-- @treturn table|string Result config or error
function Device.pair(net, onCodeGenerated, timeout)
    timeout = timeout or 300
    local pairCode = Crypto.generatePairCode()
    if onCodeGenerated then
        onCodeGenerated(pairCode)
    end

    local deadline = os.clock and (os.clock() + timeout) or (os.time() + timeout)

    while true do
        local remaining = os.clock and (deadline - os.clock()) or 5
        if remaining <= 0 then
            return false, "Pairing timed out"
        end

        local rawMsg, fromId, channel = net:pullMessage(1.0)
        if rawMsg and type(rawMsg) == "table" and rawMsg.type == "pair_req" then
            -- Verify pair_req signature using pairCode
            local signData = string.format("pair_req:%s:%s", tostring(rawMsg.controller_id), tostring(rawMsg.nonce))
            if Crypto.verifySignature(pairCode, signData, rawMsg.sig) then
                local controllerId = tonumber(rawMsg.controller_id)
                local wNonce = Crypto.randomHex(8)
                local cNonce = rawMsg.nonce

                -- Derive master session key
                local sessionKey = Crypto.kdf(pairCode, cNonce .. wNonce, "minerhaven_session_v1", 32)

                -- Send pair_ack back to controller
                local ackSignData = string.format("pair_ack:%d:%s:%s", net.localId, wNonce, cNonce)
                local ackSig = Crypto.hmacSha256(pairCode, ackSignData)

                local ackPacket = {
                    type = "pair_ack",
                    worker_id = net.localId,
                    nonce = wNonce,
                    c_nonce = cNonce,
                    sig = ackSig
                }

                net:transmitRaw(net.pairChannel, ackPacket)

                -- Save pairing configuration
                local cfg = {
                    paired = true,
                    worker_id = net.localId,
                    controller_id = controllerId,
                    session_key = sessionKey,
                    paired_at = os.time and os.time() or 0
                }
                Device.saveConfig(cfg)
                net:setSessionKey(controllerId, sessionKey)

                return true, cfg
            end
        end
    end
end

return Device
