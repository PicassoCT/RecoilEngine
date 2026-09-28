-- This file is part of the Spring engine (GPL v2 or later), see LICENSE.html
-- Include in an unsynced gadget/widget. Forward Update, DrawWorldPostUnit,
-- UnitDestroyed and Shutdown to this object. See ../model-windows.md.
local ModelWindows = VFS.Include("LuaModelWindows/ModelWindows.lua")
local Example = {}
Example.__index = Example

-- Surface is authored against your hull piece. The two model paths must exist
-- in your game archive; no extra simulation units/features are created.
function Example.New(unitID, piece, surfaceDef, roomPath, propPath)
	local windows = ModelWindows.New({maxGroups=32, maxModelDraws=256})
	local self = setmetatable({windows=windows, unitID=unitID, time=0}, Example)
	local ok, err = pcall(function()
		self.scene = windows:CreateScene({ambient=0.65})
		windows:AddModel(self.scene, roomPath)
		self.prop = windows:AddModel(self.scene, propPath, {position={0,0,-8}})
		self.surface = windows:CreateSurface(surfaceDef)
		self.attachment = windows:AttachUnit(unitID, piece, self.surface, self.scene)
	end)
	if not ok then windows:Shutdown(); error(err, 0) end
	return self
end

function Example:Update(dt)
	if self.destroyed then return end
	self.time = self.time + dt
	self.windows:UpdateModel(self.scene, self.prop, {
		position={math.sin(self.time)*3, 0, -8},
		rotation={0, self.time*30, 0},
	})
end

-- Call any time outside drawing, including with assets never previously used.
-- Surface stays fixed; only the miniature scene changes.
function Example:ReplaceScene(roomPath, propPath)
	assert(not self.destroyed, "host was destroyed")
	local scene = self.windows:CreateScene({ambient=0.4,background={0.04,0.01,0.01}})
	local ok, prop = pcall(function()
		self.windows:AddModel(scene, roomPath)
		return self.windows:AddModel(scene, propPath, {position={0,0,-8}})
	end)
	if not ok then self.windows:DeleteScene(scene); error(prop, 0) end
	self.windows:SetScene(self.attachment, scene)
	self.windows:DeleteScene(self.scene)
	self.scene, self.prop = scene, prop
end

function Example:DrawWorldPostUnit()
	if not self.destroyed then self.windows:Draw() end
end

function Example:UnitDestroyed(unitID)
	if unitID ~= self.unitID then return end
	self.windows:RemoveObject("unit", unitID)
	self.destroyed = true
end

function Example:Shutdown()
	self.windows:Shutdown()
	self.destroyed = true
end

return Example
