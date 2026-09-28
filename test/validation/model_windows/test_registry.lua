-- This file is part of the Spring engine (GPL v2 or later), see LICENSE.html
-- Run from the repo root: lua test/validation/model_windows/test_registry.lua
local root = "cont/base/springcontent/"
local preloads, deleted = {}, {}
VFS = {
	Include = function(path) return dofile(root .. path) end,
	FileExists = function(path) return path ~= "objects3d/missing.s3o" end,
}
Spring = {
	PreloadModel = function(path) preloads[path] = (preloads[path] or 0) + 1 end,
	GetUnitPieceMap = function(id) if id ~= 999 then return {hull=1, turret=2} end end,
	GetFeaturePieceMap = function() return {root=1} end,
}
gl = {ModelShape=function() end, DeleteList=function(id) deleted[id]=true end}
GL = {MODELVIEW=5888}
local function fails(fn) assert(not pcall(fn), "expected rejection") end
local function near(a,b) assert(math.abs(a-b)<1e-7, tostring(a).." ~= "..tostring(b)) end
local Geometry = VFS.Include("LuaModelWindows/Surface.lua")
local Windows = VFS.Include("LuaModelWindows/ModelWindows.lua")

local surfaceDef = {position={4,5,6}, normal={2,0,0}, up={1,3,0}, width=4,height=2}
local s = Geometry.New(surfaceDef)
near(s.matrix[1],0); near(s.matrix[3],-1)
near(s.matrix[6],1); near(s.matrix[9],1)
near(s.matrix[13],4); near(s.radius,math.sqrt(5))
assert(#s.vertices == 6)
surfaceDef.position[1] = 99
assert(s.matrix[13] == 4, "surface must own a snapshot")
fails(function() Geometry.New({width=0,height=2}) end)
fails(function() Geometry.New({width=2,height=2,normal={0,1,0}}) end)
fails(function() Geometry.New({width=2,height=2,position={0/0,0,0}}) end)
fails(function() Geometry.New({polygons={{{0,0},{0,1},{1,1},{1,0}}}}) end)
fails(function() Geometry.New({polygons={{{0,0},{2,0},{1,0.2},{2,2},{0,2}}}}) end)
fails(function() Geometry.New({polygons={{{0,0},{2,2},{0,2},{2,0}}}}) end)
assert(#Geometry.New({polygons={{{0,0},{1,0},{0,1}},{{2,0},{3,0},{2,1}}}}).vertices == 6)

local w = Windows.New()
local scene = w:CreateScene()
local other = w:CreateScene()
local surf = w:CreateSurface({width=2,height=3})
local a = w:AttachUnit(10,"hull",surf,scene)
local b = w:AttachUnit(11,2,surf,scene)
local f = w:AttachFeature(12,nil,surf,other)
fails(function() w:AttachUnit(999,nil,surf,scene) end)
fails(function() w:AttachUnit(10,"absent",surf,scene) end)
fails(function() w:AttachUnit(10,0,surf,scene) end)
fails(function() w:AddModel(scene,"missing.s3o") end)
fails(function() w:AddModel(scene,"room.s3o",{scale=0}) end)
local furniture = w:AddModel(scene,"ROOM.s3o",{position={0,0,-4}})
local actor = w:AddModel(scene,"objects3d/room.s3o",{position={0,0,-2}})
w:AddModel(other,"room.s3o")
assert(preloads["objects3d/room.s3o"] == 1, "preload once across all scenes")
assert(#w.scenes[scene]:GetBatches() == 1, "shared asset batch")
local batch = w.scenes[scene]:GetBatches()[1]
w:UpdateModel(scene,actor,{position={1,2,-3},visible=false})
assert(batch.models[2].position[1] == 1 and not batch.models[2].visible, "updates reach cached batch")
assert(w.attachments[a].sceneID == w.attachments[b].sceneID)
fails(function() w:UpdateModel(scene,actor,{position={math.huge,0,0}}) end)
assert(batch.models[2].position[1] == 1, "invalid updates are atomic")
w:RemoveModel(scene,furniture)
assert(#w.scenes[scene]:GetBatches()[1].models == 1)
local newActor = w:AddModel(scene,"actor.s3o")
assert(newActor > actor, "handles are not recycled")
w:SetScene(a,other)
w:SetEnabled(a,false)
assert(not w.attachments[a].enabled)
w:DeleteScene(scene)
assert(not w.attachments[b] and w.attachments[a] and w.attachments[f])
fails(function() w:UpdateModel(scene,actor,{}) end)
w:RemoveObject("unit",10)
assert(not w.attachments[a] and w.attachments[f])
w.surfaces[surf].list = 42
w:DeleteSurface(surf)
assert(not w.attachments[f] and deleted[42])
fails(function() w:DrawSurface(surf,other) end)
w:Shutdown(); w:Shutdown()
fails(function() w:CreateScene() end)
fails(function() Windows.New({stencilBit=3}) end)
fails(function() Windows.New({maxGroups=0.5}) end)
print("ModelWindows registry/geometry: passed")

-- Attachment draw admission: hidden/opaque flags, nearest-first ordering, both
-- budgets and object-kind transforms. GPU work is covered by test_render.py.
local activeObject, mode = nil, 1234
local drawn = {}
gl.GetNumber = function() return mode end
gl.MatrixMode = function(value) mode=value end
gl.PushPopMatrix = function(_, fn) fn() end
gl.UnitMultMatrix = function(id) activeObject=id end
gl.FeatureMultMatrix = gl.UnitMultMatrix
gl.UnitPieceMultMatrix = function() end
gl.FeaturePieceMultMatrix = function() end
gl.MultMatrix = function() end
Spring.GetUnitNoDraw = function(id) return id == 13 end
Spring.GetUnitIsCloaked = function(id) return id == 14 end
Spring.IsUnitVisible = function(id) return id ~= 15 end
Spring.GetUnitDrawFlag = function(id) return id == 16 and 2 or 1 end
Spring.GetFeatureNoDraw = function() return false end
Spring.GetFeatureDrawFlag = function() return 1 end
w = Windows.New({maxGroups=2,maxModelDraws=2})
local small, large = w:CreateScene(), w:CreateScene()
w:AddModel(small,"room.s3o")
for i=1,3 do w:AddModel(large,"room.s3o") end
surf = w:CreateSurface({width=1,height=1})
for _,id in ipairs({10,11,13,14,15,16}) do w:AttachUnit(id,nil,surf,small) end
w:AttachUnit(1,nil,surf,large) -- nearest but too expensive; must not starve others
w:AttachFeature(20,nil,surf,small)
w.renderer = {
	Visible = function() return true,activeObject end,
	Draw = function() drawn[#drawn+1]=activeObject end,
	Shutdown = function() end,
}
assert(w:Draw() == 2 and drawn[1] == 10 and drawn[2] == 11)
assert(mode == 1234, "restore caller matrix mode")
w:UpdateModel(large,1,{visible=false})
assert(w.scenes[large].visibleCount == 2)
drawn = {}
assert(w:Draw() == 1 and drawn[1] == 1, "visible instance count controls model budget")
w:RemoveModel(large,2)
assert(w.scenes[large].visibleCount == 1)
w.renderer.Draw = function() error("injected failure") end
fails(function() w:Draw() end)
assert(not w.drawing and mode == 1234, "draw lock/matrix mode survive exceptions")
w:Shutdown()
print("ModelWindows attachment visibility/budgets: passed")
