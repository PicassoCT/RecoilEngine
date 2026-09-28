-- This file is part of the Spring engine (GPL v2 or later), see LICENSE.html
-- Opt-in, unsynced visual scenes. No simulation objects or mesh copies.
local Geometry = VFS.Include("LuaModelWindows/Surface.lua")
local Scene = VFS.Include("LuaModelWindows/Scene.lua")
local Renderer = VFS.Include("LuaModelWindows/Renderer.lua")
local ModelWindows = {}
ModelWindows.__index = ModelWindows

local function get(self, kind, id)
	assert(not self.closed, "ModelWindows is shut down")
	return assert(self[kind][id], "unknown " .. kind .. " handle")
end
local function writable(self)
	assert(not self.closed and not self.drawing, "cannot mutate a closed or drawing ModelWindows manager")
end
local function insert(self, kind, value)
	self.nextID = self.nextID + 1
	self[kind][self.nextID] = value
	return self.nextID
end

function ModelWindows.New(options)
	assert(gl.ModelShape and Spring.PreloadModel, "engine lacks runtime model window APIs")
	options = options or {}
	local config = {
		maxDistance = Geometry.Number(options.maxDistance or 2000),
		minPixels = Geometry.Number(options.minPixels or 3),
		maxGroups = Geometry.Number(options.maxGroups or 64),
		maxModelDraws = Geometry.Number(options.maxModelDraws or 512),
		stencilBit = Geometry.Number(options.stencilBit or 128),
	}
	assert(config.maxDistance > 0 and config.minPixels >= 0, "invalid culling limits")
	assert(config.maxGroups >= 0 and config.maxGroups % 1 == 0, "maxGroups must be a nonnegative integer")
	assert(config.maxModelDraws >= 0 and config.maxModelDraws % 1 == 0, "maxModelDraws must be a nonnegative integer")
	local bit = config.stencilBit
	while bit > 1 and bit % 2 == 0 do bit = bit / 2 end
	assert(bit == 1 and config.stencilBit <= 128, "stencilBit must be one bit in an 8-bit buffer")
	return setmetatable({scenes={}, surfaces={}, attachments={}, preloaded={}, nextID=0,
		options=config, renderer=Renderer.New(config)}, ModelWindows)
end

function ModelWindows:CreateScene(def)
	writable(self)
	return insert(self, "scenes", Scene.New(def))
end

function ModelWindows:AddModel(sceneID, path, transform)
	writable(self)
	local scene = get(self, "scenes", sceneID)
	assert(type(path) == "string" and path ~= "", "expected a model path")
	path = path:lower():gsub("\\", "/")
	if path:sub(1,10) ~= "objects3d/" then path = "objects3d/" .. path end
	assert(VFS.FileExists(path), "model does not exist: " .. path)
	local id = scene:Add(path, transform)
	if not self.preloaded[path] then
		local ok, err = pcall(Spring.PreloadModel, path)
		if not ok then scene:Remove(id); error(err, 0) end
		self.preloaded[path] = true
	end
	return id
end

function ModelWindows:UpdateModel(sceneID, modelID, transform)
	writable(self)
	get(self, "scenes", sceneID):Update(modelID, transform)
end

function ModelWindows:RemoveModel(sceneID, modelID)
	writable(self)
	get(self, "scenes", sceneID):Remove(modelID)
end

function ModelWindows:CreateSurface(def)
	writable(self)
	return insert(self, "surfaces", Geometry.New(def))
end

local function attach(self, kind, objectID, piece, surfaceID, sceneID)
	writable(self)
	get(self, "surfaces", surfaceID)
	get(self, "scenes", sceneID)
	local map = (kind == "unit" and Spring.GetUnitPieceMap or Spring.GetFeaturePieceMap)(objectID)
	assert(map, "object is unavailable")
	if type(piece) == "string" then piece = assert(map[piece], "unknown piece name") end
	if piece ~= nil then
		local found = false
		for _, id in pairs(map) do if id == piece then found = true; break end end
		assert(found, "unknown piece index (Lua indices start at one)")
	end
	return insert(self, "attachments", {kind=kind, objectID=objectID, piece=piece,
		surfaceID=surfaceID, sceneID=sceneID, enabled=true})
end

function ModelWindows:AttachUnit(unitID, piece, surfaceID, sceneID)
	return attach(self, "unit", unitID, piece, surfaceID, sceneID)
end
function ModelWindows:AttachFeature(featureID, piece, surfaceID, sceneID)
	return attach(self, "feature", featureID, piece, surfaceID, sceneID)
end
function ModelWindows:SetScene(attachmentID, sceneID)
	writable(self)
	get(self, "scenes", sceneID)
	get(self, "attachments", attachmentID).sceneID = sceneID
end
function ModelWindows:SetEnabled(attachmentID, enabled)
	writable(self)
	assert(type(enabled) == "boolean", "enabled must be boolean")
	get(self, "attachments", attachmentID).enabled = enabled
end
function ModelWindows:Detach(attachmentID)
	writable(self)
	get(self, "attachments", attachmentID)
	self.attachments[attachmentID] = nil
end

function ModelWindows:RemoveObject(kind, objectID)
	writable(self)
	assert(kind == "unit" or kind == "feature", "expected unit or feature")
	for id, a in pairs(self.attachments) do
		if a.kind == kind and a.objectID == objectID then self.attachments[id] = nil end
	end
end

local function delete(self, kind, field, id)
	writable(self)
	local item = get(self, kind, id)
	for aid, a in pairs(self.attachments) do
		if a[field] == id then self.attachments[aid] = nil end
	end
	if item.list then gl.DeleteList(item.list) end
	self[kind][id] = nil
end
function ModelWindows:DeleteScene(id) delete(self, "scenes", "sceneID", id) end
function ModelWindows:DeleteSurface(id) delete(self, "surfaces", "surfaceID", id) end

local function apply(a, surface)
	if a.kind == "unit" then
		gl.UnitMultMatrix(a.objectID)
		if a.piece then gl.UnitPieceMultMatrix(a.objectID, a.piece) end
	else
		gl.FeatureMultMatrix(a.objectID)
		if a.piece then gl.FeaturePieceMultMatrix(a.objectID, a.piece) end
	end
	gl.MultMatrix(surface.matrix)
end

local function visible(a)
	if not a.enabled then return false end
	local flag
	if a.kind == "unit" then
		if Spring.GetUnitNoDraw(a.objectID) or Spring.GetUnitIsCloaked(a.objectID) then return false end
		if not Spring.IsUnitVisible(a.objectID, nil, true) then return false end
		flag = Spring.GetUnitDrawFlag(a.objectID)
	else
		if Spring.GetFeatureNoDraw(a.objectID) then return false end
		flag = Spring.GetFeatureDrawFlag(a.objectID)
	end
	return flag ~= nil and flag % 2 == 1 -- SO_OPAQUE_FLAG, main opaque pass only
end

local function drawScope(self, body)
	writable(self)
	self.drawing = true
	local matrixMode = gl.GetNumber(0x0BA0) -- GL_MATRIX_MODE
	gl.MatrixMode(GL.MODELVIEW)
	local ok, result = pcall(body)
	gl.MatrixMode(matrixMode)
	self.drawing = false
	if not ok then error(result, 0) end
	return result
end

-- Call once from DrawWorldPostUnit. Closest eligible groups win the budget.
function ModelWindows:Draw()
	return drawScope(self, function()
		local candidates = {}
		for id, a in pairs(self.attachments) do
			if visible(a) then
				local surface = self.surfaces[a.surfaceID]
				gl.PushPopMatrix(GL.MODELVIEW, function()
					apply(a, surface)
					local eligible, distance = self.renderer:Visible(surface)
					if eligible then candidates[#candidates+1] = {id=id, distance=distance} end
				end)
			end
		end
		table.sort(candidates, function(a,b)
			if a.distance == b.distance then return a.id < b.id end
			return a.distance < b.distance
		end)
		local count, modelDraws = 0, 0
		for _, candidate in ipairs(candidates) do
			if count >= self.options.maxGroups then break end
			local a = self.attachments[candidate.id]
			local surface, scene = self.surfaces[a.surfaceID], self.scenes[a.sceneID]
			if modelDraws + scene.visibleCount <= self.options.maxModelDraws then
				gl.PushPopMatrix(GL.MODELVIEW, function()
					apply(a, surface)
					self.renderer:Draw(surface, scene)
				end)
				count = count + 1
				modelDraws = modelDraws + scene.visibleCount
			end
		end
		return count
	end)
end

-- Generic models: caller supplies model/piece matrix and visibility policy.
-- This explicit path is culled but does not consume the attachment draw budget.
function ModelWindows:DrawSurface(surfaceID, sceneID)
	local surface, scene = get(self, "surfaces", surfaceID), get(self, "scenes", sceneID)
	return drawScope(self, function()
		local drawn = false
		gl.PushPopMatrix(GL.MODELVIEW, function()
			gl.MultMatrix(surface.matrix)
			if self.renderer:Visible(surface) then self.renderer:Draw(surface, scene); drawn = true end
		end)
		return drawn
	end)
end

function ModelWindows:Shutdown()
	if self.closed then return end
	writable(self)
	for _, surface in pairs(self.surfaces) do if surface.list then gl.DeleteList(surface.list) end end
	self.renderer:Shutdown()
	self.scenes, self.surfaces, self.attachments, self.preloaded = {}, {}, {}, {}
	self.closed = true
end

return ModelWindows
