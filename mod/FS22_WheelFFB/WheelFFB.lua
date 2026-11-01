-- FS22 Wheel Force Feedback: telemetry sender.
--
-- Every ~16 ms this writes one JSON line describing the vehicle you are driving to the
-- Windows named pipe \\.\pipe\WheelFFB. A relay running next to the game forwards it over a
-- WebSocket to the FFB server (V987 Wheel Studio, or the headless ffb-server), which drives the
-- wheel. Message format: https://github.com/egeSlop/ffb-server/blob/main/docs/FFB-SERVER.md
--
-- FS22's Lua has no sockets (no require, no socket library); `io` is the only way out of
-- the game, which is why the first hop is a pipe. If nothing is listening, io.open returns
-- nil and we simply try again a second later: the game is never affected.
--
-- Field names below were checked against FS22's own scripts (sdk/debugger/gameSource.zip):
-- Wheels.lua (netInfo.y, steeringAngle, rotMin/rotMax, hasGroundContact, contact,
-- densityType, lastColor[4]), Drivable.lua (axisSide), Motorized.lua.

WheelFFB = {
    PIPE = "\\\\.\\pipe\\WheelFFB",
    SEND_INTERVAL = 16,   -- ms, ~60 Hz
    RETRY_INTERVAL = 1000, -- ms between attempts to open the pipe
    VERSION = "1.1"
}

local ctx = { file = nil, pending = 0, retry = WheelFFB.RETRY_INTERVAL, seq = 0, elapsed = 0, warned = 0 }

local function finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function num(parts, key, v, fmt)
    if finite(v) then
        parts[#parts + 1] = string.format('"%s":' .. (fmt or "%.5f"), key, v)
    end
end

local function controlledVehicle()
    local m = g_currentMission
    if m == nil then return nil end
    local v = m.controlledVehicle
    if v ~= nil and v.getIsEntered ~= nil and not v:getIsEntered() then return nil end
    return v
end

local function isPaused()
    local m = g_currentMission
    -- The mission class isn't in the shipped sources; accept either field name. The GUI check
    -- below (verified in Gui.lua) already covers the pause menu.
    if m == nil or m.paused == true or m.isPaused == true then return true end
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then return true end
    return false
end

-- Same ground classification FS22 uses for tyre friction (Wheels:updateWheelFriction).
local function surfaceOf(wheel)
    if wheel.hasSnowContact then return "snow" end
    if not wheel.hasGroundContact then return "air" end
    local isField = wheel.densityType ~= nil and wheel.densityType ~= 0
    if isField then return "field" end
    local onObject = Wheels ~= nil and wheel.contact ~= Wheels.WHEEL_GROUND_CONTACT
    local depth = wheel.lastColor ~= nil and wheel.lastColor[4] or 0
    if onObject or not finite(depth) or depth < 0.1 then return "road" end
    if depth > 0.8 then return "soft" end
    return "hard"
end

function WheelFFB:buildLine()
    ctx.seq = ctx.seq + 1
    local parts = { '"v":1', '"seq":' .. ctx.seq, string.format('"t":%.3f', ctx.elapsed / 1000) }

    local vehicle = controlledVehicle()
    if vehicle == nil or isPaused() then
        parts[#parts + 1] = '"active":false'
        return "{" .. table.concat(parts, ",") .. "}"
    end
    parts[#parts + 1] = '"active":true'

    -- Speed in m/s; sign from movingDirection (1 forward, -1 reverse).
    if vehicle.getLastSpeed ~= nil then
        local kmh = vehicle:getLastSpeed()
        local dir = vehicle.movingDirection or 1
        if finite(kmh) then num(parts, "speed", kmh / 3.6 * (dir < 0 and -1 or 1)) end
    end

    -- Driver steering input (-1..1) as the game sees it.
    local drv = vehicle.spec_drivable
    if drv ~= nil then num(parts, "steerInput", drv.axisSide) end

    -- Engine.
    local mot = vehicle.spec_motorized
    if mot ~= nil then
        local on = vehicle.getIsMotorStarted ~= nil and vehicle:getIsMotorStarted() or false
        parts[#parts + 1] = '"engine":' .. tostring(on == true)
        local motor = mot.motor
        if motor ~= nil then
            if motor.getLastModulatedMotorRpm ~= nil then num(parts, "rpm", motor:getLastModulatedMotorRpm(), "%.1f") end
            if motor.getMaxRpm ~= nil then num(parts, "maxRpm", motor:getMaxRpm(), "%.1f") end
            if motor.getMinRpm ~= nil then num(parts, "minRpm", motor:getMinRpm(), "%.1f") end
        end
        num(parts, "load", mot.smoothedLoadPercentage, "%.4f")
    end

    -- Chassis motion, in the vehicle's own frame.
    local node = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
    if node ~= nil and node ~= 0 and (entityExists == nil or entityExists(node)) then
        local vx, vy, vz = getLinearVelocity(node)
        if finite(vx) and finite(vy) and finite(vz) then
            local lx, ly, lz = worldDirectionToLocal(node, vx, vy, vz)
            num(parts, "vLat", lx); num(parts, "vUp", ly); num(parts, "vFwd", lz)
        end
        local ax, ay, az = getAngularVelocity(node)
        if finite(ax) and finite(ay) and finite(az) then
            local px, yw, rl = worldDirectionToLocal(node, ax, ay, az)
            num(parts, "pitchRate", px); num(parts, "yawRate", yw); num(parts, "rollRate", rl)
        end
        if getMass ~= nil then num(parts, "mass", getMass(node), "%.3f") end
    end

    -- Wheels: steered wheels give the actual steering angle; suspension travel gives bumps.
    local wheels = {}
    local spec = vehicle.spec_wheels
    if spec ~= nil and spec.wheels ~= nil then
        for i, w in ipairs(spec.wheels) do
            if i > 12 then break end
            local e = { '"i":' .. i }
            local steerMax = math.max(math.abs(w.rotMax or 0), math.abs(w.rotMin or 0))
            if steerMax > 0.001 then
                e[#e + 1] = '"steered":true'
                num(e, "steer", w.steeringAngle)
                num(e, "steerMax", steerMax)
            end
            if w.netInfo ~= nil then num(e, "y", w.netInfo.y) end
            if w.positionX ~= nil then num(e, "x", w.positionX) end
            e[#e + 1] = '"surface":"' .. surfaceOf(w) .. '"'
            wheels[#wheels + 1] = "{" .. table.concat(e, ",") .. "}"
        end
    end
    parts[#parts + 1] = '"wheels":[' .. table.concat(wheels, ",") .. "]"
    return "{" .. table.concat(parts, ",") .. "}"
end

function WheelFFB:close()
    if ctx.file ~= nil then
        pcall(ctx.file.close, ctx.file)
        ctx.file = nil
    end
end

function WheelFFB:update(dt)
    if g_dedicatedServerInfo ~= nil or g_client == nil or not finite(dt) or dt <= 0 then return end
    ctx.elapsed = ctx.elapsed + dt
    ctx.pending = ctx.pending + dt
    if ctx.pending < WheelFFB.SEND_INTERVAL then return end
    ctx.pending = 0

    if ctx.file == nil then
        ctx.retry = ctx.retry + dt
        if ctx.retry < WheelFFB.RETRY_INTERVAL then return end
        ctx.retry = 0
        local ok, f = pcall(io.open, WheelFFB.PIPE, "w")
        if not ok or f == nil then return end
        ctx.file = f
        print("WheelFFB: connected to relay")
        local okHello = pcall(function()
            f:write('{"type":"hello","game":"Farming Simulator 22","source":"FS22_WheelFFB ' .. WheelFFB.VERSION .. '","protocol":1}\n')
            f:flush()
        end)
        if not okHello then
            self:close()
            return
        end
    end

    local okLine, line = pcall(self.buildLine, self)
    if not okLine then
        if ctx.elapsed > ctx.warned then
            print("WheelFFB: telemetry error: " .. tostring(line))
            ctx.warned = ctx.elapsed + 10000
        end
        return
    end

    local ok, err = pcall(function()
        local r, e = ctx.file:write(line .. "\n")
        if r == nil and e ~= nil then error(e) end
        ctx.file:flush()
    end)
    if not ok then
        print("WheelFFB: relay disconnected (" .. tostring(err) .. ")")
        self:close()
    end
end

function WheelFFB:deleteMap()
    self:close()
end

addModEventListener(WheelFFB)
