--- THE WIRES, drawn on the GPU into one texture under the nodes.
---
--- Every connector used to be a chain of rotated `<div>` bars, 2688 of the canvas's 4178
--- elements on the 113-node showcase mission. RmlUi draws every element every frame and rebuilds
--- every one on every edit, so the wires were most of what the open graph cost: 12-15 ms of
--- drawing a frame at rest and most of the 400-600 ms rebuild (UX pass, 2026-09-29). Here they
--- are one vertex buffer, drawn by one shader into a texture the size of the viewport, shown by a
--- `<texture>` element beneath the canvas.
---
--- Geometry is in CANVAS units (the layout's space) and the view is a uniform, so a pan, a zoom
--- step or the glide between two zooms is one draw call with nothing rebuilt; the vertex buffer
--- is rebuilt only when a wire's points or colour change (a render, a node dragged, the
--- selection relit). Each segment is widened in SCREEN pixels by the shader, with a one-pixel
--- anti-aliased edge, so a wire stays at least a pixel wide when zoomed far out and never blurs
--- when zoomed in.
---
--- Colours are the ones the bars had: the gradient between the two nodes' tints at the
--- adapter's strength (full on the selection), the picked wire gold, a wire on a cycle pulsing
--- between the stylesheet's two reds (`ng-edge-pulse`, 1.6 s). Drawn in the bars' z-order:
--- ordinary, cycle, selected, picked.
---
--- The hover glow, the wire being dragged and the sever button stay RmlUi elements: there are
--- few of them, and they are what the pointer interacts with.
return function(deps)
	local S = deps.S
	local Graph = deps.Graph
	local GRAPH = deps.GRAPH
	local el = deps.el

	local Wires = {}

	local TEXTURE_ID = "ng-graph-wires"
	local PULSE_S = 1.6
	local FLOATS = 11 -- pos 2, dir 2, corner 2, colour 4, pulse 1

	local records = {} -- [edgeIndex] = { points, fromTint, toTint, alpha, mode, selected }
	local geometryDirty = true
	local drawDirty = true
	local vbo, vao, vertexCount = nil, nil, 0
	local shader = nil
	local shaderFailed = false
	local texture, texW, texH = nil, 0, 0
	local shownTexture = nil
	local lastView = {}
	local anyPulse = false

	local VS = [[
#version 330
layout (location = 0) in vec2 pos;
layout (location = 1) in vec2 dir;
layout (location = 2) in vec2 corner;
layout (location = 3) in vec4 colour;
layout (location = 4) in float pulse;
uniform vec4 view;   // zoom, panX, panY, half width in px
uniform vec3 target; // texture width, height, seconds
out vec4 vColour;
out float vAcross;
out float vHalf;
void main() {
	float h = view.w;
	vec2 n = vec2(-dir.y, dir.x);
	vec2 p = pos * view.x + view.yz + dir * corner.x * h + n * corner.y * (h + 1.0);
	// Pixel rows run down, and the texture's first row (clip -1) is the element's top row.
	gl_Position = vec4(p.x / target.x * 2.0 - 1.0, p.y / target.y * 2.0 - 1.0, 0.0, 1.0);
	vec4 c = colour;
	if (pulse > 0.5) {
		float k = 0.5 - 0.5 * cos(target.z * 6.2831853 / 1.6);
		c.rgb = mix(vec3(0.537, 0.169, 0.180), vec3(0.937, 0.267, 0.267), k);
	}
	vColour = c;
	vAcross = corner.y * (h + 1.0);
	vHalf = h;
}
]]

	local FS = [[
#version 330
in vec4 vColour;
in float vAcross;
in float vHalf;
out vec4 fragColour;
void main() {
	float a = clamp(vHalf + 0.5 - abs(vAcross), 0.0, 1.0) * vColour.a;
	fragColour = vec4(vColour.rgb * a, a);
}
]]

	local function hexRGB(text)
		local r, g, b = tostring(text):match("#(%x%x)(%x%x)(%x%x)")
		return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
	end

	local PICKED = { hexRGB("#fdc04c") }

	--- Graph.mixTint as three numbers, 0..1, without building a colour string per vertex: the
	--- same flattening onto the canvas colour, the same rounding.
	local function mixRGB(from, to, t, alpha)
		local strength = (alpha or 255) / 255
		local bg = Graph.CANVAS_BG
		local r = math.floor(bg[1] + (from[1] + (to[1] - from[1]) * t - bg[1]) * strength + 0.5)
		local g = math.floor(bg[2] + (from[2] + (to[2] - from[2]) * t - bg[2]) * strength + 0.5)
		local b = math.floor(bg[3] + (from[3] + (to[3] - from[3]) * t - bg[3]) * strength + 0.5)
		return r / 255, g / 255, b / 255
	end

	-- One vertex table, reused by every rebuild: a fresh 177,000-number table per rebuild was
	-- garbage enough to put collector pauses into unrelated timed Lua.
	local data = {}
	local dataLength = 0

	--- Forget every wire: a render is about to lay them all down again.
	function Wires.begin()
		records = {}
		geometryDirty = true
	end

	---@param mode string "tint" | "cycle" | "picked"
	function Wires.add(index, points, fromTint, toTint, alpha, mode, selected)
		records[index] = {
			points = points,
			fromTint = fromTint,
			toTint = toTint,
			alpha = alpha,
			mode = mode,
			selected = selected,
		}
		geometryDirty = true
	end

	--- New points for one wire (a node being dragged). nil hides it (the nodes overlap).
	function Wires.setPoints(index, points)
		local record = records[index]
		if record then
			record.points = points
			geometryDirty = true
		end
	end

	--- A selection relight: the strength a wire is drawn at, and whether it is on the selection.
	function Wires.recolour(index, alpha, selected)
		local record = records[index]
		if record and (record.alpha ~= alpha or record.selected ~= selected) then
			record.alpha = alpha
			record.selected = selected
			geometryDirty = true
		end
	end

	--- What the harness and the hit tests can read in place of the bars.
	function Wires.record(index)
		return records[index]
	end

	function Wires.count()
		local n = 0
		for _ in pairs(records) do
			n = n + 1
		end
		return n
	end

	local function layerOf(record)
		if record.mode == "picked" then
			return 4
		end
		if record.selected then
			return 3
		end
		if record.mode == "cycle" then
			return 2
		end
		return 1
	end

	local function buildGeometry()
		geometryDirty = false
		drawDirty = true
		anyPulse = false
		local n = 0
		local function push(x, y, dx, dy, along, across, r, g, b, a, pulse)
			data[n + 1], data[n + 2], data[n + 3], data[n + 4] = x, y, dx, dy
			data[n + 5], data[n + 6] = along, across
			data[n + 7], data[n + 8], data[n + 9], data[n + 10] = r, g, b, a
			data[n + 11] = pulse
			n = n + FLOATS
		end
		for layer = 1, 4 do
			for _, record in pairs(records) do
				local points = record.points
				if points and points.n and points.n > 0 and layerOf(record) == layer then
					local pulse = record.mode == "cycle" and 1 or 0
					if pulse == 1 then
						anyPulse = true
					end
					local count = points.n
					for segment = 1, count do
						local p0, p1 = points[segment], points[segment + 1]
						if p0 and p1 then
							local dx, dy = p1.x - p0.x, p1.y - p0.y
							local length = math.sqrt(dx * dx + dy * dy)
							if length > 0.0001 then
								dx, dy = dx / length, dy / length
								local r0, g0, b0, r1, g1, b1
								if record.mode == "picked" then
									r0, g0, b0 = PICKED[1], PICKED[2], PICKED[3]
									r1, g1, b1 = r0, g0, b0
								else
									local t0 = count > 1 and (segment - 1) / (count - 1) or 0
									local t1 = count > 1 and segment / (count - 1) or 0
									r0, g0, b0 = mixRGB(record.fromTint, record.toTint, math.min(1, t0), record.alpha)
									r1, g1, b1 = mixRGB(record.fromTint, record.toTint, math.min(1, t1), record.alpha)
								end
								-- Two triangles; `along` pushes each end out by half the width so
								-- the joints between segments are covered, as the bars' caps did.
								push(p0.x, p0.y, dx, dy, -1, -1, r0, g0, b0, 1, pulse)
								push(p1.x, p1.y, dx, dy, 1, -1, r1, g1, b1, 1, pulse)
								push(p1.x, p1.y, dx, dy, 1, 1, r1, g1, b1, 1, pulse)
								push(p0.x, p0.y, dx, dy, -1, -1, r0, g0, b0, 1, pulse)
								push(p1.x, p1.y, dx, dy, 1, 1, r1, g1, b1, 1, pulse)
								push(p0.x, p0.y, dx, dy, -1, 1, r0, g0, b0, 1, pulse)
							end
						end
					end
				end
			end
		end
		for index = n + 1, dataLength do
			data[index] = nil
		end
		dataLength = n
		vertexCount = n / FLOATS
		if vertexCount == 0 then
			return
		end
		-- A VBO's layout can be defined once only, so a rebuild takes a fresh buffer and array.
		if vbo then
			vbo:Delete()
		end
		if vao then
			vao:Delete()
		end
		vbo, vao = nil, nil
		vbo = gl.GetVBO(GL.ARRAY_BUFFER, true)
		if not vbo then
			vertexCount = 0
			return
		end
		vbo:Define(vertexCount, {
			{ id = 0, name = "pos", size = 2 },
			{ id = 1, name = "dir", size = 2 },
			{ id = 2, name = "corner", size = 2 },
			{ id = 3, name = "colour", size = 4 },
			{ id = 4, name = "pulse", size = 1 },
		})
		vbo:Upload(data)
		vao = gl.GetVAO()
		if vao then
			vao:AttachVertexBuffer(vbo)
		end
	end

	local function ensureShader()
		if shader or shaderFailed then
			return shader ~= nil
		end
		local LuaShader = gl.LuaShader
		if not LuaShader then
			shaderFailed = true
			return false
		end
		shader = LuaShader({ vertex = VS, fragment = FS }, "node_graph_wires")
		if not shader:Initialize() then
			Spring.Echo("[node graph] the wire shader did not compile; wires are not drawn")
			shader = nil
			shaderFailed = true
			return false
		end
		return true
	end

	--- The texture the size of the element showing it. Recreated when the viewport resizes.
	local function ensureTexture(element)
		local w, h = math.floor(element.offset_width or 0), math.floor(element.offset_height or 0)
		if w <= 0 or h <= 0 then
			return false
		end
		if texture and texW == w and texH == h then
			return true
		end
		if texture then
			gl.DeleteTexture(texture)
		end
		texture = gl.CreateTexture(w, h, {
			border = false,
			min_filter = GL.NEAREST,
			mag_filter = GL.NEAREST,
			wrap_s = GL.CLAMP_TO_EDGE,
			wrap_t = GL.CLAMP_TO_EDGE,
			fbo = true,
		})
		texW, texH = w, h
		drawDirty = true
		return texture ~= nil
	end

	--- From the widget's DrawScreen (gl.RenderToTexture is only allowed in a draw call-in).
	--- Redraws only when something moved: the wires, the view, the size, or a cycle's pulse.
	function Wires.draw()
		local element = el(TEXTURE_ID)
		-- Whichever host the canvas is in (NodeGraph.create's host) says whether it shows.
		local showing = Graph.host and Graph.host.showing and Graph.host.showing()
		if not (element and showing) then
			return
		end
		if not ensureShader() or not ensureTexture(element) then
			return
		end
		if geometryDirty then
			buildGeometry()
		end
		if shownTexture ~= texture then
			element:SetAttribute("src", texture)
			shownTexture = texture
		end
		local zoom, panX, panY = Graph.visualView()
		-- The canvas sits at the floored pan (applyGraphView); mid-glide it is a fractional
		-- translate, which visualView already is.
		if not S.viewAnim then
			panX, panY = math.floor(panX), math.floor(panY)
		end
		local half = math.max(1, math.floor((GRAPH.edgePx or 5) * zoom + 0.5)) / 2
		local moved = lastView.zoom ~= zoom or lastView.panX ~= panX or lastView.panY ~= panY
		if not (drawDirty or moved or anyPulse) then
			return
		end
		lastView.zoom, lastView.panX, lastView.panY = zoom, panX, panY
		drawDirty = false
		local seconds = Spring.DiffTimers(Spring.GetTimer(), Wires.epoch or Spring.GetTimer())
		Wires.epoch = Wires.epoch or Spring.GetTimer()
		gl.RenderToTexture(texture, function()
			gl.Clear(GL.COLOR_BUFFER_BIT, 0, 0, 0, 0)
			if not (vao and vertexCount > 0) then
				return
			end
			gl.DepthTest(false)
			gl.Blending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA)
			shader:Activate()
			shader:SetUniform("view", zoom, panX, panY, half)
			shader:SetUniform("target", texW, texH, seconds % PULSE_S)
			vao:DrawArrays(GL.TRIANGLES, vertexCount)
			shader:Deactivate()
			gl.Blending(true)
		end)
	end

	function Wires.shutdown()
		if texture then
			gl.DeleteTexture(texture)
			texture = nil
		end
		if shader then
			shader:Finalize()
			shader = nil
		end
		if vbo then
			vbo:Delete()
		end
		if vao then
			vao:Delete()
		end
		vbo, vao = nil, nil
	end

	return Wires
end
