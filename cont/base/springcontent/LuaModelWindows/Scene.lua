-- This file is part of the Spring engine (GPL v2 or later), see LICENSE.html
local Geometry = VFS.Include("LuaModelWindows/Surface.lua")
local Scene = {}
Scene.__index = Scene

local function transform(def, old)
	def, old = def or {}, old or {}
	local scale = def.scale or old.scale or {1,1,1}
	if type(scale) == "number" then scale = {scale,scale,scale} end
	scale = Geometry.Vector(scale)
	for i = 1, 3 do assert(scale[i] > 0, "scale must be positive") end
	local visible = def.visible
	if visible == nil then visible = old.visible ~= false end
	assert(type(visible) == "boolean", "visible must be boolean")
	return {
		position = Geometry.Vector(def.position, old.position or {0,0,0}),
		rotation = Geometry.Vector(def.rotation, old.rotation or {0,0,0}),
		scale = scale, visible = visible,
	}
end

function Scene.New(def)
	def = def or {}
	return setmetatable({
		models = {}, nextID = 0, batches = {}, dirty = false, visibleCount = 0,
		background = Geometry.Vector(def.background, {0.015,0.02,0.03}, 3),
		teamColor = Geometry.Vector(def.teamColor, {1,1,1,1}, 4),
		ambient = Geometry.Number(def.ambient or 0.5, "ambient"),
	}, Scene)
end

function Scene:Add(path, def)
	local item = transform(def)
	item.path = path
	self.nextID = self.nextID + 1
	self.models[self.nextID] = item
	if item.visible then self.visibleCount = self.visibleCount + 1 end
	self.dirty = true
	return self.nextID
end

function Scene:Update(id, def)
	local old = assert(self.models[id], "unknown model instance")
	local item = transform(def, old)
	self.visibleCount = self.visibleCount + (item.visible and 1 or 0) - (old.visible and 1 or 0)
	-- Preserve identity: cached asset batches hold these same objects.
	old.position, old.rotation, old.scale, old.visible = item.position, item.rotation, item.scale, item.visible
end

function Scene:Remove(id)
	local item = assert(self.models[id], "unknown model instance")
	if item.visible then self.visibleCount = self.visibleCount - 1 end
	self.models[id] = nil
	self.dirty = true
end

function Scene:GetBatches()
	if not self.dirty then return self.batches end
	local byPath, paths = {}, {}
	local ids = {}
	for id in pairs(self.models) do ids[#ids+1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local item = self.models[id]
		if not byPath[item.path] then
			byPath[item.path] = {path = item.path, models = {}}
			paths[#paths+1] = item.path
		end
		local models = byPath[item.path].models
		models[#models+1] = item
	end
	table.sort(paths)
	self.batches = {}
	for _, path in ipairs(paths) do self.batches[#self.batches+1] = byPath[path] end
	self.dirty = false
	return self.batches
end

return Scene
