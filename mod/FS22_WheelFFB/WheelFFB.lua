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
    VERSION = "1.6",
    -- Physical wheel rotation, lock to lock, in degrees (Wheel Studio's rotation angle).
    -- Override in modSettings/FS22_WheelFFB.xml: <wheelFFB wheelRotation="900" syncSteering="true"/>
    wheelRotation = 900,
    syncSteering = true
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
    if vehicle ~= nil and vehicle ~= ctx.loggedVehicle then
        ctx.loggedVehicle = vehicle
        pcall(WheelFFB.logGearbox, vehicle)
    end
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
    -- How far the wheel is turned past the in-game steering lock (soft lock in the FFB server).
    local over = vehicle.wheelFFBLockOver
    if over ~= nil and vehicle.wheelFFBSteerTime ~= nil and ctx.elapsed - vehicle.wheelFFBSteerTime < 250 then
        num(parts, "lockOver", over, "%.4f")
    end

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

-- 1:1 steering. FS22 turns the in-game steering wheel by input x (rotTime x indoorRotation), which
-- differs per vehicle, while a real wheel always uses its full rotation for full lock. Scale the
-- wheel's input so the in-game wheel follows the real one degree for degree, and let the steering
-- follow the wheel directly instead of FS22's gamepad-style smoothing. Turning past the in-game
-- lock is reported as lockOver, and the FFB server pushes back there (soft lock).
local function loadSettings()
    local dir = g_modSettingsDirectory
    if dir == nil and getUserProfileAppPath ~= nil then dir = getUserProfileAppPath() .. "modSettings/" end
    if dir == nil or loadXMLFile == nil then return end
    local path = dir .. "FS22_WheelFFB.xml"
    if fileExists == nil or not fileExists(path) then return end
    local xml = loadXMLFile("WheelFFB", path)
    if xml == nil or xml == 0 then return end
    local rot = getXMLInt(xml, "wheelFFB#wheelRotation")
    if rot ~= nil and rot >= 90 and rot <= 3600 then WheelFFB.wheelRotation = rot end
    local sync = getXMLBool(xml, "wheelFFB#syncSteering")
    if sync ~= nil then WheelFFB.syncSteering = sync end
    delete(xml)
end
pcall(loadSettings)

--- Degrees the in-game steering wheel turns from center to full lock, or nil if unknown.
local function inGameLock(vehicle)
    local drv = vehicle.spec_drivable
    local sw = drv ~= nil and drv.steeringWheel or nil
    if sw == nil or not finite(sw.indoorRotation) or sw.indoorRotation == 0 then return nil end
    local rotTime = math.max(math.abs(vehicle.maxRotTime or 0), math.abs(vehicle.minRotTime or 0))
    if not finite(rotTime) or rotTime <= 0 then return nil end
    return math.deg(math.abs(sw.indoorRotation) * rotTime)
end

if Drivable ~= nil and Drivable.actionEventSteer ~= nil and InputDevice ~= nil and InputDevice.CATEGORY ~= nil then
    local steer = Drivable.actionEventSteer
    Drivable.actionEventSteer = function(self, actionName, inputValue, callbackState, isAnalog, isMouse, deviceCategory, ...)
        if WheelFFB.syncSteering and isAnalog and deviceCategory == InputDevice.CATEGORY.WHEEL and finite(inputValue) then
            local lock = inGameLock(self)
            local half = WheelFFB.wheelRotation / 2
            local v = inputValue
            if lock ~= nil and lock > 1 and lock < half then
                v = inputValue * half / lock
            end
            local over = 0
            if v > 1 then over = v - 1; v = 1 elseif v < -1 then over = v + 1; v = -1 end
            self.wheelFFBLockOver = over
            self.wheelFFBDirect = v
            self.wheelFFBSteerTime = ctx.elapsed
            inputValue = v
        end
        return steer(self, actionName, inputValue, callbackState, isAnalog, isMouse, deviceCategory, ...)
    end
end

if Drivable ~= nil and Drivable.updateVehiclePhysics ~= nil then
    local physics = Drivable.updateVehiclePhysics
    Drivable.updateVehiclePhysics = function(self, axisForward, axisSide, doHandbrake, dt, ...)
        -- Steering events only arrive while the wheel is off center; a stale value means centered.
        if WheelFFB.syncSteering and self.wheelFFBDirect ~= nil and self.wheelFFBSteerTime ~= nil then
            if ctx.elapsed - self.wheelFFBSteerTime < 100 then
                if self.getIsPowered == nil or self:getIsPowered() then
                    axisSide = self.wheelFFBDirect
                    self.spec_drivable.axisSide = axisSide
                end
            else
                self.wheelFFBDirect = nil
                self.wheelFFBLockOver = 0
            end
        end
        return physics(self, axisForward, axisSide, doHandbrake, dt, ...)
    end
end

--- Writes the vehicle's gearbox to log.txt, to see how its shifter positions and ranges are laid out.
function WheelFFB.logGearbox(vehicle)
    local spec = vehicle.spec_motorized
    local motor = spec ~= nil and spec.motor or nil
    if motor == nil then return end
    local name = vehicle.getFullName ~= nil and vehicle:getFullName() or tostring(vehicle.configFileName)
    local gears = {}
    for i, g in ipairs(motor.forwardGears or {}) do
        local action = "-"
        for k, v in pairs(InputAction or {}) do
            if v == g.inputAction and type(k) == "string" and k:find("SHIFT_GEAR_SELECT_", 1, true) then action = k:sub(-1) end
        end
        gears[#gears + 1] = string.format("%d:%s@%s", i, tostring(g.name), action)
    end
    local groups = {}
    for i, g in ipairs(motor.gearGroups or {}) do groups[#groups + 1] = string.format("%d:%s", i, tostring(g.name)) end
    print(string.format("WheelFFB: gearbox of %s | gears(name@shifterPos) %s | groups %s (type %s, manual %s) | manualGears %s",
        tostring(name), table.concat(gears, " "), #groups > 0 and table.concat(groups, " ") or "none",
        tostring(motor.groupType), tostring(motor.manualShiftGroups), tostring(motor.manualShiftGears)))
end

local function isSplitGearbox(motor)
    if motor == nil or motor.forwardGears == nil then return false end
    if motor.gearGroups ~= nil and (motor.numGearGroups or 0) > 1 then return false end
    for _, gear in ipairs(motor.forwardGears) do
        if gear.inputAction == nil then return true end
    end
    return false
end

local function sendShift(vehicle, shiftType)
    pcall(MotorGearShiftEvent.sendEvent, vehicle, shiftType)
end

-- LO-HI: the mod's own input action (WHEELFFB_LOHI), because FS22 only enables "range up" on
-- vehicles that have ranges. The button decides per vehicle:
--  * ranges (gear groups): flips LO <-> HI; in the top range it shifts down.
--  * shifter positions that skip gears (John Deere 4755: 15 gears on 8 positions, 1-3-5...):
--    a splitter. It steps to the in-between gear and back, and the shifter keeps the half you chose,
--    so with the splitter on "high", 5th -> 7th lands on 8.
function WheelFFB.onLoHi(self, actionName, inputValue)
    local spec = self.spec_motorized
    local motor = spec ~= nil and spec.motor or nil
    if motor == nil then return end
    print(string.format("WheelFFB: LO-HI pressed: group %s/%s, gear %s, direction %s, split gearbox %s",
        tostring(motor.activeGearGroupIndex), tostring(motor.numGearGroups), tostring(motor.targetGear),
        tostring(motor.currentDirection), tostring(isSplitGearbox(motor))))
    if motor.gearGroups ~= nil and (motor.numGearGroups or 0) > 1 then
        local top = (motor.activeGearGroupIndex or 1) >= motor.numGearGroups
        sendShift(self, top and MotorGearShiftEvent.TYPE_SHIFT_GROUP_DOWN or MotorGearShiftEvent.TYPE_SHIFT_GROUP_UP)
        return
    end
    -- In R: step through the reverse gears (R is a shifter slot, so no other position can pick them).
    -- In reverse FS22 counts "down" as the next gear up.
    if motor.currentDirection == -1 then
        local back, t = motor.backwardGears, motor.targetGear or 0
        if back ~= nil and #back > 1 and t > 0 then
            if t < #back then
                sendShift(self, MotorGearShiftEvent.TYPE_SHIFT_DOWN)
            else
                for _ = 1, t - 1 do sendShift(self, MotorGearShiftEvent.TYPE_SHIFT_UP) end
            end
        end
        return
    end
    -- In the wheel's top shifter position (6th), on tractors with more gears above it: step up
    -- through them and wrap back, so the road gears of an 8-position gearbox are reachable.
    local gears, t = motor.forwardGears, motor.targetGear or 0
    local top = nil
    for i, gear in ipairs(gears or {}) do
        if InputAction.SHIFT_GEAR_SELECT_6 ~= nil and gear.inputAction == InputAction.SHIFT_GEAR_SELECT_6 then top = i end
    end
    if top ~= nil and t >= top and #gears > top + 1 then
        if t < #gears then
            sendShift(self, MotorGearShiftEvent.TYPE_SHIFT_UP)
            self.wheelFFBSplitHigh = true
        else
            for _ = 1, t - top do sendShift(self, MotorGearShiftEvent.TYPE_SHIFT_DOWN) end
            self.wheelFFBSplitHigh = false
        end
        return
    end
    if isSplitGearbox(motor) then
        local cur, nxt = gears[t], gears[t + 1]
        if cur ~= nil and cur.inputAction ~= nil and nxt ~= nil and nxt.inputAction == nil then
            self.wheelFFBSplitHigh = true
            sendShift(self, MotorGearShiftEvent.TYPE_SHIFT_UP)
        elseif cur ~= nil and cur.inputAction == nil then
            self.wheelFFBSplitHigh = false
            sendShift(self, MotorGearShiftEvent.TYPE_SHIFT_DOWN)
        else
            self.wheelFFBSplitHigh = not self.wheelFFBSplitHigh  -- in neutral: preselect
        end
    end
end

if Motorized ~= nil and Motorized.onRegisterActionEvents ~= nil and MotorGearShiftEvent ~= nil then
    local register = Motorized.onRegisterActionEvents
    Motorized.onRegisterActionEvents = function(self, isActiveForInput, isActiveForInputIgnoreSelection, ...)
        register(self, isActiveForInput, isActiveForInputIgnoreSelection, ...)
        if self.isClient and isActiveForInputIgnoreSelection and InputAction ~= nil and InputAction.WHEELFFB_LOHI ~= nil then
            local spec = self.spec_motorized
            local _, id = self:addActionEvent(spec.actionEvents, InputAction.WHEELFFB_LOHI, self, WheelFFB.onLoHi, false, true, false, true, nil)
            if id ~= nil and g_inputBinding ~= nil then g_inputBinding:setActionEventTextVisibility(id, false) end
        end
    end
end

-- Shifter helpers, run on every shifter position:
--  * FS22's R only flips the driving direction and choosing a gear never flips it back, so going
--    from R straight into 2nd kept reversing. Choosing a gear while reversing now switches to forward.
--  * With the splitter on "high", the shifter lands on the in-between gear.
-- Both go through the game's own (multiplayer-safe) gear events.
if Motorized ~= nil and Motorized.actionEventSelectGear ~= nil and MotorGearShiftEvent ~= nil then
    local selectGear = Motorized.actionEventSelectGear
    Motorized.actionEventSelectGear = function(self, actionName, inputValue, ...)
        local spec = self.spec_motorized
        local motor = spec ~= nil and spec.motor or nil
        if inputValue == 1 and motor ~= nil and motor.currentDirection == -1 then
            sendShift(self, MotorGearShiftEvent.TYPE_DIRECTION_CHANGE_POS)
        end
        local result = selectGear(self, actionName, inputValue, ...)
        if inputValue == 1 and self.wheelFFBSplitHigh and isSplitGearbox(motor) and InputAction ~= nil then
            local gears = motor.forwardGears
            for i, gear in ipairs(gears) do
                if gear.inputAction == InputAction[actionName] then
                    if gears[i + 1] ~= nil and gears[i + 1].inputAction == nil then
                        sendShift(self, MotorGearShiftEvent.TYPE_SHIFT_UP)
                    end
                    break
                end
            end
        end
        return result
    end
end

addModEventListener(WheelFFB)
