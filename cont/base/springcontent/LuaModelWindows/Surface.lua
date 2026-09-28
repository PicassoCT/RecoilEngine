-- This file is part of the Spring engine (GPL v2 or later), see LICENSE.html
-- Pure geometry and validation, independent of GL and the scene registry.
local Surface = {}

function Surface.Number(value, name)
	assert(type(value) == "number" and value == value and math.abs(value) < math.huge,
		(name or "value") .. " must be finite")
	return value
end

function Surface.Vector(value, default, size)
	value = value or default
	assert(type(value) == "table", "expected a vector")
	local copy = {}
	for i = 1, size or 3 do copy[i] = Surface.Number(value[i], "vector component") end
	return copy
end

local function dot(a, b) return a[1]*b[1] + a[2]*b[2] + a[3]*b[3] end
local function cross(a, b)
	return {a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1]}
end
local function normal(v)
	local length = math.sqrt(dot(v, v))
	assert(length > 1e-8, "normal and up must be nonzero and not parallel")
	return {v[1]/length, v[2]/length, v[3]/length}
end

function Surface.New(def)
	assert(type(def) == "table", "expected a surface definition")
	local p = Surface.Vector(def.position, {0,0,0})
	local n = normal(Surface.Vector(def.normal, {0,0,1}))
	local right = normal(cross(Surface.Vector(def.up, {0,1,0}), n))
	local up = cross(n, right)
	local polygons = def.polygons
	if not polygons then
		local w, h = Surface.Number(def.width, "width"), Surface.Number(def.height, "height")
		assert(w > 0 and h > 0, "width and height must be positive")
		polygons = {{{-w/2,-h/2}, {w/2,-h/2}, {w/2,h/2}, {-w/2,h/2}}}
	end
	assert(type(polygons) == "table" and #polygons > 0, "expected aperture polygons")
	local vertices, radius = {}, 0
	for _, polygon in ipairs(polygons) do
		assert(type(polygon) == "table" and #polygon >= 3, "polygon needs at least three vertices")
		local points = {}
		for i, point in ipairs(polygon) do
			points[i] = Surface.Vector(point, nil, 2)
			radius = math.max(radius, math.sqrt(points[i][1]^2 + points[i][2]^2))
		end
		-- Every other vertex must lie strictly left of every edge. This also
		-- rejects self-intersections, repeated vertices and concave input.
		for i, a in ipairs(points) do
			local j = i % #points + 1
			local b = points[j]
			for k, c in ipairs(points) do
				if k ~= i and k ~= j then
					assert((b[1]-a[1])*(c[2]-a[2]) - (b[2]-a[2])*(c[1]-a[1]) > 1e-8,
						"polygons must be strictly convex and counter-clockwise")
				end
			end
		end
		for i = 2, #points-1 do
			vertices[#vertices+1] = points[1]
			vertices[#vertices+1] = points[i]
			vertices[#vertices+1] = points[i+1]
		end
	end
	return {
		matrix = {right[1],right[2],right[3],0, up[1],up[2],up[3],0,
			n[1],n[2],n[3],0, p[1],p[2],p[3],1},
		vertices = vertices, radius = radius,
	}
end

return Surface
