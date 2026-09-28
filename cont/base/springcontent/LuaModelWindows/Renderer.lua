-- This file is part of the Spring engine (GPL v2 or later), see LICENSE.html
-- Stencil is scratch space; exterior depth is restored to the aperture plane.
local Renderer = {}
Renderer.__index = Renderer
local unpack = unpack or table.unpack
local STENCIL_BITS, STENCIL_TEST, VIEWPORT = 0x0D57, 0x0B90, 0x0BA2

local function shader(name, uniforms)
	local prefix = "shaders/GLSL/ModelWindow" .. name
	local result = gl.CreateShader({
		vertex = assert(VFS.LoadFile(prefix .. "Vert.glsl")),
		fragment = assert(VFS.LoadFile(prefix .. "Frag.glsl")),
		uniformInt = uniforms,
	})
	assert(result and result ~= 0, "ModelWindows shader: " .. tostring(gl.GetShaderLog()))
	return result
end

function Renderer.New(options)
	return setmetatable({options = options}, Renderer)
end

function Renderer:Initialize()
	if self.mask then return end
	assert(gl.GetNumber(STENCIL_BITS) >= 8, "ModelWindows requires an 8-bit stencil buffer")
	local mask = shader("Mask", {farDepth = 0})
	local ok, scene = pcall(shader, "Scene", {diffuseTex = 0, extraTex = 1})
	if not ok then gl.DeleteShader(mask); error(scene, 0) end
	self.mask, self.scene = mask, scene
	self.farDepth = gl.GetUniformLocation(mask, "farDepth")
	self.background = gl.GetUniformLocation(mask, "background")
	self.teamColor = gl.GetUniformLocation(scene, "teamColor")
	self.ambient = gl.GetUniformLocation(scene, "ambient")
end

function Renderer:Shutdown()
	if self.mask then gl.DeleteShader(self.mask); gl.DeleteShader(self.scene) end
	self.mask, self.scene = nil, nil
end

-- Called with the surface transform applied. Conservative bound, no GPU query.
function Renderer:Visible(surface)
	local m = {gl.GetMatrixData(GL.MODELVIEW)}
	local x, y, z = m[13], m[14], m[15]
	local distance = math.sqrt(x*x + y*y + z*z)
	local radius = surface.radius * math.sqrt(m[1]^2+m[2]^2+m[3]^2+m[5]^2+m[6]^2+m[7]^2)
	if distance - radius > self.options.maxDistance then return false end
	local nx, ny, nz = m[2]*m[7]-m[3]*m[6], m[3]*m[5]-m[1]*m[7], m[1]*m[6]-m[2]*m[5]
	if nx*x + ny*y + nz*z >= 0 then return false end
	local p = {gl.GetMatrixData(GL.PROJECTION)}
	-- Test a bounding sphere against each homogeneous clip plane.
	for row = 1, 3 do
		for sign = -1, 1, 2 do
			local a, b, c, d = p[4]+sign*p[row], p[8]+sign*p[row+4], p[12]+sign*p[row+8], p[16]+sign*p[row+12]
			if a*x+b*y+c*z+d < -radius*math.sqrt(a*a+b*b+c*c) then return false end
		end
	end
	local _, _, _, height = gl.GetNumber(VIEWPORT, 4)
	-- Avoid size rejection at/inside the bounding sphere (near-plane crossings).
	local w = p[4]*x+p[8]*y+p[12]*z+p[16]
	if w > radius and height*math.abs(p[6])*radius/(w-radius) < self.options.minPixels then return false end
	return true, distance
end

local function modelTransform(item)
	gl.Translate(unpack(item.position))
	gl.Rotate(item.rotation[1], 1,0,0)
	gl.Rotate(item.rotation[2], 0,1,0)
	gl.Rotate(item.rotation[3], 0,0,1)
	gl.Scale(unpack(item.scale))
	gl.ModelShape(item.path)
end

function Renderer:DrawScene(scene)
	gl.Uniform(self.teamColor, unpack(scene.teamColor))
	gl.Uniform(self.ambient, scene.ambient)
	for _, batch in ipairs(scene:GetBatches()) do
		gl.ModelShapeTextures(batch.path, true)
		local ok, err = pcall(function()
			gl.Culling(false)
			for _, item in ipairs(batch.models) do
				if item.visible then gl.PushPopMatrix(modelTransform, item) end
			end
		end)
		gl.ModelShapeTextures(batch.path, false)
		if not ok then error(err, 0) end
	end
end

function Renderer:Draw(surface, scene)
	self:Initialize()
	assert(gl.GetNumber(STENCIL_TEST) == 0, "ModelWindows cannot nest inside an active stencil pass")
	if not surface.list then
		surface.list = gl.CreateList(function()
			gl.BeginEnd(GL.TRIANGLES, function()
				for _, v in ipairs(surface.vertices) do gl.Vertex(v[1],v[2],0) end
			end)
		end)
		assert(surface.list and surface.list ~= 0, "failed to create aperture geometry")
	end
	local bit = self.options.stencilBit
	gl.PushAttrib(GL.ALL_ATTRIB_BITS)
	local touched = false
	local ok, err = pcall(function()
		gl.Blending(false)
		gl.AlphaTest(false)
		gl.Culling(false)
		gl.ClipPlane(1, false)
		gl.ClipPlane(2, false)
		gl.StencilTest(true)
		gl.StencilMask(bit)
		gl.ColorMask(false,false,false,false)
		gl.DepthMask(false)
		gl.DepthTest(GL.ALWAYS)
		gl.PolygonOffset(-1,-1)
		gl.ActiveShader(self.mask, function()
			gl.UniformInt(self.farDepth, 0)
			-- Clear only our bit under the aperture, preserving other users' bits.
			gl.StencilFunc(GL.ALWAYS, 0, bit)
			gl.StencilOp(GL.ZERO,GL.ZERO,GL.ZERO)
			gl.CallList(surface.list)
			gl.DepthTest(GL.LEQUAL)
			gl.StencilFunc(GL.ALWAYS, bit, bit)
			gl.StencilOp(GL.KEEP,GL.KEEP,GL.REPLACE)
			gl.CallList(surface.list)
			touched = true
			gl.StencilMask(0)
			gl.StencilFunc(GL.EQUAL, bit, bit)
			gl.StencilOp(GL.KEEP,GL.KEEP,GL.KEEP)
			gl.ColorMask(true,true,true,true)
			gl.DepthMask(true)
			gl.DepthTest(GL.ALWAYS)
			gl.UniformInt(self.farDepth, 1)
			gl.Uniform(self.background, unpack(scene.background))
			gl.CallList(surface.list)
		end)
		gl.PolygonOffset(false)
		gl.DepthTest(GL.LEQUAL)
		-- Scene extends into negative surface Z. Never protrude through the hull.
		gl.ClipPlane(1, 0,0,-1,-0.001)
		gl.ActiveShader(self.scene, function() self:DrawScene(scene) end)
	end)
	-- Restore aperture depth even if scene rendering failed. Do not expose
	-- interior depth to the main world's water, particles or later windows.
	local restored, restoreError = pcall(function()
		if not touched then return end
		gl.ClipPlane(1, false)
		gl.Culling(false)
		gl.ColorMask(false,false,false,false)
		gl.DepthMask(true)
		gl.DepthTest(GL.ALWAYS)
		gl.PolygonOffset(-1,-1)
		gl.StencilMask(bit)
		gl.StencilFunc(GL.EQUAL, bit, bit)
		gl.StencilOp(GL.KEEP,GL.KEEP,GL.ZERO)
		gl.ActiveShader(self.mask, function()
			gl.UniformInt(self.farDepth, 0)
			gl.CallList(surface.list)
		end)
	end)
	gl.PopAttrib()
	if not ok then error(err, 0) end
	if not restored then error(restoreError, 0) end
end

return Renderer
