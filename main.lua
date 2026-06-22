-- AutoBuilder Script with Rayfield UI
-- Features: Auto-break, auto-place, freecam, area selection, structure saving/loading
-- UI: Rayfield (supports TextBoxes, Tabs, mobile-friendly)

-- Load Rayfield UI library
--local Rayfield = loadstring(game:HttpGet('https://raw.githubusercontent.com/shlexware/Rayfield/main/source'))()
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
-- Create Window
local Window = Rayfield:CreateWindow({
    Name = "AutoBuilder",
    LoadingTitle = "AutoBuilder Interface",
    LoadingSubtitle = "by ChipLag",
    ConfigurationSaving = {
        Enabled = false,
        FolderName = nil, -- Create a custom folder for your hub/game
        FileName = "AutoBuilder"
    },
    Discord = {
        Enabled = false,
        Invite = "noinvitelink", -- The Discord invite code, do not include discord.gg/
        RememberJoins = true -- Set this to false to make them join the discord every time they load it up
    },
    KeySystem = false -- Set this to true to use our key system
})

-- Services
local uis = game:GetService("UserInputService")
local rs = game:GetService("RunService")
local players = game:GetService("Players")
local localPlayer = players.LocalPlayer

-- Variables
local blocksize = 3
local maxDist = 16.5
local breakRemote = game.ReplicatedStorage.GameRemotes.BreakBlock
local placeRemote = game.ReplicatedStorage.GameRemotes.PlaceBlock
local changeSlot = game.ReplicatedStorage.GameRemotes.ChangeSlot
local cworld = require(game.Players.LocalPlayer.PlayerScripts.MainLocalScript.CWorld)
local ids = require(game.ReplicatedStorage.AssetsMod.IDs)

-- State variables
local breakRunning = false
local placeRunning = false
local radius = 5
local placeSlot = 0
local placeBlockId = nil
local placeItemName = ""
local origCF = nil
local origPos = nil
local breakCount = 0
local placeCount = 0
local idleLimit = 2
local freecamSpeed = 30
local placeOverrideMode = false
local isMobile = uis.TouchEnabled


-- Structures storage
local structures = {} -- name -> {blocks = {{x,y,z,id}, ...}, width, height, depth}

-- Freecam state
local fcPart = nil
local fcYaw = 0
local fcPitch = 0
local fcRenderConn = nil
local fcLockConn = nil
local fcInputBeganConn = nil
local fcInputChangedConn = nil
local fcInputEndedConn = nil
local lockedCF = nil
local keysDown = {}
local touchMoveStart = nil
local touchLastPos = nil

-- Area selection state
local areaCorner1 = nil
local areaCorner2 = nil
local areaHighlight1 = nil
local areaHighlight2 = nil
local areaMarker1 = nil
local areaMarker2 = nil
local useAreaSelection = false
local areaSelectMode = nil

-- Core functions
local function getCam()
    return workspace.CurrentCamera
end

local function getBlockCoords(worldPos)
    return math.floor(worldPos.X / blocksize + 0.5),
           math.floor(worldPos.Y / blocksize + 0.5),
           math.floor(worldPos.Z / blocksize + 0.5)
end

local function getLookRayTarget()
    local cam = getCam()
    if not cam then return Vector3.new(0, 0, 0) end
    local origin = cam.CFrame.Position
    local direction = cam.CFrame.LookVector
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local char = players.LocalPlayer.Character
    if char then
        params.FilterDescendantsInstances = {char}
    end
    local result = workspace:Raycast(origin, direction * 1000, params)
    if result then
        return result.Position
    end
    -- Return player position instead of camera forward position when no block is hit
    local char = players.LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        return char.HumanoidRootPart.Position
    end
    return origin  -- Fallback to camera origin if no character
end

local function updatePlaceInfo()
    local inv = players.LocalPlayer.Character.Inventory
    local slot = inv:FindFirstChild("Slot" .. placeSlot)
    if slot then
        local data = game:GetService("HttpService"):JSONDecode(slot.Value)
        placeItemName = data.name
        if data.count > 0 and data.name ~= "" then
            local itemDef = ids.ByName.Items[data.name]
            if itemDef then
                local blockName = itemDef.block or data.name
                local blockDef = ids.ByName.Blocks[blockName]
                placeBlockId = blockDef and blockDef.id
                return true
            end
        end
    end
    placeBlockId = nil
    return false
end

local function getSlotWithBlockId(blockId)
    local character = players.LocalPlayer.Character
    if not character then return nil end
    local inventory = character:FindFirstChild("Inventory")
    if not inventory then return nil end
    for i = 0, 8 do
        local slot = inventory:FindFirstChild("Slot" .. i)
        if slot then
            local success, data = pcall(function()
                return game:GetService("HttpService"):JSONDecode(slot.Value)
            end)
            if success and data and data.name ~= "" then
                local itemDef = ids.ByName.Items[data.name]
                if itemDef then
                    local blockName = itemDef.block or data.name
                    local blockDef = ids.ByName.Blocks[blockName]
                    if blockDef and blockDef.id == blockId then
                        return i
                    end
                end
            end
        end
    end
    return nil
end

local function findAdjacentBlock(x, y, z)
    local neighbors = {
        {dx = 0, dy = -1, dz = 0},
        {dx = 0, dy = 1, dz = 0},
        {dx = -1, dy = 0, dz = 0},
        {dx = 1, dy = 0, dz = 0},
        {dx = 0, dy = 0, dz = -1},
        {dx = 0, dy = 0, dz = 1},
    }
    local dirMap = {
        [1] = 5,
        [2] = 1,
        [3] = 2,
        [4] = 3,
        [5] = 4,
        [6] = 0,
    }
    for i, n in ipairs(neighbors) do
        local block, _ = cworld.getBlock(x + n.dx, y + n.dy, z + n.dz)
        if block and block.id then
            return x + n.dx, y + n.dy, z + n.dz, dirMap[i]
        end
    end
    return nil, nil, nil, nil
end

local function saveState()
    local char = players.LocalPlayer.Character
    if char then
        origCF = getCam().CFrame
        origPos = char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.CFrame
    end
end

local function restoreState()
    pcall(function()
        if fcLockConn then
            fcLockConn:Disconnect()
            fcLockConn = nil
        end
        lockedCF = nil
        if origCF then
            getCam().CFrame = origCF
            origCF = nil
        end
        if origPos then
            local char = players.LocalPlayer.Character
            if char and char:FindFirstChild("HumanoidRootPart") then
                char.HumanoidRootPart.CFrame = origPos
            end
            origPos = nil
        end
        getCam().CameraType = Enum.CameraType.Custom
    end)
end

local function startFreecam()
    if fcPart then return end

    local pos = getCam().CFrame.Position
    local look = getCam().CFrame.LookVector

    fcPart = Instance.new("Part")
    fcPart.Anchored = true
    fcPart.CanCollide = false
    fcPart.Transparency = 1
    fcPart.Size = Vector3.new(1, 1, 1)
    fcPart.Parent = workspace

    fcPart.CFrame = CFrame.lookAt(pos, pos + look)
    fcPitch, fcYaw = fcPart.CFrame:ToOrientation()

    getCam().CameraType = Enum.CameraType.Scriptable
    getCam().CFrame = fcPart.CFrame
    uis.MouseBehavior = Enum.MouseBehavior.LockCenter
    uis.MouseIconEnabled = false

    local char = players.LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        lockedCF = char.HumanoidRootPart.CFrame
    end

    fcInputBeganConn = uis.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.UserInputType == Enum.UserInputType.Touch then
            local screenPos = input.Position
            if screenPos.X < 300 then -- Left side of screen for joystick
                touchMoveStart = screenPos
                touchLastPos = screenPos
            end
        else
            keysDown[input.KeyCode] = true
        end
    end)

    fcInputChangedConn = uis.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            local screenPos = input.Position
            if screenPos.X < 300 then -- Left side of screen for joystick
                touchLastPos = screenPos
            end
        end
    end)

    fcInputEndedConn = uis.InputEnded:Connect(function(input, gameProcessed)
        if input.UserInputType == Enum.UserInputType.Touch then
            touchMoveStart = nil
            touchLastPos = nil
        else
            keysDown[input.KeyCode] = false
        end
    end)

    fcRenderConn = rs.RenderStepped:Connect(function(dt)
        if not fcPart then return end
        getCam().CameraType = Enum.CameraType.Scriptable

        local delta = uis:GetMouseDelta()
        fcYaw = fcYaw - delta.X * 0.008
        fcPitch = math.clamp(fcPitch - delta.Y * 0.008, -math.pi / 2.2, math.pi / 2.2)

        local orientCf = CFrame.fromOrientation(0, fcYaw, 0)
        local fwd = orientCf.LookVector
        local right = orientCf.RightVector
        local up = Vector3.new(0, 1, 0)

        local moveDir = Vector3.new(0,0,0)

        if keysDown[Enum.KeyCode.W] then moveDir = moveDir + fwd end
        if keysDown[Enum.KeyCode.S] then moveDir = moveDir - fwd end
        if keysDown[Enum.KeyCode.A] then moveDir = moveDir - right end
        if keysDown[Enum.KeyCode.D] then moveDir = moveDir + right end
        if keysDown[Enum.KeyCode.Space] then moveDir = moveDir + up end
        if keysDown[Enum.KeyCode.LeftShift] then moveDir = moveDir - up end
        if keysDown[Enum.KeyCode.Up] then moveDir = moveDir + fwd end
        if keysDown[Enum.KeyCode.Down] then moveDir = moveDir - fwd end
        if keysDown[Enum.KeyCode.Left] then moveDir = moveDir - right end
        if keysDown[Enum.KeyCode.Right] then moveDir = moveDir + right end

        -- Handle mobile joystick touch input
        if isMobile and touchMoveStart and touchLastPos then
            local diff = touchLastPos - touchMoveStart
            -- Convert touch delta to movement (adjust sensitivity as needed)
            local move = Vector3.new(-diff.X * 0.3, 0, -diff.Y * 0.3)
            local rotatedMove = (orientCf * CFrame.new(move)).Position
            moveDir = moveDir + rotatedMove
            -- Update the start position for next frame (relative movement)
            touchMoveStart = touchLastPos
        end

        if moveDir.Magnitude > 0 then
            fcPart.CFrame = fcPart.CFrame + moveDir.Unit * freecamSpeed * dt
        end

        fcPart.CFrame = CFrame.new(fcPart.Position) * CFrame.fromOrientation(fcPitch, fcYaw, 0)
        getCam().CFrame = fcPart.CFrame
    end)

    fcLockConn = rs.Heartbeat:Connect(function()
        if lockedCF then
            local char = players.LocalPlayer.Character
            if char and char:FindFirstChild("HumanoidRootPart") then
                char.HumanoidRootPart.CFrame = lockedCF
            end
        end
    end)
end

local function stopFreecam()
    if fcRenderConn then
        fcRenderConn:Disconnect()
        fcRenderConn = nil
    end
    if fcInputBeganConn then
        fcInputBeganConn:Disconnect()
        fcInputBeganConn = nil
    end
    if fcInputEndedConn then
        fcInputEndedConn:Disconnect()
        fcInputEndedConn = nil
    end
    if fcInputChangedConn then
        fcInputChangedConn:Disconnect()
        fcInputChangedConn = nil
    end
    if fcPart then
        fcPart:Destroy()
        fcPart = nil
    end
    uis.MouseBehavior = Enum.MouseBehavior.Default
    uis.MouseIconEnabled = true
    keysDown = {}
    touchMoveStart = nil
    touchLastPos = nil
end

local function placeBlockAt(x, y, z, override, blockId, slot)
    -- Use provided blockId and slot if given, otherwise fallback to current
    local useBlockId = blockId or placeBlockId
    local useSlot = slot or placeSlot
    if not useBlockId then
        if not updatePlaceInfo() then
            return false
        end
        -- After updatePlaceInfo, placeBlockId and placeSlot are set
        useBlockId = placeBlockId
        useSlot = placeSlot
    end

    local blockData, chunk = cworld.getBlock(x, y, z)
    if not chunk then
        return false
    end

    if blockData and blockData.id then
        if not override then
            return false
        end
        if blockData.id == useBlockId then
            return false
        end
        local target = Vector3.new(x * blocksize, y * blocksize, z * blocksize)
        getCam().CFrame = CFrame.lookAt(target + Vector3.new(0, 5, 8), target)
        breakRemote:FireServer(x, y, z, nil)
    end

    local adjX, adjY, adjZ, dir = findAdjacentBlock(x, y, z)
    if not adjX then
        return false
    end

    local adjWorld = Vector3.new(adjX * blocksize, adjY * blocksize, adjZ * blocksize)
    getCam().CFrame = CFrame.lookAt(adjWorld + Vector3.new(0, 5, 0.001), adjWorld)

    local pred = cworld.placeBlock(x, y, z, chunk, dir, useBlockId)
    if not pred then
        return false
    end

    task.spawn(function()
        placeRemote:InvokeServer(x, y, z, useSlot, dir)
    end)
    return true
end

local function clearAreaHighlights()
    if areaHighlight1 then
        areaHighlight1:Destroy()
        areaHighlight1 = nil
    end
    if areaHighlight2 then
        areaHighlight2:Destroy()
        areaHighlight2 = nil
    end
    if areaMarker1 then
        areaMarker1:Destroy()
        areaMarker1 = nil
    end
    if areaMarker2 then
        areaMarker2:Destroy()
        areaMarker2 = nil
    end
    areaCorner1 = nil
    areaCorner2 = nil
end

local function makeAreaHighlight(part, which)
    local hl = Instance.new("Highlight")
    hl.FillColor = which == 1 and Color3.new(1, 0, 0) or Color3.new(0, 1, 0)
    hl.OutlineColor = which == 1 and Color3.new(0.8, 0, 0) or Color3.new(0, 0.8, 0)
    hl.FillTransparency = 0
    hl.OutlineTransparency = 0
    hl.Adornee = part
    hl.Parent = part
    return hl
end

local function setAreaPoint(which)
    local pos = getLookRayTarget()
    local bx, by, bz = getBlockCoords(pos)
    local blockPos = Vector3.new(bx * blocksize, by * blocksize, bz * blocksize)

    local function createMarker()
        local p = Instance.new("Part")
        p.Anchored = true
        p.CanCollide = false
        p.Size = Vector3.new(blocksize - 0.0001, blocksize - 0.0001, blocksize - 0.0001)
        p.CFrame = CFrame.new(blockPos)
        p.Transparency = 0
        p.Color = which == 1 and Color3.new(1, 0, 0) or Color3.new(0, 1, 0)
        p.Material = Enum.Material.Neon
        p.Parent = workspace
        return p
    end

    if which == 1 then
        if areaMarker1 then areaMarker1:Destroy() end
        if areaHighlight1 then areaHighlight1:Destroy() end
        areaMarker1 = createMarker()
        areaCorner1 = {bx = bx, by = by, bz = bz}
        areaHighlight1 = makeAreaHighlight(areaMarker1, 1)
    else
        if areaMarker2 then areaMarker2:Destroy() end
        if areaHighlight2 then areaHighlight2:Destroy() end
        areaMarker2 = createMarker()
        areaCorner2 = {bx = bx, by = by, bz = bz}
        areaHighlight2 = makeAreaHighlight(areaMarker2, 2)
    end
end

-- Structure functions
local function getStructureBounds()
    if not areaCorner1 or not areaCorner2 then
        return nil
    end
    local minX = math.min(areaCorner1.bx, areaCorner2.bx)
    local maxX = math.max(areaCorner1.bx, areaCorner2.bx)
    local minY = math.min(areaCorner1.by, areaCorner2.by)
    local maxY = math.max(areaCorner1.by, areaCorner2.by)
    local minZ = math.min(areaCorner1.bz, areaCorner2.bz)
    local maxZ = math.max(areaCorner1.bz, areaCorner2.bz)
    return {
        minX = minX,
        maxX = maxX,
        minY = minY,
        maxY = maxY,
        minZ = minZ,
        maxZ = maxZ,
        width = maxX - minX + 1,
        height = maxY - minY + 1,
        depth = maxZ - minZ + 1
    }
end

local function saveStructure(name)
    if not name or name == "" then
        return false, "Structure name cannot be empty"
    end
    
    if structures[name] then
        return false, "A structure with this name already exists"
    end
    
    local bounds = getStructureBounds()
    if not bounds then
        return false, "Please set both area points first"
    end
    
    local blocks = {}
    for x = bounds.minX, bounds.maxX do
        for y = bounds.minY, bounds.maxY do
            for z = bounds.minZ, bounds.maxZ do
                local blockData, _ = cworld.getBlock(x, y, z)
                if blockData and blockData.id then
                    table.insert(blocks, {
                        x = x - bounds.minX,
                        y = y - bounds.minY,
                        z = z - bounds.minZ,
                        id = blockData.id
                    })
                end
            end
        end
    end
    
    structures[name] = {
        blocks = blocks,
        width = bounds.width,
        height = bounds.height,
        depth = bounds.depth
    }
    
    return true, "Structure saved successfully"
end

local function loadStructureFromPlayerPos(name, placeMode, rotation)
    rotation = rotation or 0
    local structure = structures[name]
    if not structure then
        return false, "Structure not found"
    end
    
    -- Get player position as origin
    local char = players.LocalPlayer.Character
    if not char or not char:FindFirstChild("HumanoidRootPart") then
        return false, "Player character not found"
    end
    
    local originPos = char.HumanoidRootPart.Position
    local originX = math.floor(originPos.X / blocksize + 0.5)
    local originY = math.floor(originPos.Y / blocksize + 0.5) - 1
    local originZ = math.floor(originPos.Z / blocksize + 0.5)
    
    local width = structure.width
    local depth = structure.depth
    
    local placedCount = 0
    for _, block in ipairs(structure.blocks) do
        local x = block.x
        local y = block.y
        local z = block.z
        
        -- Apply rotation to x and z
        local rx, rz
        if rotation == 0 then
            rx, rz = x, z
        elseif rotation == 1 then
            rx, rz = z, width - 1 - x
        elseif rotation == 2 then
            rx, rz = width - 1 - x, depth - 1 - z
        elseif rotation == 3 then
            rx, rz = depth - 1 - z, x
        end
        
        local worldX = originX + rx
        local worldY = originY + y
        local worldZ = originZ + rz
        
        -- Check if we're allowed to place here (respect override mode)
        local blockData, _ = cworld.getBlock(worldX, worldY, worldZ)
        local canPlace = true
        if not placeMode then
            -- When not in override mode, we can only place if there's no block
            if blockData and blockData.id then
                canPlace = false
            end
        else
            -- When in override mode, we can place regardless of what's there
            -- But we can skip if it's the same block to avoid unnecessary work
            if blockData and blockData.id == block.id then
                canPlace = false  -- Skip if same block type (optimization)
            end
            -- Otherwise canPlace remains true
        end
        
        if canPlace then
            local slot = getSlotWithBlockId(block.id)
            if placeBlockAt(worldX, worldY, worldZ, placeMode, block.id, slot) then
                placedCount = placedCount + 1
            end
        end
    end
    
    return true, string.format("Loaded structure '%s': %d blocks placed", name, placedCount)
end

local function deleteStructure(name)
    if not structures[name] then
        return false, "Structure not found"
    end
    
    structures[name] = nil
    
    return true, string.format("Structure '%s' deleted", name)
end

local function getStructureList()
    local list = {}
    for name, _ in pairs(structures) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
end

-- Tab creation and UI building
-- Settings Tab
local settingsTab = Window:CreateTab("Settings", 4483362458) -- Gear icon
settingsTab:CreateSlider({
    Name = "Freecam Speed",
    Range = {5, 100},
    Increment = 1,
    Suffix = " stud/s",
    CurrentValue = freecamSpeed,
    Flag = "freecamSpeed",
    Callback = function(value)
        freecamSpeed = value
    end
})

-- Area Tab
local areaTab = Window:CreateTab("Area", 6031098825) -- Map icon
local areaStatusLabel = areaTab:CreateLabel("Area: Not set")

areaTab:CreateToggle({
    Name = "Use Area Selection",
    CurrentValue = useAreaSelection,
    Flag = "useAreaSelection",
    Callback = function(value)
        useAreaSelection = value
    end
})

areaTab:CreateButton({
    Name = "Set Point 1",
    Callback = function()
        setAreaPoint(1)
        if areaCorner1 and areaCorner2 then
            areaStatusLabel:Set(string.format("Area: (%d,%d,%d) to (%d,%d,%d)", 
                areaCorner1.bx, areaCorner1.by, areaCorner1.bz,
                areaCorner2.bx, areaCorner2.by, areaCorner2.bz))
        else
            areaStatusLabel:Set("Area: Point 1 set, need Point 2")
        end
    end
})

areaTab:CreateButton({
    Name = "Set Point 2",
    Callback = function()
        setAreaPoint(2)
        if areaCorner1 and areaCorner2 then
            areaStatusLabel:Set(string.format("Area: (%d,%d,%d) to (%d,%d,%d)", 
                areaCorner1.bx, areaCorner1.by, areaCorner1.bz,
                areaCorner2.bx, areaCorner2.by, areaCorner2.bz))
        else
            areaStatusLabel:Set("Area: Point 2 set, need Point 1")
        end
    end
})

areaTab:CreateButton({
    Name = "Clear Area",
    Callback = function()
        clearAreaHighlights()
        areaStatusLabel:Set("Area: Not set")
    end
})

-- Break Tab
local breakTab = Window:CreateTab("Break", 6022668868) -- Hammer icon
local breakLabel = breakTab:CreateLabel("Status: Idle")
local breakCountLabel = breakTab:CreateLabel("Broken: 0")

breakTab:CreateSlider({
    Name = "Radius",
    Range = {2, 10},
    Increment = 1,
    CurrentValue = radius,
    Flag = "breakRadius",
    Callback = function(value)
        radius = value
    end
})

breakTab:CreateButton({
    Name = "Start Break",
    Callback = function()
        if breakRunning or placeRunning then return end
        breakRunning = true
        breakLabel:Set("Status: Breaking...")
        breakCount = 0
        breakCountLabel:Set("Broken: 0")
        saveState()
        startFreecam()
        
        task.spawn(function()
            local ok, err = pcall(function()
                local char = players.LocalPlayer.Character
                if not char or not char:FindFirstChild("HumanoidRootPart") then
                    breakRunning = false
                    breakLabel:Set("Status: Dead/No Char")
                    return
                end
                local bx, by, bz = getBlockCoords(char.HumanoidRootPart.Position)
                local scanCount = 0
                local maxScans = 100
                local idle = 0

                local scanMinX, scanMaxX, scanMinY, scanMaxY, scanMinZ, scanMaxZ
                local useAreaScan = useAreaSelection and areaCorner1 and areaCorner2

                while breakRunning do
                    scanCount = scanCount + 1
                    if scanCount > maxScans then
                        breakLabel:Set("Status: Max scans reached")
                        break
                    end

                    if useAreaScan then
                        scanMinX = math.min(areaCorner1.bx, areaCorner2.bx)
                        scanMaxX = math.max(areaCorner1.bx, areaCorner2.bx)
                        scanMinY = math.min(areaCorner1.by, areaCorner2.by)
                        scanMaxY = math.max(areaCorner1.by, areaCorner2.by)
                        scanMinZ = math.min(areaCorner1.bz, areaCorner2.bz)
                        scanMaxZ = math.max(areaCorner1.bz, areaCorner2.bz)
                    else
                        scanMinX = bx - radius
                        scanMaxX = bx + radius
                        scanMinY = by - radius
                        scanMaxY = by + radius
                        scanMinZ = bz - radius
                        scanMaxZ = bz + radius
                    end

                    local anyBroken = false
                    local breakYield = 0
                    for x = scanMinX, scanMaxX do
                        for y = scanMinY, scanMaxY do
                            for z = scanMinZ, scanMaxZ do
                                if not breakRunning then break end
                                local block, _ = cworld.getBlock(x, y, z)
                                if block and block.id and block.quad ~= false then
                                    local target = Vector3.new(x * blocksize, y * blocksize, z * blocksize)
                                    lockedCF = CFrame.new(target + Vector3.new(0, 5, 0))
                                    getCam().CFrame = CFrame.lookAt(target + Vector3.new(0, 5, 8), target)
                                    breakRemote:FireServer(x, y, z, nil)
                                    anyBroken = true
                                    breakCount = breakCount + 1
                                    breakCountLabel:Set("Broken: " .. breakCount)
                                    breakYield = breakYield + 1
                                    if breakYield % 12 == 0 then
                                        task.wait()
                                        if not breakRunning then break end
                                    end
                                end
                            end
                            if not breakRunning then break end
                        end
                        if not breakRunning then break end
                    end

                    if not anyBroken then
                        idle = idle + 1
                        if idle >= idleLimit then
                            breakLabel:Set("Status: Done")
                            breakCountLabel:Set("Broken: " .. breakCount .. " (Done)")
                            breakRunning = false
                            break
                        end
                        task.wait(0.5)
                    else
                        idle = 0
                    end
                end
            end)
            if not ok then
                warn("AutoBuilder Break error:", err)
                breakRunning = false
            end
            stopFreecam()
            restoreState()
        end)
    end
})

breakTab:CreateButton({
    Name = "Stop Break",
    Callback = function()
        breakRunning = false
        breakLabel:Set("Status: Stopped")
        breakCountLabel:Set("Broken: " .. breakCount .. " (Done)")
    end
})

-- Place Tab
local placeTab = Window:CreateTab("Place", 6026568294) -- Plus icon
local placeLabel = placeTab:CreateLabel("Status: Idle")
local placeCountLabel = placeTab:CreateLabel("Placed: 0")
local placeInfoLabel = placeTab:CreateLabel("Item: none")

placeTab:CreateSlider({
    Name = "Slot",
    Range = {0, 8},
    Increment = 1,
    CurrentValue = placeSlot,
    Flag = "placeSlot",
    Callback = function(value)
        placeSlot = value
    end
})

placeTab:CreateSlider({
    Name = "Radius",
    Range = {2, 10},
    Increment = 1,
    CurrentValue = radius,
    Flag = "placeRadius",
    Callback = function(value)
        radius = value
    end
})

placeTab:CreateToggle({
    Name = "Override Mode",
    CurrentValue = placeOverrideMode,
    Flag = "placeOverrideMode",
    Callback = function(value)
        placeOverrideMode = value
    end
})

placeTab:CreateButton({
    Name = "Select Slot",
    Callback = function()
        changeSlot:InvokeServer(placeSlot)
        task.wait(0.1)
        if updatePlaceInfo() then
            placeInfoLabel:Set(string.format("Item: %s (ID: %d)", placeItemName, placeBlockId))
        else
            placeInfoLabel:Set("Item: none or invalid")
        end
    end
})

placeTab:CreateButton({
    Name = "Start Place",
    Callback = function()
        if placeRunning or breakRunning then return end
        if not placeBlockId then
            if not updatePlaceInfo() then
                placeLabel:Set("Status: No valid block in slot")
                return
            end
        end
        placeRunning = true
        placeLabel:Set("Status: Placing...")
        placeCount = 0
        placeCountLabel:Set("Placed: 0")
        saveState()
        startFreecam()
        changeSlot:InvokeServer(placeSlot)
        
        task.spawn(function()
            local ok, err = pcall(function()
                local char = players.LocalPlayer.Character
                if not char or not char:FindFirstChild("HumanoidRootPart") then
                    placeRunning = false
                    placeLabel:Set("Status: Dead/No Char")
                    return
                end
                local bx, by, bz = getBlockCoords(char.HumanoidRootPart.Position)
                local scanCount = 0
                local maxScans = 100
                local idle = 0

                while placeRunning do
                    scanCount = scanCount + 1
                    if scanCount > maxScans then
                        placeLabel:Set("Status: Max scans reached")
                        break
                    end

                    if not updatePlaceInfo() then
                        placeLabel:Set("Status: No blocks left")
                        placeRunning = false
                        break
                    end

                    local anyPlaced = false
                    local placeYield = 0

                    local scanMinX, scanMaxX, scanMinY, scanMaxY, scanMinZ, scanMaxZ
                    local useAreaScan = useAreaSelection and areaCorner1 and areaCorner2
                    if useAreaScan then
                        scanMinX = math.min(areaCorner1.bx, areaCorner2.bx)
                        scanMaxX = math.max(areaCorner1.bx, areaCorner2.bx)
                        scanMinY = math.min(areaCorner1.by, areaCorner2.by)
                        scanMaxY = math.max(areaCorner1.by, areaCorner2.by)
                        scanMinZ = math.min(areaCorner1.bz, areaCorner2.bz)
                        scanMaxZ = math.max(areaCorner1.bz, areaCorner2.bz)
                    else
                        scanMinX = bx - radius
                        scanMaxX = bx + radius
                        scanMinY = by - radius
                        scanMaxY = by + radius
                        scanMinZ = bz - radius
                        scanMaxZ = bz + radius
                    end

                    for x = scanMinX, scanMaxX do
                        for y = scanMinY, scanMaxY do
                            for z = scanMinZ, scanMaxZ do
                                if not placeRunning then break end
                                placeYield = placeYield + 1
                                if placeYield % 12 == 0 then
                                    task.wait()
                                    if not placeRunning then break end
                                end
                                local blockData, _ = cworld.getBlock(x, y, z)
                                local shouldPlace = false
                                if not blockData or not blockData.id then
                                    shouldPlace = true
                                elseif placeOverrideMode and blockData.id ~= placeBlockId then
                                    shouldPlace = true
                                end
                                if shouldPlace then
                                    local target = Vector3.new(x * blocksize, y * blocksize, z * blocksize)
                                    lockedCF = CFrame.new(target + Vector3.new(0, 5, 0))
                                    if placeBlockAt(x, y, z, placeOverrideMode, placeBlockId, placeSlot) then
                                        anyPlaced = true
                                        placeCount = placeCount + 1
                                        placeCountLabel:Set("Placed: " .. placeCount)
                                    end
                                end
                            end
                            if not placeRunning then break end
                        end
                        if not placeRunning then break end
                    end

                    if not anyPlaced then
                        idle = idle + 1
                        if idle >= idleLimit then
                            placeLabel:Set("Status: Done")
                            placeCountLabel:Set("Placed: " .. placeCount .. " (Done)")
                            placeRunning = false
                            break
                        end
                        task.wait(0.5)
                    else
                        idle = 0
                    end
                end
            end)
            if not ok then
                warn("AutoBuilder Place error:", err)
                placeRunning = false
            end
            stopFreecam()
            restoreState()
        end)
    end
})

placeTab:CreateButton({
    Name = "Stop Place",
    Callback = function()
        placeRunning = false
        placeLabel:Set("Status: Stopped")
        placeCountLabel:Set("Placed: " .. placeCount .. " (Done)")
    end
})

-- Structures Tab
local structTab = Window:CreateTab("Structures", 6031280880) -- Folder icon
local structListLabel = structTab:CreateLabel("No structures saved")
local structNameLabel = structTab:CreateLabel("Enter Structure Name:")
local structNameInput = ""
local structRotation = 0 -- 0,1,2,3 for 0°,90°,180°,270°
local previewEnabled = true
local previewFolder = Instance.new("Folder")
previewFolder.Name = "StructurePreview"
previewFolder.Parent = workspace

-- Function to update the structure list display
local function updateStructListDisplay()
    local structList = getStructureList()
    if #structList == 0 then
        structListLabel:Set("No structures saved")
    else
        structListLabel:Set("Saved: " .. table.concat(structList, ", "))
    end
end

-- Structure name input
structTab:CreateInput({
    Name = "Structure Name",
    PlaceholderText = "Enter structure name...",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        structNameInput = text
    end
})

-- Structure rotation
structTab:CreateSlider({
    Name = "Rotation",
    Range = {0, 3},
    Increment = 1,
    CurrentValue = structRotation,
    Flag = "structRotation",
    Callback = function(value)
        structRotation = value
    end
})

-- Save Structure button
structTab:CreateButton({
    Name = "Save Structure",
    Callback = function()
        if not structNameInput or structNameInput == "" then
            structListLabel:Set("Please enter a structure name")
            return
        end
        
        local success, message = saveStructure(structNameInput)
        if success then
            structListLabel:Set(message)
            -- Refresh structure list display (will be handled by updateStructListDisplay function)
            updateStructListDisplay()
        else
            structListLabel:Set(message)
        end
    end
})

-- Load Structure button (from player position)
structTab:CreateButton({
    Name = "Load Structure",
    Callback = function()
        if not structNameInput or structNameInput == "" then
            structListLabel:Set("Please enter a structure name")
            return
        end
        
        local success, message = loadStructureFromPlayerPos(structNameInput, false, structRotation) -- false = don't override existing blocks
        structListLabel:Set(message)
    end
})

-- Load & Override button (from player position)
structTab:CreateButton({
    Name = "Load & Override",
    Callback = function()
        if not structNameInput or structNameInput == "" then
            structListLabel:Set("Please enter a structure name")
            return
        end
        
        local success, message = loadStructureFromPlayerPos(structNameInput, true, structRotation) -- true = override existing blocks
        structListLabel:Set(message)
    end
})

-- Delete Structure button
structTab:CreateButton({
    Name = "Delete Structure",
    Callback = function()
        if not structNameInput or structNameInput == "" then
            structListLabel:Set("Please enter a structure name")
            return
        end
        
        local success, message = deleteStructure(structNameInput)
        if success then
            structListLabel:Set(message)
            -- Refresh structure list display
            updateStructListDisplay()
        else
            structListLabel:Set(message)
        end
    end
})

-- Refresh List button
structTab:CreateButton({
    Name = "Refresh List",
    Callback = function()
        updateStructListDisplay()
    end
    
});
structTab:CreateToggle({
    Name = "Enable Preview",
    CurrentValue = previewEnabled,
    Flag = "previewToggle",
    Callback = function(value)
        previewEnabled = value
        if not previewEnabled then
            -- Clear preview when disabled
            for _, child in ipairs(previewFolder:GetChildren()) do
                child:Destroy()
            end
        end
    end
})


local function updatePreview()
    -- Clear previous preview
    for _, child in ipairs(previewFolder:GetChildren()) do
        child:Destroy()
    end

    -- If preview disabled, return
    if not previewEnabled then
        return
    end

    -- If no structure name or structure not found, return
    if structNameInput == "" or not structures[structNameInput] then
        return
    end

    local structure = structures[structNameInput]
    local char = players.LocalPlayer.Character
    if not char or not char:FindFirstChild("HumanoidRootPart") then
        return
    end
    
    local originPos = char.HumanoidRootPart.Position
    local originX = math.floor(originPos.X / blocksize + 0.5)
    local originY = math.floor(originPos.Y / blocksize + 0.5) - 1
    local originZ = math.floor(originPos.Z / blocksize + 0.5)
    
    local width = structure.width
    local depth = structure.depth

    for _, block in ipairs(structure.blocks) do
        local x = block.x
        local y = block.y
        local z = block.z

        local rx, rz
        if structRotation == 0 then
            rx, rz = x, z
        elseif structRotation == 1 then
            rx, rz = z, width - 1 - x
        elseif structRotation == 2 then
            rx, rz = width - 1 - x, depth - 1 - z
        elseif structRotation == 3 then
            rx, rz = depth - 1 - z, x
        end

        local worldX = originX + rx
        local worldY = originY + y
        local worldZ = originZ + rz

        local part = Instance.new("Part")
        part.Size = Vector3.new(blocksize, blocksize, blocksize)
        part.Position = Vector3.new(worldX * blocksize, worldY * blocksize, worldZ * blocksize)
        part.Transparency = 0.5
        part.CanCollide = false
        part.Anchored = true
        part.Color = Color3.new(0, 1, 0) -- green
        part.Parent = previewFolder
    end
end

-- Update preview every 0.1 seconds
task.spawn(function()
    while true do
        updatePreview()
        task.wait(0.1)
    end
end)

-- Jail Tab
local jailTab = Window:CreateTab("Jail", 6026568294) -- Plus icon
local jailStatusLabel = jailTab:CreateLabel("Jail: Disabled")
local jailEnabled = false
local jailConn = nil
local jailTargetPlayer = "" -- Stores the username of the player to jail

-- Player selection for jail
jailTab:CreateLabel("Target Player (username or display name):")
local jailTargetInput = jailTab:CreateInput({
    Name = "Player Name",
    PlaceholderText = "Enter player name...",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        jailTargetPlayer = text
    end
})

-- Function to get the current block ID from the hotbar
local function getCurrentBlockId()
    if not placeSlot then return nil end
    local char = players.LocalPlayer.Character
    if not char then return nil end
    local inv = char:FindFirstChild("Inventory")
    if not inv then return nil end
    local slot = inv:FindFirstChild("Slot" .. placeSlot)
    if not slot then return nil end
    local data = game:GetService("HttpService"):JSONDecode(slot.Value)
    if data.count <= 0 or data.name == "" then return nil end
    local itemDef = ids.ByName.Items[data.name]
    if not itemDef then return nil end
    local blockName = itemDef.block or data.name
    local blockDef = ids.ByName.Blocks[blockName]
    return blockDef and blockDef.id
end

local function startJail()
    if jailConn then return end
    jailConn = rs.RenderStepped:Connect(function()
        if not jailEnabled then
            stopJail()
            return
        end
        
        -- Find target player
        local targetPlayer = nil
        if jailTargetPlayer ~= "" then
            -- Search for player by username or display name
            for _, player in ipairs(players:GetPlayers()) do
                if string.lower(player.Name) == string.lower(jailTargetPlayer) or 
                   (player.DisplayName and string.lower(player.DisplayName) == string.lower(jailTargetPlayer)) then
                    targetPlayer = player
                    break
                end
                -- Partial match (substring)
                if string.find(string.lower(player.Name), string.lower(jailTargetPlayer)) or 
                   (player.DisplayName and string.find(string.lower(player.DisplayName), string.lower(jailTargetPlayer))) then
                    targetPlayer = player
                    break
                end
            end
        end
        
        -- If no target specified or not found, use local player
        if not targetPlayer then
            targetPlayer = players.LocalPlayer
        end
        
        local char = targetPlayer.Character
        if not char or not char:FindFirstChild("HumanoidRootPart") then
            jailStatusLabel:Set("Jail: Target player not found or invalid")
            return
        end
        
        local root = char.HumanoidRootPart
        local originPos = root.Position
        local originX = math.floor(originPos.X / blocksize + 0.5)
        local originY = math.floor(originPos.Y / blocksize + 0.5) - 1
        local originZ = math.floor(originPos.Z / blocksize + 0.5)

        local blockId = getCurrentBlockId()
        if not blockId then
            jailStatusLabel:Set("Jail: No block selected")
            return
        end

        -- Check which positions need jail blocks and place only those
        local blocksPlaced = 0
        -- Build the cage: 3x3x4
        for y = 0, 3 do
            for x = -1, 1 do
                for z = -1, 1 do
                    if (y < 2) and (x == 0) and (z == 0) then
                        -- skip the center hollow part
                    else
                        -- Check if we need to place a jail block at this position
                        local blockData, _ = cworld.getBlock(originX + x, originY + y, originZ + z)
                        -- Place if no block there or if it's not our jail block
                        if not blockData or not blockData.id or blockData.id ~= blockId then
                            -- Get slot for this block ID
                            local slot = getSlotWithBlockId(blockId)
                            
                            -- Enable freecam during placement
                            saveState()
                            startFreecam()
                            
                            -- We want to place the block at (originX+x, originY+y, originZ+z)
                            -- We'll use placeBlockAt with override=true to ensure we place the jail block.
                            if placeBlockAt(originX + x, originY + y, originZ + z, true, blockId, slot) then
                                blocksPlaced = blocksPlaced + 1
                            end
                            
                            -- Disable freecam after placement
                            stopFreecam()
                            restoreState()
                        end
                    end
                end
            end
        end
        
        if blocksPlaced > 0 then
            jailStatusLabel:Set(string.format("Jail: Enabled (%d blocks placed)", blocksPlaced))
        else
            jailStatusLabel:Set("Jail: Enabled (all blocks intact)")
        end
    end)
end

local function stopJail()
    if jailConn then
        jailConn:Disconnect()
        jailConn = nil
    end
    jailStatusLabel:Set("Jail: Disabled")
end

local jailToggle = jailTab:CreateToggle({
    Name = "Enable Jail",
    CurrentValue = false,
    Flag = "jailToggle",
    Callback = function(value)
        jailEnabled = value
        if value then
            startJail()
        else
            stopJail()
        end
    end
})

-- Initialize
Rayfield:Notify({
    Title = "AutoBuilder Loaded",
    Content = "The AutoBuilder script has been successfully loaded!\nUse the tabs to control breaking, placing, freecam, area selection, structure management, and jail.",
    Duration = 5,
    Image = 4483362458,
})
