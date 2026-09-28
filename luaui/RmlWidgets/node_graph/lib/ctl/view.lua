-- The GRAPH window's view controller: zoom and pan, the minimap, comment frames (the
-- groupings the timeline reads as lanes), and the polled gestures (mouse pan, auto-pan at
-- the edge, ending a gesture whose release was lost) (refactor plan, Phase 3.3, GRAPH
-- slice 3).
--
-- Same shape as ctl/edit.lua: a constructor handed exactly what it uses, which
-- FILLS the `Graph` table it is given, because `Graph` is the namespace the timeline and the
-- rest of the widget read too.
--
--     VFS.Include(".../ctl/view.lua")(deps)

---@param deps table
return function(deps)
	local Graph = deps.Graph
	local Bind = deps.Bind
	local GRAPH = deps.GRAPH
	local S = deps.S
	local echo = deps.echo
	local el = deps.el
	local setChipText = deps.setChipText
	local render = deps.render
	for _, name in ipairs({ "Graph", "Bind", "GRAPH", "S", "echo", "el", "setChipText", "render" }) do
		assert(deps[name] ~= nil, "ctl/view: missing dependency " .. name)
	end

	--------------------------------------------------------------------------------
	-- Looking at the canvas: zoom and pan
	--------------------------------------------------------------------------------

	--- Push the current zoom and pan onto the canvas element.
	---
	--- One transform and one offset for the whole graph, so zooming and panning cost nothing
	--- per node and never rebuild anything. `transform-origin` is the canvas's top-left corner
	--- (set in the RCSS), which is what lets the pointer maths below stay this short.
	function Graph.applyGraphView()
		local canvas = el("ng-graph-canvas")
		if not canvas then
			return
		end
		local view = S.graphView
		canvas.style.left = math.floor(view.panX) .. "px"
		canvas.style.top = math.floor(view.panY) .. "px"
		-- NO scale transform. The zoom is baked into what the renderer emits, because a
		-- transform scales the rasterised glyphs and the text goes soft as you zoom in.
		canvas.style.transform = "none"
		setChipText("ng-chip-graph-zoom", string.format("%d%%", math.floor(view.zoom * 100 + 0.5)))
		-- Every pan and every zoom comes through here, so this is the one place the minimap's
		-- rectangle has to be moved from. It moves ONE element: the dots are a render's job.
		Graph.updateMinimapView()
		-- The same for the grid (one container slides) and the scrollbars (two thumbs).
		Graph.updateGrid()
		Graph.updateScrollbars()
	end

	--------------------------------------------------------------------------------
	-- The minimap
	--------------------------------------------------------------------------------

	--- How the whole graph maps into the little box in the corner.
	---
	--- Returned rather than stored, because every number in it depends on something that moves:
	--- the content grows as nodes are dragged, and the box itself changes size with the display.
	--- Measured from the element every time, which is also what keeps this honest about `dp`: the
	--- box is declared in `dp` so it scales with the display, and nothing here has to know that.
	---@return table|nil metrics { scale, offX, offY, boxW, boxH }
	function Graph.minimapMetrics()
		local map = el("ng-graph-minimap")
		if not map then
			return nil
		end
		-- A headless run reports a width and a height of zero, and a zero-sized box would give an
		-- infinite scale and write nonsense into every dot.
		local width, height = map.client_width, map.client_height
		if not width or width <= 0 or not height or height <= 0 then
			return nil
		end
		local pad = GRAPH.minimapPadPx
		local boxW = math.max(1, width - pad * 2)
		local boxH = math.max(1, height - pad * 2)
		-- The GRAPH's extent, not the canvas's. See the note by `graphW` in `Graph.sizeCanvas`: scaling
		-- from the canvas made the map zoom whenever the main view did, and a minimap that moves
		-- with the view shows you nothing the view was not already showing you.
		local contentW = math.max(1, S.graphView.graphW)
		local contentH = math.max(1, S.graphView.graphH)
		-- The SMALLER of the two, so the whole graph fits and its shape is not distorted. A map
		-- that stretched to fill the box would say two nodes are further apart vertically than
		-- they are, which is the one question a minimap exists to answer.
		local scale = math.min(boxW / contentW, boxH / contentH)
		return {
			scale = scale,
			-- Centred in whichever direction has room left over.
			offX = pad + (boxW - contentW * scale) / 2,
			offY = pad + (boxH - contentH * scale) / 2,
			boxW = boxW,
			boxH = boxH,
		}
	end

	--- Move the rectangle that shows what the window is looking at.
	---
	--- Separate from `Graph.renderMinimap` and called from `Graph.applyGraphView`, so a pan costs
	--- one element's style and nothing else. The dots only change when the LAYOUT changes, which
	--- is a different and much rarer event than looking somewhere else.
	function Graph.updateMinimapView()
		local rect = el("ng-graph-minimap-view")
		local metrics = Graph.minimapMetrics()
		local viewport = el("ng-graph-viewport")
		if not (rect and metrics and viewport) then
			return
		end
		local view = S.graphView
		local zoom = math.max(0.0001, view.zoom)
		local contentW = math.max(1, view.graphW)
		local contentH = math.max(1, view.graphH)
		-- The canvas-space rectangle the viewport is showing. The pan is in screen pixels and the
		-- layout is in canvas pixels, which is the whole of the conversion.
		local left = -view.panX / zoom
		local top = -view.panY / zoom
		local width = viewport.offset_width / zoom
		local height = viewport.offset_height / zoom
		-- CLAMPED to the map. Zoomed far enough out, the window covers more than the graph does
		-- and the rectangle would otherwise be drawn outside the box entirely. Held to the edges
		-- it says "all of it, and then some", which is the true thing and the readable one.
		local x0 = math.max(metrics.offX, metrics.offX + left * metrics.scale)
		local y0 = math.max(metrics.offY, metrics.offY + top * metrics.scale)
		local x1 = math.min(metrics.offX + contentW * metrics.scale, metrics.offX + (left + width) * metrics.scale)
		local y1 = math.min(metrics.offY + contentH * metrics.scale, metrics.offY + (top + height) * metrics.scale)
		rect.style.left = math.floor(x0) .. "px"
		rect.style.top = math.floor(y0) .. "px"
		-- At least a couple of pixels each way: zoomed right in on a big graph the rectangle is
		-- sub-pixel, and a marker you cannot see is worse than a slightly wrong one.
		rect.style.width = math.max(3, math.floor(x1 - x0)) .. "px"
		rect.style.height = math.max(3, math.floor(y1 - y0)) .. "px"
	end

	--- Rebuild the dots. Called from the graph render, not from a pan.
	function Graph.renderMinimap()
		local body = el("ng-graph-minimap-body")
		if not body then
			return
		end
		local metrics = Graph.minimapMetrics()
		if not metrics then
			-- Nothing measurable: leave whatever is there rather than blanking it, so a run with
			-- no layout does not also throw away the last good picture.
			return
		end

		local selected = {}
		for _, key in ipairs(S.graphSel or {}) do
			selected[key] = true
		end

		local parts = {}
		-- Groupings first, so the dots sit on top of them, the same order the canvas itself uses.
		for _, frame in ipairs(Graph.comments()) do
			parts[#parts + 1] = string.format(
				'<div class="ng-graph-minimap-frame" style="left: %dpx; top: %dpx; width: %dpx; height: %dpx;"></div>',
				math.floor(metrics.offX + (tonumber(frame.x) or 0) * metrics.scale),
				math.floor(metrics.offY + (tonumber(frame.y) or 0) * metrics.scale),
				math.max(1, math.floor((tonumber(frame.w) or 0) * metrics.scale)),
				math.max(1, math.floor((tonumber(frame.h) or 0) * metrics.scale))
			)
		end

		-- The CONNECTORS (PtaQ, 2026-09-26), under the dots: each wire as a few straight bars
		-- sampled off the curve the canvas drew, one pixel thick, in its gradient's middle colour.
		for index, edge in ipairs(S.graphEdgeList or {}) do
			local points = (S.graphEdgePoints or {})[index]
			if points and points.n then
				local step = math.max(1, math.floor(points.n / 4))
				local colour = Graph.mixTint(Graph.tintOf(edge.from), Graph.tintOf(edge.to), 0.5, 0xb0)
				local at = 1
				while at <= points.n do
					local nextAt = math.min(points.n + 1, at + step)
					local a, b = points[at], points[nextAt]
					local ax, ay = metrics.offX + a.x * metrics.scale, metrics.offY + a.y * metrics.scale
					local bx, by = metrics.offX + b.x * metrics.scale, metrics.offY + b.y * metrics.scale
					local dx, dy = bx - ax, by - ay
					parts[#parts + 1] = string.format(
						'<div class="ng-graph-minimap-edge" style="left: %.1fpx; top: %.1fpx; width: %.1fpx; '
							.. 'background-color: %s; transform: rotate(%.1fdeg);"></div>',
						ax,
						ay,
						math.max(1, math.sqrt(dx * dx + dy * dy) + 0.5),
						colour,
						math.deg(math.atan2(dy, dx))
					)
					at = nextAt
				end
			end
		end

		local dotW = math.max(GRAPH.minimapDotPx, math.floor(GRAPH.nodeWidth * metrics.scale))
		for key, position in pairs(S.layout or {}) do
			local class = "ng-graph-minimap-dot"
			if selected[key] then
				class = class .. " ng-graph-minimap-sel"
			else
				-- `.ng-graph-minimap-<kind>` in the stylesheet, beside the kind's node rules.
				class = class .. " ng-graph-minimap-" .. (key:match("^(%a+):") or "")
			end
			parts[#parts + 1] = string.format(
				'<div class="%s" style="left: %dpx; top: %dpx; width: %dpx; height: %dpx;"></div>',
				class,
				math.floor(metrics.offX + position.x * metrics.scale),
				math.floor(metrics.offY + position.y * metrics.scale),
				dotW,
				math.max(GRAPH.minimapDotPx, math.floor(Graph.heightOf(key) * metrics.scale))
			)
		end

		body.inner_rml = table.concat(parts)
		Graph.updateMinimapView()
	end

	--- Show or hide it, and light the chip that says which it is.
	---@return boolean shown
	function Graph.setMinimap(shown)
		S.graph.minimap = shown and true or false
		Graph.syncFlags()
		if S.graph.minimap then
			-- A RENDER, not a call to `Graph.renderMinimap` here. The box was `display: none` a
			-- line ago, so RmlUi has not laid it out and it still measures zero wide -- and
			-- `Graph.minimapMetrics` correctly refuses to scale anything into a zero-sized box, so
			-- drawing it now puts nothing in it. `widget.Render` raises a flag that `widget:Update`
			-- acts on next frame, by which point the box has a size. The map was otherwise empty
			-- from the moment it was switched on until something else happened to cause a render.
			render()
		end
		return S.graph.minimap
	end

	--- Centre the view on the canvas point this minimap point stands for.
	---
	--- CENTRE and not top-left: a click on a minimap means "show me that", and putting the point
	--- clicked in the corner of the window shows mostly what is to the right of it.
	---@param pointerX number RmlUi screen pixels
	---@param pointerY number RmlUi screen pixels
	---@return boolean moved
	function Graph.jumpMinimap(pointerX, pointerY)
		local map = el("ng-graph-minimap")
		local viewport = el("ng-graph-viewport")
		local metrics = Graph.minimapMetrics()
		if not (map and viewport and metrics and pointerX and metrics.scale > 0) then
			return false
		end
		local localX = pointerX - map.absolute_left - metrics.offX
		local localY = pointerY - map.absolute_top - metrics.offY
		local canvasX = localX / metrics.scale
		local canvasY = localY / metrics.scale
		local view = S.graphView
		view.panX = viewport.offset_width / 2 - canvasX * view.zoom
		view.panY = viewport.offset_height / 2 - canvasY * view.zoom
		Graph.clampPan()
		-- No render. A jump is a pan, and a pan is one offset on the canvas plus one rectangle on
		-- the map; rebuilding the markup for it would make dragging the map cost a rebuild a frame.
		Graph.applyGraphView()
		return true
	end

	--- Where a pointer is in CANVAS coordinates -- the same space `S.layout` is in.
	---
	--- Every gesture on the graph needs this, and a zoom is exactly what breaks the naive
	--- version: at 50% a pointer that moved 10 screen pixels moved 20 canvas pixels. One helper,
	--- so there is one place that has to be right.
	---@param pointerX number RmlUi screen pixels
	---@param pointerY number RmlUi screen pixels
	function Graph.canvasPoint(pointerX, pointerY)
		local viewport = el("ng-graph-viewport")
		if not (viewport and pointerX and pointerY) then
			return nil
		end
		local view = S.graphView
		return (pointerX - viewport.absolute_left - view.panX) / view.zoom,
			(pointerY - viewport.absolute_top - view.panY) / view.zoom
	end

	--- Keep enough of the canvas in the viewport that it can always be dragged back.
	function Graph.clampPan()
		local minX, maxX, minY, maxY = Graph.panRange()
		if not minX then
			return
		end
		local view = S.graphView
		view.panX = math.max(minX, math.min(maxX, view.panX))
		view.panY = math.max(minY, math.min(maxY, view.panY))
	end

	--------------------------------------------------------------------------------
	-- Animated zoom (PtaQ, 2026-09-26: "next level sleek")
	--------------------------------------------------------------------------------
	-- The zoom is baked into the markup, so text stays sharp at every zoom, and changing it is
	-- a rebuild. To animate it without a rebuild per frame, the view moves in two parts: for
	-- `VIEW_ANIM_S` the canvas as last RENDERED is scaled with a transform (so text is briefly
	-- soft), anchored where it has to be; on the last frame one real rebuild at the new zoom
	-- makes it sharp again. `S.graphView` is always the TARGET, so everything that reads it
	-- (hit tests, the pan clamp, the zoom chip) already agrees with where the view is going.

	Graph.VIEW_ANIM_S = 0.1

	--- Where the view is ON SCREEN right now: mid-animation, part way there; otherwise the view.
	function Graph.visualView()
		local anim = S.viewAnim
		local view = S.graphView
		if not anim then
			return view.zoom, view.panX, view.panY
		end
		local t = math.min(1, Spring.DiffTimers(Spring.GetTimer(), anim.started) / Graph.VIEW_ANIM_S)
		local e = 1 - (1 - t) ^ 3
		-- Zoom in LOG space: equal steps look equal, and a 2x and a 0.5x take the same time.
		local zoom = math.exp(math.log(anim.z0) + (math.log(anim.z1) - math.log(anim.z0)) * e)
		local panX, panY
		if anim.ax then
			-- Anchored (the wheel): the point under the pointer stays under it the whole way.
			panX = anim.ax - (anim.ax - anim.x0) * (zoom / anim.z0)
			panY = anim.ay - (anim.ay - anim.y0) * (zoom / anim.z0)
		else
			-- Unanchored (framing, 1:1): the canvas point at the viewport's middle glides.
			local cx = anim.cx0 + (anim.cx1 - anim.cx0) * e
			local cy = anim.cy0 + (anim.cy1 - anim.cy0) * e
			panX = anim.w / 2 - cx * zoom
			panY = anim.h / 2 - cy * zoom
		end
		return zoom, panX, panY, t >= 1
	end

	--- Move the view to where `S.graphView` now says, animated from `z0, x0, y0` (where it was
	--- on screen). `ax, ay` anchor it (viewport px), or nil to glide the middle. Instant, with
	--- the usual rebuild, when animation is off (the harness) or there is no viewport.
	function Graph.animateView(z0, x0, y0, ax, ay)
		local view = S.graphView
		local viewport = el("ng-graph-viewport")
		if S.viewAnimOff or not viewport or viewport.offset_width <= 0 then
			S.viewAnim = nil
			Graph.applyGraphView()
			render()
			return
		end
		local w, h = viewport.offset_width, viewport.offset_height
		S.viewAnim = {
			started = Spring.GetTimer(),
			z0 = z0,
			x0 = x0,
			y0 = y0,
			z1 = view.zoom,
			ax = ax,
			ay = ay,
			w = w,
			h = h,
			cx0 = (w / 2 - x0) / z0,
			cy0 = (h / 2 - y0) / z0,
			cx1 = (w / 2 - view.panX) / view.zoom,
			cy1 = (h / 2 - view.panY) / view.zoom,
		}
		-- An anchored zoom whose clamp moved the target off the anchor's path would jump on the
		-- last frame; glide it instead.
		if ax then
			local expectX = ax - (ax - x0) * (view.zoom / z0)
			local expectY = ay - (ay - y0) * (view.zoom / z0)
			if math.abs(expectX - view.panX) > 1 or math.abs(expectY - view.panY) > 1 then
				S.viewAnim.ax, S.viewAnim.ay = nil, nil
			end
		end
		setChipText("ng-chip-graph-zoom", string.format("%d%%", math.floor(view.zoom * 100 + 0.5)))
		Graph.pollViewAnim()
	end

	--- How long the ghost takes to fade off the sharp rebuild.
	Graph.GHOST_FADE_S = 0.07

	--- Lay an inert copy of the canvas, scaled to the glide's last frame, over it. Ids and
	--- bindings are stripped, so nothing finds or wires the copy's elements by mistake.
	function Graph.beginGhost(canvas, zoom, panX, panY)
		local ghost = el("ng-graph-canvas-ghost")
		if not ghost then
			return
		end
		local markup = tostring(canvas.inner_rml or "")
		markup = markup:gsub(' id="[^"]*"', ""):gsub(' data%-[%w%-]+="[^"]*"', "")
		ghost.inner_rml = markup
		local rendered = S.renderedZoom or zoom
		ghost.style.width = canvas.style.width
		ghost.style.height = canvas.style.height
		ghost.style["transform-origin"] = "0px 0px"
		-- At the WHOLE-pixel offset the rebuilt canvas takes (`applyGraphView` floors the pan):
		-- at the fractional one the two sat up to half a pixel apart and the fade smudged.
		ghost.style.transform =
			string.format("translate(%dpx, %dpx) scale(%.5f)", math.floor(panX), math.floor(panY), zoom / rendered)
		ghost.style.opacity = "1"
		ghost:SetClass("hidden", false)
		S.ghostFade = Spring.GetTimer()
		-- The view it belongs to: the moment the view moves (a pan, a scroll, another zoom,
		-- framing), the ghost no longer lines up with anything and goes at once.
		S.ghostView = { zoom = S.graphView.zoom, panX = S.graphView.panX, panY = S.graphView.panY }
	end

	--- Fade it off, then empty it. Also cut short by a new glide.
	function Graph.pollGhost()
		if not S.ghostFade then
			return
		end
		local ghost = el("ng-graph-canvas-ghost")
		local t = Spring.DiffTimers(Spring.GetTimer(), S.ghostFade) / Graph.GHOST_FADE_S
		local view, at = S.graphView, S.ghostView or {}
		local moved = view.zoom ~= at.zoom or view.panX ~= at.panX or view.panY ~= at.panY
		if not ghost or t >= 1 or S.viewAnim or moved then
			S.ghostFade = nil
			if ghost then
				ghost:SetClass("hidden", true)
				ghost.inner_rml = ""
			end
			return
		end
		-- Falls off fast, so it reads as the rebuild settling rather than as a second picture.
		ghost.style.opacity = string.format("%.3f", (1 - t) * (1 - t))
	end

	--- One frame of it, from widget:Update. The canvas keeps its rendered markup and is scaled
	--- by transform from the zoom it was rendered at; the grid, minimap rectangle and scrollbars
	--- follow the on-screen view. The last frame rebuilds at the target zoom.
	function Graph.pollViewAnim()
		local anim = S.viewAnim
		if not anim then
			return
		end
		local canvas = el("ng-graph-canvas")
		local zoom, panX, panY, done = Graph.visualView()
		if done or not canvas then
			S.viewAnim = nil
			-- The scaled picture, frozen at exactly where the glide ends, over the rebuild.
			if canvas then
				Graph.beginGhost(canvas, zoom, panX, panY)
			end
			Graph.applyGraphView()
			render()
			return
		end
		local rendered = S.renderedZoom or S.graphView.zoom
		-- ALL of the motion in ONE transform, at sub-pixel precision: the canvas box stays put at
		-- 0,0 and the pan is a fractional translate. Writing the pan to left/top rounds it to
		-- whole pixels every frame while the scale moves smoothly, and the text wobbled by up to
		-- a pixel against itself (PtaQ, 2026-09-26: "it wanders pixels").
		canvas.style.left = "0px"
		canvas.style.top = "0px"
		canvas.style["transform-origin"] = "0px 0px"
		canvas.style.transform = string.format("translate(%.3fpx, %.3fpx) scale(%.5f)", panX, panY, zoom / rendered)
		-- The chrome that reads the view, told the on-screen one for this frame.
		local view = S.graphView
		local tz, tx, ty = view.zoom, view.panX, view.panY
		view.zoom, view.panX, view.panY = zoom, panX, panY
		Graph.updateGrid()
		Graph.updateMinimapView()
		Graph.updateScrollbars()
		view.zoom, view.panX, view.panY = tz, tx, ty
	end

	function Graph.zoomGraph(direction, pointerX, pointerY)
		local view = S.graphView
		-- A notch mid-animation zooms on from where the view IS, not from where it was going:
		-- held wheel turns chain smoothly instead of each one snapping to the last target first.
		local z0, x0, y0 = Graph.visualView()
		view.zoom, view.panX, view.panY = z0, x0, y0
		local step = direction > 0 and GRAPH.zoomStep or 1 / GRAPH.zoomStep
		local target = math.max(GRAPH.minZoom, math.min(GRAPH.maxZoom, view.zoom * step))
		if math.abs(target - view.zoom) < 0.0005 then
			return false
		end
		local viewport = el("ng-graph-viewport")
		local vx = (pointerX or 0) - (viewport and viewport.absolute_left or 0)
		local vy = (pointerY or 0) - (viewport and viewport.absolute_top or 0)
		local scale = target / view.zoom
		view.panX = vx - (vx - view.panX) * scale
		view.panY = vy - (vy - view.panY) * scale
		view.zoom = target
		Graph.clampPan()
		-- Animated, anchored at the pointer; the rebuild happens once, on the last frame.
		Graph.animateView(z0, x0, y0, vx, vy)
		return true
	end

	--- Back to 1:1 at the origin. What FIT and RELAYOUT leave behind, and what the zoom chip
	--- does when pressed.
	function Graph.resetGraphView()
		local z0, x0, y0 = Graph.visualView()
		S.graphView.zoom = 1
		S.graphView.panX = 0
		S.graphView.panY = 0
		-- Glides there (the rebuild at 1:1 is on the last frame).
		Graph.animateView(z0, x0, y0)
	end

	--- Scroll the canvas by screen pixels: the wheel (vertical) and Shift+wheel (horizontal).
	--- Positive moves the CONTENT down/right, which is what a wheel turned up shows.
	function Graph.scrollBy(dx, dy)
		S.graphView.panX = S.graphView.panX + (dx or 0)
		S.graphView.panY = S.graphView.panY + (dy or 0)
		Graph.clampPan()
		Graph.applyGraphView()
	end

	--------------------------------------------------------------------------------
	-- The background grid and the scrollbars
	--------------------------------------------------------------------------------
	-- Both live in SCREEN space, siblings of the canvas like the minimap, and both follow the
	-- view from `applyGraphView`. Neither is rebuilt by a pan: the grid slides one container,
	-- the scrollbars restyle two thumbs. The grid's lines are rebuilt only when the zoom or the
	-- viewport's size changes (the canvas exception: raw pixel geometry, not bound markup).

	--- The pan range `clampPan` enforces, and the viewport's size.
	---@return number|nil minX, number maxX, number minY, number maxY, number viewW, number viewH
	function Graph.panRange()
		local viewport = el("ng-graph-viewport")
		if not viewport or viewport.offset_width <= 0 or viewport.offset_height <= 0 then
			return nil
		end
		local view = S.graphView
		local keep = GRAPH.panKeepPx
		local width = math.max(1, view.contentW * view.zoom)
		local height = math.max(1, view.contentH * view.zoom)
		-- Half a screen of slack past the content on every side, so there is somewhere to drag a
		-- node TO. Clamping tight to the content means the empty space a designer wants to move
		-- something into cannot be brought into view.
		local viewW, viewH = viewport.offset_width, viewport.offset_height
		local slackX, slackY = viewW * 0.5, viewH * 0.5
		return keep - width - slackX, viewW - keep + slackX, keep - height - slackY, viewH - keep + slackY, viewW, viewH
	end

	--- Lay the tame background grid under the canvas, so an empty canvas visibly moves.
	---
	--- Lines every `GRAPH.gridPx` canvas pixels, every fourth one a little brighter. The spacing
	--- doubles until it is at least `GRAPH.gridMinPx` on screen, so zooming out never turns the
	--- background into a grey wash. The container is a grid PERIOD (four cells) larger than the
	--- viewport on every side and is slid by the pan modulo that period, so the lines appear to
	--- be fixed to the canvas while never being more than one container.
	function Graph.updateGrid()
		local grid = el("ng-graph-grid")
		local viewport = el("ng-graph-viewport")
		if not (grid and viewport) or viewport.offset_width <= 0 or viewport.offset_height <= 0 then
			return
		end
		local view = S.graphView
		local cell = GRAPH.gridPx * view.zoom
		while cell < GRAPH.gridMinPx do
			cell = cell * 2
		end
		local period = cell * 4
		local w, h = viewport.offset_width, viewport.offset_height
		local key = string.format("%d:%d:%d", math.floor(cell * 100), w, h)
		if S.gridKey ~= key then
			S.gridKey = key
			local parts = {}
			for i = 0, math.ceil((w + 2 * period) / cell) do
				parts[#parts + 1] = string.format(
					'<div class="ng-grid-v%s" style="left: %dpx;"></div>',
					i % 4 == 0 and " ng-grid-major" or "",
					math.floor(i * cell)
				)
			end
			for i = 0, math.ceil((h + 2 * period) / cell) do
				parts[#parts + 1] = string.format(
					'<div class="ng-grid-h%s" style="top: %dpx;"></div>',
					i % 4 == 0 and " ng-grid-major" or "",
					math.floor(i * cell)
				)
			end
			grid.inner_rml = table.concat(parts)
			grid.style.width = math.ceil(w + 2 * period) .. "px"
			grid.style.height = math.ceil(h + 2 * period) .. "px"
		end
		-- The grid is phased off the pan PLUS every shift `normaliseLayout` has made: that moves
		-- the content one way and the pan the other, the picture stays put, and the grid has to
		-- stay put with it (PtaQ, 2026-09-26: dropping a node left of the canvas jumped it).
		local shiftX = (S.gridShiftX or 0) * view.zoom
		local shiftY = (S.gridShiftY or 0) * view.zoom
		grid.style.left = math.floor(((view.panX + shiftX) % period) - period) .. "px"
		grid.style.top = math.floor(((view.panY + shiftY) % period) - period) .. "px"
	end

	--- One scrollbar's thumb: its length and offset along a track, in px.
	---@return number|nil length, number offset, number ratio pan pixels per thumb pixel
	function Graph.scrollThumb(axis)
		local minX, maxX, minY, maxY, viewW, viewH = Graph.panRange()
		local track = el(axis == "x" and "ng-graph-scroll-x" or "ng-graph-scroll-y")
		if not (minX and track) then
			return nil
		end
		local lo, hi, visible = minX, maxX, viewW
		local trackLen = track.offset_width
		local pan = S.graphView.panX
		if axis == "y" then
			lo, hi, visible, trackLen, pan = minY, maxY, viewH, track.offset_height, S.graphView.panY
		end
		if trackLen <= 0 then
			return nil
		end
		local range = math.max(1, hi - lo)
		local length = math.max(GRAPH.scrollThumbMinPx, math.floor(trackLen * visible / (range + visible)))
		length = math.min(length, trackLen)
		local travel = math.max(1, trackLen - length)
		-- The pan at its MAXIMUM shows the start of the content, so the thumb sits at the start.
		local offset = math.floor((hi - pan) / range * travel + 0.5)
		return length, math.max(0, math.min(travel, offset)), range / travel
	end

	--- Put both thumbs where the view is.
	function Graph.updateScrollbars()
		for _, axis in ipairs({ "x", "y" }) do
			local thumb = el("ng-graph-scroll-" .. axis .. "-thumb")
			local length, offset = Graph.scrollThumb(axis)
			if thumb and length then
				if axis == "x" then
					thumb.style.width = length .. "px"
					thumb.style.left = offset .. "px"
				else
					thumb.style.height = length .. "px"
					thumb.style.top = offset .. "px"
				end
			end
		end
	end

	--- A press on a scrollbar THUMB: grab it. Bound (`data-event-mousedown`), and the drag is
	--- then polled from `widget:Update` like every gesture on this canvas, because RmlUi stops
	--- sending drag events once the pointer leaves the element and a scrollbar drag spends most
	--- of its time off the thumb.
	function Graph.bound.graphScrollGrab(event, axis)
		if event and event.StopPropagation then
			event:StopPropagation()
		end
		local p = event and event.parameters or {}
		if p.button ~= nil and p.button ~= Graph.RMLUI_BUTTON.left then
			return
		end
		local px, py = Graph.pointerScreen(p.mouse_x, p.mouse_y)
		local _, _, ratio = Graph.scrollThumb(axis)
		if not (px and ratio) then
			return
		end
		S.scrollDrag = {
			axis = axis,
			grab = axis == "x" and px or py,
			startPan = axis == "x" and S.graphView.panX or S.graphView.panY,
			ratio = ratio,
		}
	end

	--- A press on a scrollbar TRACK, off the thumb: page towards the press, 90% of a view.
	function Graph.bound.graphScrollPage(event, axis)
		if event and event.StopPropagation then
			event:StopPropagation()
		end
		local p = event and event.parameters or {}
		if p.button ~= nil and p.button ~= Graph.RMLUI_BUTTON.left then
			return
		end
		local px, py = Graph.pointerScreen(p.mouse_x, p.mouse_y)
		local thumb = el("ng-graph-scroll-" .. axis .. "-thumb")
		local _, _, _, _, viewW, viewH = Graph.panRange()
		if not (px and thumb and viewW) then
			return
		end
		local page = 0.9 * (axis == "x" and viewW or viewH)
		if axis == "x" then
			Graph.scrollBy(px < thumb.absolute_left and page or -page, 0)
		else
			Graph.scrollBy(0, py < thumb.absolute_top and page or -page)
		end
	end

	--- Keep a thumb under the pointer while the button is down. From `widget:Update`.
	---@param pointerX number|nil for the harness, which cannot move a real pointer
	function Graph.pollScrollDrag(pointerX, pointerY)
		local drag = S.scrollDrag
		if not drag then
			return
		end
		if not Graph.host.showing() then
			S.scrollDrag = nil
			return
		end
		local px, py = pointerX, pointerY
		if not px then
			px, py = Graph.pointerScreen()
		end
		if not px then
			return
		end
		local moved = (drag.axis == "x" and px or py) - drag.grab
		-- The thumb going right/down shows content further right/down: the pan goes the other way.
		local pan = drag.startPan - moved * drag.ratio
		if drag.axis == "x" then
			S.graphView.panX = pan
		else
			S.graphView.panY = pan
		end
		Graph.clampPan()
		Graph.applyGraphView()
	end

	function Graph.endScrollDrag()
		S.scrollDrag = nil
	end

	--------------------------------------------------------------------------------
	-- Edge tabs: the KEYS card and the minimap (stage three, Q10)
	--------------------------------------------------------------------------------
	-- Blender's panel tab: a small handle that sticks out of the edge a panel slides from and
	-- stays on screen when the panel is shut. A CLICK toggles; a DRAG moves the panel with the
	-- pointer and letting go snaps it open or shut by how far out it is. The press and the click
	-- are bound; the drag is polled from widget:Update like every canvas gesture, and ended by
	-- the document's mouseup (Graph.endStuckGestures).

	Graph.EDGE_TABS = {
		-- `sign` is which way the pointer moves to OPEN it; `side` the margin that slides it.
		keys = { id = "ng-graph-help", side = "margin-right", sign = -1 },
		map = { id = "ng-graph-minimap", side = "margin-left", sign = 1 },
	}
	--- Below this many pixels of travel a press and release is a click, not a drag.
	Graph.EDGE_TAB_SLOP_PX = 5

	local function edgeOpen(which)
		if which == "keys" then
			return S.helpOpen == true
		end
		return S.graph.minimap == true
	end

	local function setEdgeOpen(which, open)
		if which == "keys" then
			Graph.setHelp(open)
		else
			Graph.setMinimap(open)
		end
	end

	--- How far a panel travels between shut and open, in px: its own width, plus the gap it
	--- keeps from the edge.
	local function edgeTravel(tab)
		local panel = el(tab.id)
		if not panel then
			return nil
		end
		return panel.offset_width + (tab.side == "margin-left" and 10 or 0)
	end

	function Graph.bound.edgeTabGrab(event, which)
		local tab = Graph.EDGE_TABS[which]
		if event and event.StopPropagation then
			event:StopPropagation()
		end
		local p = event and event.parameters or {}
		if not tab or (p.button ~= nil and p.button ~= Graph.RMLUI_BUTTON.left) then
			return
		end
		local px = Graph.pointerScreen(p.mouse_x, p.mouse_y)
		local travel = edgeTravel(tab)
		if not (px and travel) then
			return
		end
		S.edgeDrag = { which = which, grab = px, travel = travel, start = edgeOpen(which) and travel or 0 }
		-- A drag slides the card in before anything opens it, so it has to be filled already.
		if which == "keys" then
			Graph.renderHelp()
		end
	end

	--- How far out the panel is while it is being dragged, 0 (shut) to `travel` (open).
	local function dragAmount(drag, px)
		local tab = Graph.EDGE_TABS[drag.which]
		return math.max(0, math.min(drag.travel, drag.start + tab.sign * (px - drag.grab)))
	end

	---@param pointerX number|nil for the harness, which cannot move a real pointer
	function Graph.pollEdgeDrag(pointerX)
		local drag = S.edgeDrag
		if not drag then
			return
		end
		local px = pointerX or Graph.pointerScreen()
		if not px then
			return
		end
		if math.abs(px - drag.grab) > Graph.EDGE_TAB_SLOP_PX then
			drag.moved = true
		end
		drag.last = px
		if drag.moved then
			local tab = Graph.EDGE_TABS[drag.which]
			local panel = el(tab.id)
			if panel then
				-- Inline, over the class, while the hand is on it; the release gives it back.
				panel.style[tab.side] = math.floor(dragAmount(drag, px) - drag.travel) .. "px"
			end
		end
	end

	--- The release. A drag snaps by position; a press that never moved is left to the click.
	function Graph.endEdgeDrag(pointerX)
		local drag = S.edgeDrag
		if not drag then
			return
		end
		S.edgeDrag = nil
		if pointerX then
			Graph.pollEdgeDrag(pointerX)
		end
		if not drag.moved then
			return
		end
		S.edgeJustDragged = drag.which
		local tab = Graph.EDGE_TABS[drag.which]
		local panel = el(tab.id)
		if panel then
			-- An empty string REMOVES the inline property (SolLua StyleProxy::Set), handing the
			-- panel back to its class.
			panel.style[tab.side] = ""
		end
		setEdgeOpen(drag.which, dragAmount(drag, drag.last or drag.grab) > drag.travel / 2)
	end

	--- A click on a tab toggles its panel, unless it was the end of a drag.
	function Graph.bound.edgeTabClick(event, which)
		if event and event.StopPropagation then
			event:StopPropagation()
		end
		if S.edgeJustDragged == which then
			S.edgeJustDragged = nil
			return
		end
		if Graph.EDGE_TABS[which] then
			setEdgeOpen(which, not edgeOpen(which))
		end
	end

	--- Is this RmlUi screen point inside the graph viewport?
	function Graph.inGraphViewport(pointerX, pointerY)
		local viewport = el("ng-graph-viewport")
		-- BOTH, not just the width. A run with no viewport reports a width but a height of
		-- zero, and a degenerate box happily contains the (0, 0) the mouse reads as there --
		-- so the editor would claim the wheel in a headless session.
		if not viewport or viewport.offset_width == 0 or viewport.offset_height == 0 then
			return false
		end
		local left, top = viewport.absolute_left, viewport.absolute_top
		return pointerX >= left
			and pointerX <= left + viewport.offset_width
			and pointerY >= top
			and pointerY <= top + viewport.offset_height
	end

	--- Geometry in core.lua (Graph.lib); this passes the widget's state in.
	function Graph.normaliseLayout()
		local dx, dy = Graph.lib.NormaliseLayout(S.layout, Graph.commentsIfAny())
		if not dx then
			return false
		end
		-- The content moved inside the canvas; the canvas moves the other way under the window,
		-- and the grid keeps its phase (see `Graph.updateGrid`).
		S.graphView.panX = S.graphView.panX - dx * S.graphView.zoom
		S.graphView.panY = S.graphView.panY - dy * S.graphView.zoom
		S.gridShiftX = (S.gridShiftX or 0) + dx
		S.gridShiftY = (S.gridShiftY or 0) + dy
		return true
	end

	--- Begin a pan from a screen point, whatever started it.
	function Graph.beginPan(pointerX, pointerY)
		S.graphPan = {
			grabX = pointerX or 0,
			grabY = pointerY or 0,
			startX = S.graphView.panX,
			startY = S.graphView.panY,
		}
	end

	--- Move a pan already begun.
	function Graph.panTo(pointerX, pointerY)
		local pan = S.graphPan
		if not (pan and pointerX) then
			return
		end
		-- Screen pixels, NOT canvas pixels: a pan moves the canvas itself, so it moves one for
		-- one with the pointer whatever the zoom is.
		S.graphView.panX = pan.startX + (pointerX - pan.grabX)
		S.graphView.panY = pan.startY + (pointerY - pan.grabY)
		Graph.clampPan()
		Graph.applyGraphView()
	end

	--------------------------------------------------------------------------------
	-- Comment frames
	--------------------------------------------------------------------------------

	--- The groupings, on the adapter's store (`adapter.store().comments`), created on demand so
	--- a document that has none emits no key for them.
	function Graph.comments()
		local store = Graph.adapter.store()
		if type(store) ~= "table" then
			return {}
		end
		store.comments = type(store.comments) == "table" and store.comments or {}
		return store.comments
	end

	--- The same list for a reader, without creating it.
	function Graph.commentsIfAny()
		local store = Graph.adapter.store()
		return type(store) == "table" and type(store.comments) == "table" and store.comments or {}
	end

	function Graph.commentById(id)
		for _, frame in ipairs(Graph.comments()) do
			if frame.id == id then
				return frame
			end
		end
		return nil
	end

	function Graph.commentElementId(id)
		return "ng-gcomment-" .. tostring(id)
	end

	--- Wrap the selection in a frame, or drop an empty one in the middle of the view.
	---
	--- Round-robin tints rather than a colour picker: two frames side by side are never the same
	--- colour, and nobody has to make a decision they did not come here to make.
	---@return boolean consumed
	function Graph.addComment()
		if not Graph.host.hasDocument() then
			return false
		end
		local frames = Graph.comments()
		local minX, minY, maxX, maxY = Graph.boundsOf(S.graphSel)
		if minX then
			local pad = GRAPH.commentPadPx
			minX, minY = minX - pad, minY - pad - GRAPH.commentHeadPx
			maxX, maxY = maxX + pad, maxY + pad
		else
			-- Nothing selected: an empty frame in the middle of what is being looked at, which is
			-- how somebody makes a place to drag nodes INTO.
			local viewport = el("ng-graph-viewport")
			local cx, cy = Graph.canvasPoint(
				(viewport and viewport.absolute_left or 0) + (viewport and viewport.offset_width or 600) / 2,
				(viewport and viewport.absolute_top or 0) + (viewport and viewport.offset_height or 400) / 2
			)
			if not cx then
				return false
			end
			minX, minY = cx - GRAPH.commentBlankW / 2, cy - GRAPH.commentBlankH / 2
			maxX, maxY = minX + GRAPH.commentBlankW, minY + GRAPH.commentBlankH
		end

		local id = "c1"
		local n = 1
		while Graph.commentById(id) do
			n = n + 1
			id = "c" .. n
		end
		local frame = {
			id = id,
			title = "Grouping",
			x = math.floor(minX),
			y = math.floor(minY),
			w = math.floor(maxX - minX),
			h = math.floor(maxY - minY),
			tint = (#frames % GRAPH.commentTints) + 1,
		}
		frames[#frames + 1] = frame
		S.graphSelComment = id
		Graph.host.edited()
		render()
		-- Straight into naming it. An untitled frame is a coloured rectangle, and a coloured
		-- rectangle is not a comment.
		Graph.editCommentTitle(id)
		return true
	end

	--- Geometry in core.lua (Graph.lib); this passes the widget's state in.
	function Graph.commentMembers(frame)
		return Graph.lib.CommentMembers(S.layout, S.nodeH, frame)
	end

	function Graph.beginCommentDrag(id, pointerX, pointerY)
		local frame = Graph.commentById(id)
		if not frame then
			return
		end
		-- Membership is decided ONCE, when the drag starts. Recomputing it per frame would let a
		-- node the frame happens to sweep over join the drag halfway through it.
		S.commentDrag = {
			id = id,
			grabX = pointerX or 0,
			grabY = pointerY or 0,
			startX = frame.x,
			startY = frame.y,
			members = Graph.commentMembers(frame),
		}
		S.graphSelComment = id
		Graph.clearSelection()
	end

	function Graph.dragCommentTo(pointerX, pointerY)
		local drag = S.commentDrag
		local frame = drag and Graph.commentById(drag.id)
		if not (frame and pointerX) then
			return
		end
		local cx, cy = Graph.canvasPoint(pointerX, pointerY)
		local gx, gy = Graph.canvasPoint(drag.grabX, drag.grabY)
		if not (cx and gx) then
			return
		end
		frame.x = math.floor(drag.startX + (cx - gx))
		frame.y = math.floor(drag.startY + (cy - gy))

		-- Styles only, never markup: this runs inside RmlUi's own drag dispatch.
		local element = el(Graph.commentElementId(frame.id))
		if element then
			element.style.left = Graph.px(frame.x) .. "px"
			element.style.top = Graph.px(frame.y) .. "px"
		end
		for _, member in ipairs(drag.members) do
			if Graph.moveNode(member.key, frame.x + member.dx, frame.y + member.dy) then
				Graph.refreshNodeElements(member.key)
			end
		end
	end

	--- Start resizing a grouping from its corner grip.
	function Graph.beginCommentResize(id, pointerX, pointerY)
		local frame = Graph.commentById(id)
		if not frame then
			return
		end
		local cx, cy = Graph.canvasPoint(pointerX, pointerY)
		if not cx then
			return
		end
		S.commentResize = { id = id, grabX = cx, grabY = cy, w = frame.w, h = frame.h }
		S.graphSelComment = id
		Graph.clearSelection()
		S.graphSelComment = id
	end

	--- Follow the pointer. Styles only: this runs inside RmlUi's own drag dispatch, where
	--- rebuilding the canvas would replace the element being dragged.
	function Graph.resizeCommentTo(pointerX, pointerY)
		local resize = S.commentResize
		local frame = resize and Graph.commentById(resize.id)
		if not (frame and pointerX) then
			return
		end
		local cx, cy = Graph.canvasPoint(pointerX, pointerY)
		if not cx then
			return
		end
		-- Never smaller than its own title bar plus somewhere to put a node.
		frame.w = math.max(GRAPH.commentMinW, math.floor(resize.w + (cx - resize.grabX)))
		frame.h = math.max(GRAPH.commentMinH, math.floor(resize.h + (cy - resize.grabY)))

		local element = el(Graph.commentElementId(frame.id))
		if element then
			element.style.width = Graph.px(frame.w) .. "px"
			element.style.height = Graph.px(frame.h) .. "px"
			local head = el("ng-gcommenthead-" .. tostring(frame.id))
			if head then
				head.style.width = Graph.px(frame.w) .. "px"
			end
		end
	end

	function Graph.endCommentResize()
		if not S.commentResize then
			return false
		end
		S.commentResize = nil
		Graph.host.edited()
		Graph.sizeCanvas()
		-- A render, because which nodes are INSIDE the grouping has just changed and the next drag
		-- of it has to pick up the new membership.
		render()
		return true
	end

	function Graph.endCommentDrag()
		if not S.commentDrag then
			return false
		end
		S.commentDrag = nil
		Graph.host.edited()
		Graph.normaliseLayout()
		Graph.sizeCanvas()
		render()
		return true
	end

	--- Remove a frame. The nodes inside it are untouched: a comment is a note about the graph,
	--- not a container for it, and deleting the note must never delete the work.
	function Graph.deleteComment(id)
		local frames = Graph.comments()
		for index, frame in ipairs(frames) do
			if frame.id == id then
				table.remove(frames, index)
				S.graphSelComment = nil
				Graph.host.edited()
				render()
				echo(string.format("deleted the grouping '%s'", tostring(frame.title)))
				return true
			end
		end
		return false
	end

	--- Put the caret in a frame's title.
	function Graph.editCommentTitle(id)
		local frame = Graph.commentById(id)
		if not frame then
			return false
		end
		S.commentEdit = id
		local field = el("ng-comment-title")
		if field then
			pcall(function()
				field:SetAttribute("value", tostring(frame.title or ""))
			end)
		end
		S.focusAfterRender = "ng-comment-title"
		render()
		return true
	end

	function Graph.closeCommentEdit()
		if not S.commentEdit then
			return false
		end
		S.commentEdit = nil
		local field = el("ng-comment-title")
		if field then
			pcall(function()
				field:Blur()
			end)
		end
		render()
		return true
	end

	--- Position the title editor over the frame it belongs to, and show or hide it.
	function Graph.renderCommentEdit()
		local box = el("ng-comment-edit")
		if not box then
			return
		end
		local frame = S.commentEdit and Graph.commentById(S.commentEdit)
		if not frame then
			box:SetClass("hidden", true)
			return
		end
		-- IN PLACE over the title, at its size, like a node's rename (PtaQ, 2026-09-26).
		local viewport, window = el("ng-graph-viewport"), S.graphWindow
		if viewport and window then
			local left = viewport.absolute_left
				- window.absolute_left
				+ S.graphView.panX
				+ Graph.px(frame.x + GRAPH.commentTitleInsetPx - 4)
			local top = viewport.absolute_top - window.absolute_top + S.graphView.panY + Graph.px(frame.y + 3)
			local height = Graph.px(GRAPH.commentHeadPx - 6)
			box.style.left = math.floor(left) .. "px"
			box.style.top = math.floor(top) .. "px"
			local field = el("ng-comment-title")
			if field then
				field.style.width = Graph.px(math.max(120, frame.w - GRAPH.commentTitleInsetPx * 2)) .. "px"
				field.style.height = height .. "px"
				field.style["line-height"] = (height - 4) .. "px"
				field.style["font-size"] = Graph.px(GRAPH.commentTitlePx) .. "px"
			end
		end
		box:SetClass("hidden", false)
	end

	--- Keep a middle-button pan following the pointer. Position only.
	---
	--- **The button cannot be polled.** Two earlier attempts died on this and the reason is
	--- written out above `Graph.beginNodeDrag`: a press that lands on an RmlUi element is reported
	--- handled before `MouseHandler::MousePress` records it, so the engine says every button is up
	--- for the whole gesture. `widget:MousePress` never arrives either, for the same reason.
	---
	--- So the press comes from an RmlUi `mousedown`, which carries a button, the release comes from
	--- the document's `mouseup`, and this only moves what is already moving. It is exactly what
	--- `attachDraggable` does for the floating windows, which has worked all along.
	---
	--- Called from `widget:Update`.
	function Graph.pollMousePan()
		if not S.graphPanMouse then
			return
		end
		if not Graph.host.showing() then
			S.graphPanMouse = nil
			S.graphPan = nil
			return
		end
		Graph.panTo(Graph.pointerScreen())
	end

	--- Move the canvas when a gesture reaches the edge of the viewport.
	---
	--- The viewport CLIPS and does not scroll, so without this a node cannot be dragged to
	--- anywhere that is not already on screen: the answer was zoom out, drag, zoom back in, every
	--- time. Every gesture gets it, not only the node drag, because a connector being pulled to an
	--- off-screen node has exactly the same problem.
	---
	--- After the canvas moves, the gesture in flight is re-driven at the SAME screen point. It has
	--- to be: the pan changed what that point means in canvas coordinates, and a node that stayed
	--- where it was would slide out from under the pointer.
	---
	--- Called from `widget:Update`.
	function Graph.pollAutoPan()
		if not Graph.host.showing() then
			return
		end
		-- Only while something is being dragged. A pointer resting near the edge must not send the
		-- view drifting on its own.
		local dragging = S.graphDrag or S.portDrag or S.graphMarquee or S.commentDrag or S.commentResize
		if not dragging or S.graphPanMouse then
			return
		end
		local viewport = el("ng-graph-viewport")
		if not viewport or viewport.offset_height == 0 then
			return
		end
		local px, py = Graph.pointerScreen()
		if not px then
			return
		end

		local left, top = viewport.absolute_left, viewport.absolute_top
		local right, bottom = left + viewport.offset_width, top + viewport.offset_height
		local margin, speed = GRAPH.autoPanMarginPx, GRAPH.autoPanSpeedPx

		--- How hard to push, from 0 at the margin to 1 at the edge and beyond.
		local function push(distance)
			if distance >= margin then
				return 0
			end
			return math.min(1, (margin - distance) / margin)
		end

		local dx = push(px - left) * speed - push(right - px) * speed
		local dy = push(py - top) * speed - push(bottom - py) * speed
		if dx == 0 and dy == 0 then
			return
		end

		local view = S.graphView
		local wasX, wasY = view.panX, view.panY
		view.panX = view.panX + dx
		view.panY = view.panY + dy
		Graph.clampPan()
		Graph.applyGraphView()
		if view.panX == wasX and view.panY == wasY then
			-- Clamped: there is nothing further that way, so nothing to follow either.
			return
		end

		-- Re-drive whatever is in flight, at the same pointer, now that the pointer means a
		-- different place on the canvas.
		if S.graphDrag then
			Graph.dragNodeTo(px, py)
		elseif S.portDrag then
			Graph.dragPortTo(px, py)
		elseif S.commentDrag then
			Graph.dragCommentTo(px, py)
		elseif S.commentResize then
			Graph.resizeCommentTo(px, py)
		elseif S.graphMarquee then
			Graph.dragMarquee(px, py)
		end
	end

	--- End anything still believed to be in progress, on any mouse release.
	---
	--- Each of these has its own end, and this calls it rather than clearing the state by hand:
	--- ending a node drag commits the move and re-bases the layout, and dropping that on the floor
	--- would be a different bug in place of this one.
	function Graph.endStuckGestures()
		-- RmlUi's release is mouseup, THEN a click on the element the press started on, THEN
		-- dragend. This runs on the mouseup, so the click that follows would find the gesture
		-- already over and read as "clicked empty space": a rubber band released over the canvas
		-- cleared everything it had just caught (PtaQ: "it works if the canvas pans", because an
		-- auto-panned release lands off the canvas and no click follows). The frame a gesture
		-- ended in is kept, and the canvas's click stands down for it.
		if
			S.graphDrag
			or S.portDrag
			or S.commentDrag
			or S.commentResize
			or S.graphMarquee
			or S.minimapDrag
			or S.scrollDrag
			or S.graphPan
		then
			S.gestureEndedAt = Graph.host.frame()
		end
		if S.graphDrag then
			Graph.endNodeDrag()
		end
		if S.portDrag then
			Graph.endPortDrag()
		end
		if S.commentDrag then
			Graph.endCommentDrag()
		end
		if S.commentResize then
			Graph.endCommentResize()
		end
		if S.graphMarquee then
			Graph.endMarquee()
		end
		S.minimapDrag = nil
		S.scrollDrag = nil
		Graph.endEdgeDrag()
		S.graphPan = nil
	end

	--- Start a middle-button pan, from the press that RmlUi delivered.
	function Graph.beginMousePan(pointerX, pointerY)
		Graph.beginPan(pointerX, pointerY)
		S.graphPanMouse = true
		-- Nothing else may claim the gesture while it runs.
		S.graphMarquee = nil
		Graph.setHoverEdge(nil)
	end

	function Graph.endMousePan()
		if not S.graphPanMouse then
			return false
		end
		S.graphPanMouse = nil
		S.graphPan = nil
		-- No render: a pan is one offset on the canvas and the markup is unchanged.
		return true
	end
end
