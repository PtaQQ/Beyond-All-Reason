-- The GRAPH window's linking controller: wires (hit testing, hover, selecting, severing,
-- clearing a port), the create palette, expanding and renaming a node, and dragging a
-- connector off a port to link two nodes (refactor plan, Phase 3.3, GRAPH slice 2).
--
-- Same shape as ctl/edit.lua: a constructor handed exactly what it uses, which
-- FILLS the `Graph` table it is given, because `Graph` is the namespace the timeline and the
-- rest of the widget read too.
--
--     VFS.Include(".../ctl/link.lua")(deps)

---@param deps table
return function(deps)
	local Graph = deps.Graph
	local GRAPH = deps.GRAPH
	local S = deps.S
	local echo = deps.echo
	local el = deps.el
	local escapeRml = deps.escapeRml
	local nodeKey = deps.nodeKey
	local onClick = deps.onClick
	local setText = deps.setText
	local render = deps.render
	for _, name in ipairs({
		"Graph",
		"GRAPH",
		"S",
		"echo",
		"el",
		"escapeRml",
		"nodeKey",
		"onClick",
		"setText",
		"render",
	}) do
		assert(deps[name] ~= nil, "ctl/link: missing dependency " .. name)
	end

	--------------------------------------------------------------------------------
	-- Wires: hit testing, selecting, severing
	--------------------------------------------------------------------------------

	Graph.pointToSegment = Graph.lib.PointToSegment

	--- Geometry in core.lua (Graph.lib); this passes the widget's state in.
	function Graph.edgeAt(cx, cy, screenRadius)
		local zoom = (S.graphView and S.graphView.zoom) or 1
		return Graph.lib.EdgeAt(S.graphEdgeList, S.graphEdgePoints, zoom, cx, cy, screenRadius)
	end

	--- How a connector reads in the status line: the adapter's words for it.
	function Graph.describeEdge(edge)
		return Graph.adapter.describeEdge(edge)
	end

	--- Light up the connector under the pointer, so clicking one is aiming rather than guessing.
	---
	--- Polled from `widget:Update` rather than driven by events: the bars are `pointer-events:
	--- none` (they are hundreds of one-pixel divs and making them hit-testable would cost a hit
	--- test per bar per mouse move), so nothing sends us a hover. The poll does nothing at all
	--- unless the pointer has actually moved.
	function Graph.pollEdgeHover()
		if not Graph.host.showing() then
			return
		end
		-- Not during a gesture: a drag has its own feedback and a hover would fight it.
		if S.graphDrag or S.portDrag or S.graphMarquee or S.graphPan or S.graphPanMouse then
			Graph.setHoverEdge(nil)
			return
		end
		local px, py = Graph.pointerScreen()
		if not px or (px == S.hoverPointerX and py == S.hoverPointerY) then
			return
		end
		S.hoverPointerX, S.hoverPointerY = px, py
		if not Graph.inGraphViewport(px, py) then
			Graph.setHoverEdge(nil)
			return
		end
		local cx, cy = Graph.canvasPoint(px, py)
		if Graph.nodeAt(cx, cy) then
			-- A node in front of the wire wins: the click would go to the node.
			Graph.setHoverEdge(nil)
			return
		end
		local _, index = Graph.edgeAt(cx, cy)
		Graph.setHoverEdge(index)
		Graph.setHoverSever(index and Graph.nearEdgeMiddle(index, cx, cy) and index or nil)
	end

	--- A wire's gradient at `t`, lifted a third of the way to white: the hover colour.
	function Graph.brightTint(from, to, t)
		local out = {}
		for channel = 1, 3 do
			local tint = from[channel] + (to[channel] - from[channel]) * t
			out[channel] = math.floor(tint + (255 - tint) * 0.35 + 0.5)
		end
		return string.format("#%02x%02x%02x", out[1], out[2], out[3])
	end

	--- Where a connector's middle is, in canvas units: half way along the curve it was drawn
	--- with. The curve's points are spaced by smoothstep on the parameter, so the middle POINT
	--- (or the mean of the two middle ones) is the bezier at t = 0.5.
	---@return number|nil x, number|nil y
	function Graph.edgeMiddle(index)
		local points = index and (S.graphEdgePoints or {})[index]
		if not (points and points.n) then
			return nil
		end
		local a = points[math.floor(points.n / 2) + 1]
		local b = points[math.ceil(points.n / 2) + 1]
		if not (a and b) then
			return nil
		end
		return (a.x + b.x) / 2, (a.y + b.y) / 2
	end

	--- Is this canvas point close enough to a connector's middle to mean its sever button?
	--- The radius is in SCREEN pixels, like the wire's own hit radius.
	function Graph.nearEdgeMiddle(index, cx, cy)
		local mx, my = Graph.edgeMiddle(index)
		if not (mx and cx) then
			return false
		end
		local zoom = (S.graphView and S.graphView.zoom) or 1
		local dx, dy = (cx - mx) * zoom, (cy - my) * zoom
		return dx * dx + dy * dy <= Graph.EDGE.severPx * Graph.EDGE.severPx
	end

	--- Show the sever button on the middle of one connector, or hide it.
	function Graph.setHoverSever(index)
		if S.hoverSever == index then
			return
		end
		S.hoverSever = index
		local button = el("ng-edge-sever")
		if not button then
			return
		end
		local mx, my = Graph.edgeMiddle(index)
		if not mx then
			button:SetClass("hidden", true)
			-- Back to what the wire under the pointer (if any) says about itself.
			local hovered = S.hoverEdge and (S.graphEdgeList or {})[S.hoverEdge]
			Graph.setHint(
				hovered and (Graph.describeEdge(hovered) .. "  |  click to pick it, click its middle to cut it") or ""
			)
			return
		end
		local half = Graph.px(Graph.SEVER_ICON_PX) / 2
		button.style.left = math.floor(Graph.px(mx) - half) .. "px"
		button.style.top = math.floor(Graph.px(my) - half) .. "px"
		button:SetClass("hidden", false)
		local edge = (S.graphEdgeList or {})[index]
		Graph.setHint(edge and ("click to cut: " .. Graph.describeEdge(edge)) or "")
	end

	--- Show the hover highlight on one connector, or on none.
	---
	--- An OVERLAY laid along the wire, not a class on the wire's own bars. The renderer writes
	--- `background-color` INLINE on every tinted connector, and an inline value beats a class, so
	--- a `.ng-edge-hover` rule would never be seen on the ordinary edges. That is the same trap
	--- the single-wire port fell into, where the square corner only appeared once its radius went
	--- inline. An overlay owns its own elements and nothing competes for them.
	function Graph.setHoverEdge(index)
		if S.hoverEdge == index then
			return
		end
		if index == nil or S.hoverSever ~= index then
			Graph.setHoverSever(nil)
		end
		S.hoverEdge = index
		local points = index and (S.graphEdgePoints or {})[index]
		local edge = index and (S.graphEdgeList or {})[index]
		-- How many bars are showing. NOT the thickness below: an inner local of the same name
		-- once shadowed this, it stayed 0, and every bar was hidden again the moment it was laid,
		-- so no wire ever lit up under the pointer.
		local shown = 0
		if points and edge then
			local fromTint, toTint = Graph.tintOf(edge.from), Graph.tintOf(edge.to)
			-- A touch fatter than the wire, so the brighter copy covers it cleanly.
			local thick = math.max(2, Graph.px(GRAPH.edgePx + 1))
			for segment = 1, math.min(points.n, Graph.HOVER_SEGMENTS) do
				local bar = el(Graph.hoverSegmentId(segment))
				if bar then
					local left, top, width, angle = Graph.segmentStyle(points[segment], points[segment + 1])
					local along = points.n > 1 and (segment - 1) / (points.n - 1) or 0
					bar.style.left = Graph.px(left) .. "px"
					bar.style.top = Graph.px(top) .. "px"
					bar.style.width = Graph.px(width) .. "px"
					bar.style.height = thick .. "px"
					bar.style["border-radius"] = math.max(1, math.ceil(thick / 2)) .. "px"
					bar.style.transform = string.format("rotate(%.2fdeg)", angle)
					-- The wire's own colours, brighter: hovering says "this one", it does not
					-- repaint the wire as something else (PtaQ, 2026-09-26).
					bar.style["background-color"] = Graph.brightTint(fromTint, toTint, along)
					bar:SetClass("hidden", false)
					shown = segment
				end
			end
		end
		for segment = shown + 1, Graph.HOVER_SEGMENTS do
			local bar = el(Graph.hoverSegmentId(segment))
			if bar then
				bar:SetClass("hidden", true)
			end
		end

		-- The status line says what clicking would pick, which is the other half of the answer:
		-- the highlight says WHICH wire, this says what it means.
		Graph.setHint(edge and (Graph.describeEdge(edge) .. "  |  click to pick it, click its middle to cut it") or "")
	end

	--- What a press on empty canvas means, at a screen point.
	---
	--- A function rather than a listener body, because two things reach it: the `click` event, and
	--- a marquee that turned out never to have grown. RmlUi reports a drag on the first pixel of
	--- movement with no threshold of its own, so a click that wobbled arrives as a band.
	function Graph.clickCanvasAt(pointerX, pointerY)
		if S.palette or S.commentEdit or S.nodeRename then
			Graph.closePalette()
			Graph.closeCommentEdit()
			Graph.closeNodeRename()
			return
		end
		local cx, cy = Graph.canvasPoint(pointerX, pointerY)
		local edge, edgeIndex = Graph.edgeAt(cx, cy)
		if edge then
			local alt = Spring.GetModKeyState()
			-- Alt-click cuts outright, the fast path for somebody who already knows; a click on
			-- the wire's MIDDLE, where the sever button shows, cuts it too.
			if alt or Graph.nearEdgeMiddle(edgeIndex, cx, cy) then
				Graph.severEdge(edge)
				return
			end
			Graph.selectEdge(edge)
			S.elementCache = {}
			render()
			echo(Graph.describeEdge(edge) .. " -- Delete to cut it")
			return
		end
		if #S.graphSel == 0 and not S.graphSelEdge and not S.graphSelComment then
			return
		end
		Graph.clearSelection()
		S.elementCache = {}
		render()
	end

	--- Pick a wire. Replaces the node selection, because Delete has to be unambiguous.
	function Graph.selectEdge(edge)
		S.graphSel = {}
		-- The PORT and the HOOK travel with it, which is the same mistake `S.graphEdgesByNode`
		-- made: a copy of an edge that keeps only its two ends is not an edge, and everything
		-- downstream treats it as one. Without them, Delete on a selected hook wire fell back to
		-- the "cut it only if exactly one of the five fields names that trigger" rule and refused
		-- a wire it was looking straight at, and the status line described it as the wrong thing.
		S.graphSelEdge = edge
				and { from = edge.from, to = edge.to, kind = edge.kind, port = edge.port, hook = edge.hook }
			or nil
	end

	--- Take every connector off one port. Alt-click.
	---
	--- One gesture for "start this node over", which otherwise means finding and cutting each wire
	--- by hand. One undo step for the lot.
	---@return boolean consumed
	---@param name string|nil clear only the named port, rather than the whole side
	function Graph.clearPort(key, side, name)
		local wanted = side == "out"
		local doomed = {}
		for _, edge in ipairs((S.graphEdgesByNode or {})[key] or {}) do
			local mine = (wanted and edge.from == key) or (not wanted and edge.to == key)
			-- A named port owns only the wires that left IT. Alt-clicking `onCompleted` must not
			-- take `onFailed` with it just because both leave the same node.
			if mine and name ~= nil and wanted and edge.port ~= name then
				mine = false
			end
			if mine then
				doomed[#doomed + 1] = edge
			end
		end
		if #doomed == 0 then
			echo("nothing is plugged into that port")
			return true
		end
		local cut = 0
		for _, edge in ipairs(doomed) do
			if Graph.unlinkNodes(edge.from, edge.to, edge.port) then
				cut = cut + 1
			end
		end
		if cut == 0 then
			return true
		end
		Graph.host.edited()
		Graph.host.analyse()
		render()
		echo(string.format("cut %d connector(s) off that port", cut))
		return true
	end

	--- Cut a wire and say what was cut.
	---@return boolean cut
	function Graph.severEdge(edge)
		if not edge then
			return false
		end
		local description = Graph.describeEdge(edge)
		if not Graph.unlinkNodes(edge.from, edge.to, edge.port) then
			echo("that connector is already gone")
			return false
		end
		if S.graphSelEdge and S.graphSelEdge.from == edge.from and S.graphSelEdge.to == edge.to then
			S.graphSelEdge = nil
		end
		Graph.host.edited()
		Graph.host.analyse()
		render()
		echo("cut: " .. description)
		return true
	end

	--------------------------------------------------------------------------------
	-- The create palette
	--------------------------------------------------------------------------------

	--- At most this many rows. A filter box with 94 entries under it is a wall, and anybody who
	--- has not narrowed it to twelve has not started typing yet.
	Graph.PALETTE_ROWS = 12

	--- Every option the palette offers for the wire in flight (or none): the adapter's.
	function Graph.paletteAll(pending)
		return Graph.adapter.palette(pending)
	end

	--- What the filter lets through. A plain substring match, case-insensitive, over the type
	--- name and the kind, so "trig sp" is not clever but "spawn" and "trigger" both work.
	function Graph.paletteMatches()
		local palette = S.palette
		if not palette then
			return {}
		end
		local needle = (palette.filter or ""):lower()
		local wanted = palette.kind or "all"
		local out = {}
		for _, option in ipairs(palette.all or {}) do
			local rightKind = wanted == "all" or option.kind == wanted
			if rightKind and (needle == "" or (option.kind .. " " .. option.type):lower():find(needle, 1, true)) then
				out[#out + 1] = option
				if #out >= Graph.PALETTE_ROWS then
					break
				end
			end
		end
		return out
	end

	--- Which kinds this palette could offer at all, whatever is typed in it.
	---
	--- From the legal set rather than from the two names, because a wire off an EnableTrigger can
	--- only reach a trigger and a chip that offers actions there would be a lie.
	function Graph.paletteKindsAvailable()
		local available = {}
		for _, option in ipairs((S.palette or {}).all or {}) do
			available[option.kind] = true
		end
		return available
	end

	--- Pick a category. `which` is "all" or one of the adapter's kinds.
	function Graph.setPaletteKind(which)
		if not S.palette then
			return false
		end
		if which ~= "all" and not Graph.paletteKindsAvailable()[which] then
			echo("no " .. which .. " can take that connector")
			return false
		end
		S.palette.kind = which
		render()
		return true
	end

	--- Open the palette at a screen point.
	---@param pending table|nil the port drag it was opened from, kept alive across it
	function Graph.openPalette(pointerX, pointerY, pending)
		if not Graph.host.hasDocument() then
			return false
		end
		local cx, cy = Graph.canvasPoint(pointerX, pointerY)
		if not cx then
			return false
		end
		S.palette = {
			screenX = pointerX,
			screenY = pointerY,
			canvasX = cx,
			canvasY = cy,
			pending = pending,
			filter = "",
			-- ALL every time it opens, rather than remembering the last choice: the palette is
			-- opened dozens of times an hour and a filter left on from ten minutes ago looks like
			-- a missing entry.
			kind = "all",
			all = Graph.paletteAll(pending),
		}
		-- The caret goes in the box on the next frame, for the same reason a new record's name
		-- does: the list under it has not been built yet.
		S.focusAfterRender = "ng-palette-search"
		render()
		return true
	end

	--- Open the palette to CHANGE a node's type (PtaQ, 2026-09-27: double click the type line).
	--- The same box, search and keys as ADD NODE, offering only the types of that node's kind,
	--- the one it has now left out. Picking one retypes the record in place.
	function Graph.openRetype(key, pointerX, pointerY)
		local kind, id = Graph.splitKey(key)
		if not (Graph.adapter.retype and Graph.adapter.retypable and Graph.adapter.retypable(kind)) then
			return false
		end
		local record = Graph.adapter.find(kind, id)
		if not record then
			return false
		end
		if not Graph.openPalette(pointerX, pointerY, nil) then
			return false
		end
		local offered = {}
		for _, option in ipairs(Graph.paletteAll(nil)) do
			if option.kind == kind and not option.new and option.type ~= record.type then
				offered[#offered + 1] = option
			end
		end
		S.palette.all = offered
		S.palette.kind = kind
		S.palette.retype = key
		return true
	end

	--- Shut it, leaving the document untouched.
	function Graph.closePalette()
		if not S.palette then
			return false
		end
		S.palette = nil
		local field = el("ng-palette-search")
		if field then
			pcall(function()
				field:SetAttribute("value", "")
				field:Blur()
			end)
		end
		render()
		return true
	end

	--- Create the chosen node, place it where the wire was let go, and wire it up.
	---@return boolean created
	function Graph.paletteAccept(option)
		local palette = S.palette
		if not (palette and option and Graph.host.hasDocument()) then
			return false
		end
		-- Opened from a node's type line: change that node, make nothing.
		if palette.retype then
			local retypeKind, retypeId = Graph.splitKey(palette.retype)
			local ok, said = Graph.adapter.retype(retypeKind, retypeId, option.type)
			S.palette = nil
			echo(tostring(said))
			if ok then
				Graph.setSelection(palette.retype)
				Graph.adapter.inspect(retypeKind, retypeId)
				S.elementCache = {}
				Graph.host.edited()
				Graph.host.analyse()
			end
			render()
			return ok
		end
		local kind = option.kind
		local key, made = Graph.adapter.create(option)
		if not key then
			echo(tostring(made))
			return false
		end
		local _, id = Graph.splitKey(key)

		-- Where it lands. The point the wire was let go is where the connector should MEET the
		-- node, not where the node's corner goes, so the box is placed so that the port the wire
		-- arrives at sits under the cursor.
		local pending = palette.pending
		local x = palette.canvasX - GRAPH.nodeWidth / 2
		if pending then
			x = pending.fixedIsSource and palette.canvasX or (palette.canvasX - GRAPH.nodeWidth)
		end
		S.layout = S.layout or {}
		S.layout[key] = { x = math.floor(x), y = math.floor(palette.canvasY - GRAPH.nodeHeight / 2) }

		local linked, message
		if pending then
			local sourceKey, targetKey = Graph.dropEnds(pending, key)
			-- The PORT the wire left, when the fixed end is its source. Without it a wire off an
			-- objective's hook wrote the new trigger into `nextStage` (Link defaults to it).
			linked, message = Graph.linkNodes(sourceKey, targetKey, pending.fixedIsSource and pending.port or nil)
		end

		S.palette = nil
		Graph.setSelection(key)
		-- The inspector follows, with the new record's name in edit.
		Graph.adapter.inspect(kind, id, true)
		Graph.host.edited()
		Graph.host.analyse()
		render()
		echo(made)
		if pending then
			echo(linked and tostring(message) or ("could not connect it: " .. tostring(message)))
		end
		return true
	end

	--- The palette's size before it has been laid out (its first frame), in window pixels: about
	--- what `.ng-palette` measures with a full list. Only a first guess; the box is measured after.
	Graph.PALETTE_ESTIMATE_W = 620
	Graph.PALETTE_ESTIMATE_H = 560

	--- Draw the palette. Called from the render, like everything else that builds markup.
	function Graph.renderPalette()
		local box = el("ng-palette")
		if not box then
			return
		end
		local palette = S.palette
		if not palette then
			box:SetClass("hidden", true)
			return
		end

		local window = S.graphWindow
		local viewport = el("ng-graph-viewport")
		if window and palette.docked and viewport then
			-- Opened from + NODE: docked in the canvas's top-left corner, under the button.
			box.style.left = math.floor(viewport.absolute_left - window.absolute_left + 6) .. "px"
			box.style.top = math.floor(viewport.absolute_top - window.absolute_top + 6) .. "px"
		elseif window then
			-- Kept wholly inside the graph window (PtaQ: "it should never be obscured by the edge").
			-- Below and right of the pointer by default; ABOVE it when that would pass the bottom,
			-- LEFT of it when that would pass the right edge; then clamped with a margin. Sized
			-- from the box itself: it used to clamp against a fixed 610 x 170, and the real box is
			-- several times taller once its list is in, so near the bottom the list hung off the
			-- window. On the frame it first shows it has no size yet, so an estimate is used and
			-- the next frame re-places it from the measured box.
			local margin = 8
			local measuredW, measuredH = box.offset_width or 0, box.offset_height or 0
			local boxW = measuredW > 0 and measuredW or Graph.PALETTE_ESTIMATE_W
			local boxH = measuredH > 0 and measuredH or Graph.PALETTE_ESTIMATE_H
			local windowW, windowH = window.offset_width, window.offset_height
			local pointerX = palette.screenX - window.absolute_left
			local pointerY = palette.screenY - window.absolute_top
			local left = pointerX + margin
			if left + boxW > windowW - margin then
				left = pointerX - margin - boxW
			end
			local top = pointerY + margin
			if top + boxH > windowH - margin then
				top = pointerY - margin - boxH
			end
			left = math.max(margin, math.min(math.max(margin, windowW - boxW - margin), left))
			top = math.max(margin, math.min(math.max(margin, windowH - boxH - margin), top))
			box.style.left = math.floor(left) .. "px"
			box.style.top = math.floor(top) .. "px"
			-- Placed from a guess, or the list changed height: place it again next frame.
			if measuredW ~= palette.placedW or measuredH ~= palette.placedH then
				palette.placedW, palette.placedH = measuredW, measuredH
				render()
			end
		end

		local title = palette.pending and "CONNECT TO A NEW NODE" or "ADD NODE"
		if palette.retype then
			local _, retypeId = Graph.splitKey(palette.retype)
			title = "CHANGE TYPE: " .. tostring(retypeId)
		end
		setText("ng-palette-title", title)

		-- The kinds' chips are bound (`Graph.syncKindChips`); ALL is the one in the markup.
		local allChip = el("ng-palette-kind-all")
		if allChip then
			allChip:SetClass("active", (palette.kind or "all") == "all")
		end

		local matches = Graph.paletteMatches()
		palette.matches = matches
		local list = el("ng-palette-list")
		if list then
			local parts = {}
			for index, option in ipairs(matches) do
				parts[#parts + 1] = string.format(
					'<div class="ng-palette-row ng-palette-row-%s%s" id="ng-palette-row-%d">'
						.. '<div class="ng-palette-kind">%s</div><div class="ng-palette-name">%s</div></div>',
					option.kind,
					index == 1 and " active" or "",
					index,
					option.kind:upper(),
					escapeRml(option.type)
				)
			end
			if #matches == 0 then
				parts[#parts + 1] = '<div class="ng-palette-hint">nothing matches, and nothing legal is hidden</div>'
			end
			list.inner_rml = table.concat(parts)
		end

		box:SetClass("hidden", false)
		S.elementCache = {}
		for index, option in ipairs(matches) do
			local captured = option
			onClick("ng-palette-row-" .. index, function()
				Graph.paletteAccept(captured)
			end)
		end
	end

	--- Open or shut one node. A render, because the box changes height and every connector
	--- touching it has to meet it in its new middle.
	function Graph.toggleExpanded(key)
		S.expanded[key] = (not S.expanded[key]) or nil
		S.elementCache = {}
		render()
	end

	--- Put the caret in a node's title, to rename it in place.
	---
	--- A floating field rather than one inside the node: the canvas is rebuilt wholesale on every
	--- render and a field living in there would be destroyed mid-word.
	function Graph.editNodeTitle(key)
		local kind, id = Graph.splitKey(key)
		if not (kind and Graph.adapter.find(kind, id)) then
			return false
		end
		S.nodeRename = key
		local field = el("ng-node-rename-input")
		if field then
			pcall(function()
				field:SetAttribute("value", tostring(id))
			end)
		end
		S.focusAfterRender = "ng-node-rename-input"
		render()
		return true
	end

	--- Select every character in a text field. `GetElementById` hands back a plain Element,
	--- which has no `Select`; SolLua's cast (`RmlUi.Element.As.ElementFormControlInput`) gives
	--- the input usertype that does. Says once if that fails, rather than leaving the caret
	--- quietly at the end.
	function Graph.selectAllIn(field)
		local ok = pcall(function()
			local input = RmlUi.Element.As.ElementFormControlInput(field)
			input:Select()
		end)
		if not ok and not S.selectAllWarned then
			S.selectAllWarned = true
			echo("this RmlUi build cannot select a field's text from Lua; the rename field keeps the caret at the end")
		end
		return ok
	end

	function Graph.closeNodeRename()
		if not S.nodeRename then
			return false
		end
		S.nodeRename = nil
		local field = el("ng-node-rename-input")
		if field then
			pcall(function()
				field:Blur()
			end)
		end
		render()
		return true
	end

	--- Park the rename field over the node it belongs to.
	function Graph.renderNodeRename()
		local box = el("ng-node-rename")
		if not box then
			return
		end
		local position = S.nodeRename and S.layout and S.layout[S.nodeRename]
		if not position then
			box:SetClass("hidden", true)
			return
		end
		-- IN PLACE, like renaming a folder (PtaQ, 2026-09-26): the field sits exactly over the
		-- node's name, at its size, the width of the title bar's text column.
		local viewport, window = el("ng-graph-viewport"), S.graphWindow
		if viewport and window then
			local left = viewport.absolute_left
				- window.absolute_left
				+ S.graphView.panX
				+ Graph.px(position.x + GRAPH.padX - 4)
			local height = Graph.px(GRAPH.titleBarPx - 6)
			local top = viewport.absolute_top - window.absolute_top + S.graphView.panY + Graph.px(position.y + 3)
			box.style.left = math.floor(left) .. "px"
			box.style.top = math.floor(top) .. "px"
			local field = el("ng-node-rename-input")
			if field then
				field.style.width = Graph.px(GRAPH.nodeWidth - 2 * GRAPH.padX + 8) .. "px"
				field.style.height = height .. "px"
				field.style["line-height"] = (height - 4) .. "px"
				field.style["font-size"] = Graph.px(GRAPH.titlePx) .. "px"
			end
		end
		box:SetClass("hidden", false)
	end

	--- The adapter's wiring rules: may this wire be made, make it, cut it.
	function Graph.canLink(sourceKey, targetKey, port)
		return Graph.adapter.canLink(sourceKey, targetKey, port)
	end

	function Graph.linkNodes(sourceKey, targetKey, port)
		return Graph.adapter.link(sourceKey, targetKey, port)
	end

	function Graph.unlinkNodes(sourceKey, targetKey, port)
		return Graph.adapter.unlink(sourceKey, targetKey, port)
	end

	--- How far outside a node's box a connector can be let go and still land on it, in screen
	--- pixels. Covers the port dot (11px, centred on the edge) with a hand's worth to spare.
	Graph.DROP_SLOP_PX = 18

	--- The node a connector let go at this canvas point would land on, or nil.
	---
	--- A drop ON the port dot counts. The dot sits half outside its node's box, so the box alone
	--- missed it and the release opened the create palette instead of connecting. The tolerance
	--- is in SCREEN pixels, divided by the zoom, so it is as forgiving at 40% as at 200%.
	function Graph.dropTargetAt(cx, cy)
		local zoom = (S.graphView and S.graphView.zoom) or 1
		return Graph.nodeAt(cx, cy) or Graph.nodeAt(cx, cy, Graph.DROP_SLOP_PX / zoom)
	end

	--- Say what the pointer is over, or what a drop in flight would do.
	---
	--- Its OWN element, not the status line. It used to overwrite the node and edge counts, so
	--- hovering a connector hid how big the graph was, and anything reading that line got whichever
	--- of the two happened to be in it.
	function Graph.setHint(text)
		setText("ng-graph-hint", text or "")
	end

	--- Which way round a drop would be wired, given the drag in flight and the node under it.
	---@return string|nil sourceKey, string|nil targetKey
	function Graph.dropEnds(drag, candidateKey)
		if not (drag and candidateKey) then
			return nil, nil
		end
		if drag.fixedIsSource then
			return drag.fixedKey, candidateKey
		end
		return candidateKey, drag.fixedKey
	end

	--- Light up every node the wire in flight could legally land on, and quiet the rest.
	---
	--- The rules stop being something a designer learns by being refused. It asks `canLink` once
	--- per node, which on the largest mission in the tree is 75 calls on the frame a drag starts
	--- and none after that.
	---@param on boolean false to take all the marks off again
	function Graph.markLegalTargets(on)
		local drag = S.portDrag
		for key in pairs(S.layout or {}) do
			local element = el(Graph.nodeElementId(key))
			if element then
				local legal, quiet = false, false
				if on and drag then
					local sourceKey, targetKey = Graph.dropEnds(drag, key)
					legal = Graph.canLink(sourceKey, targetKey, drag.port) == true
					-- The node the wire is coming FROM is neither. Fading the end somebody is
					-- dragging out of would read as though the gesture had gone wrong.
					quiet = not legal and key ~= drag.fixedKey
				end
				element:SetClass("ng-node-legal", legal)
				element:SetClass("ng-node-illegal", quiet)
			end
		end
	end

	--- Mark the node a drop would land on, and take the mark off the last one.
	function Graph.highlightDropTarget(key)
		local drag = S.portDrag
		if not drag or drag.hoverKey == key then
			return
		end
		if drag.hoverKey then
			local previous = el(Graph.nodeElementId(drag.hoverKey))
			if previous then
				previous:SetClass("ng-node-drop", false)
			end
		end
		drag.hoverKey = key
		if key then
			local element = el(Graph.nodeElementId(key))
			if element then
				element:SetClass("ng-node-drop", true)
			end
		end
	end

	--- Pull a connector off a port.
	---
	--- Dragging from an OUTPUT starts a new connector looking for something to fire. Dragging
	--- from an INPUT that already carries exactly ONE connector picks that connector up instead,
	--- which is how one gets moved to a different source; with several the choice would be a
	--- guess, so a new one is started backwards and the drop supplies the source.
	---@param name string|nil which named output it was pulled off, for a node with more than one
	function Graph.beginPortDrag(key, side, pointerX, pointerY, name)
		-- Starting another connector abandons whatever the last one was asking for.
		if S.palette then
			Graph.closePalette()
		end
		local wantFrom = side == "out"
		-- Whether this node has an output at all, asked of the port list rather than of a hand
		-- written set of kinds. That set said "a trigger, or an action that is an EnableTrigger",
		-- and stopped being true the moment stages, objectives and the objective actions grew
		-- ports: every one of them DREW a dot that refused to be dragged.
		if wantFrom and #Graph.outPortsOf(key) == 0 then
			return
		end

		-- Pulling a wire OFF a port rather than starting a new one. Both cases are "this port
		-- holds exactly one wire, so there is no ambiguity about which":
		--   * any input port with a single connector arriving at it, and
		--   * a single-wire output, which is an action's parameter or one of an objective's six
		--     fields, and can never hold more than one.
		-- Picking it up is what makes re-pointing and severing the same gesture.
		local pickedUp
		if side == "in" or Graph.portIsSingle(key, name) then
			local touching = {}
			for _, edge in ipairs((S.graphEdgesByNode or {})[key] or {}) do
				local mine = (wantFrom and edge.from == key) or (not wantFrom and edge.to == key)
				-- Only the wires that left THIS port. Without it, grabbing `onFailed` on an
				-- objective with one hook set anywhere would pick that other hook's wire up.
				if mine and wantFrom and edge.port ~= name then
					mine = false
				end
				if mine then
					touching[#touching + 1] = edge
				end
			end
			if #touching == 1 then
				pickedUp = touching[1]
			end
		end

		-- A press on a port is INSIDE a node, and the node is draggable too. Both gestures used
		-- to start and the box came along with the connector.
		--
		-- Stopping the event was not enough: the node's listeners run anyway. So the state
		-- decides instead of the propagation -- the connector takes the gesture outright and
		-- drops any node grab the same press began. That holds whichever order the two
		-- listeners happen to run in, which is the part that cannot be relied on.
		S.graphDrag = nil

		-- The end that stays put. Dragging off an OUT port always leaves the source fixed and the
		-- target loose; dragging off an IN port picks the wire up by its target, so what stays is
		-- the far end it came from.
		local fixedKey, fixedIsSource
		if side == "out" then
			fixedKey, fixedIsSource = key, true
		elseif pickedUp then
			fixedKey, fixedIsSource = pickedUp.from, true
		else
			fixedKey, fixedIsSource = key, false
		end

		S.portDrag = {
			fixedKey = fixedKey,
			fixedIsSource = fixedIsSource,
			pickedUp = pickedUp,
			hoverKey = nil,
			-- Which named output the wire belongs to. A drag off an OUT port is the port itself; a
			-- wire picked up by its far end keeps the port it was written from, so re-pointing
			-- `onCompleted` still writes `onCompleted` and not whichever field a guess would pick.
			port = wantFrom and name or (pickedUp and pickedUp.port) or nil,
		}
		-- The port's NAME, laid along the wire while it is in flight: an unwired port's name only
		-- shows while its node is hovered, and a wire pulled off one has left the hover behind.
		-- A wire picked up off a wired port keeps its name on show at the node instead.
		if fixedIsSource and S.portDrag.port and not pickedUp then
			for _, entry in ipairs(Graph.outPortsOf(fixedKey)) do
				if entry.name == S.portDrag.port then
					S.portDrag.label = entry.label and entry.label:upper()
				end
			end
		end
		-- Classes only, no markup: this runs inside the mousedown that started the drag, and
		-- rebuilding the canvas there is the crash this panel has already paid for once.
		Graph.markLegalTargets(true)
		Graph.setHint(
			pickedUp and (Graph.describeEdge(pickedUp) .. " -- drop on empty canvas to cut it")
				or "drop on a node to connect"
		)
		if pointerX then
			Graph.dragPortTo(pointerX, pointerY)
		end
	end

	--- Lay the live connector between its fixed end and the pointer, and mark what it is over.
	function Graph.dragPortTo(pointerX, pointerY)
		local drag = S.portDrag
		if not drag then
			return
		end
		local cx, cy = Graph.canvasPoint(pointerX, pointerY)
		if not cx then
			return
		end
		local fixed = S.layout and S.layout[drag.fixedKey]
		if not fixed then
			return
		end

		local over = Graph.dropTargetAt(cx, cy)
		if over ~= drag.hoverKey then
			-- Only when it CHANGES. The status line is a text write and this runs on every drag
			-- event; rewriting the same string sixty times a second is work for nothing.
			if over then
				local sourceKey, targetKey = Graph.dropEnds(drag, over)
				local _, message = Graph.canLink(sourceKey, targetKey, drag.port)
				Graph.setHint(message)
			elseif drag.pickedUp then
				Graph.setHint(Graph.describeEdge(drag.pickedUp) .. " -- drop on empty canvas to cut it")
			else
				Graph.setHint("drop on a node to connect")
			end
		end
		Graph.highlightDropTarget(over)

		-- The free end is wherever the pointer is; the fixed end keeps the anchor its side
		-- would have used, so a connector being re-pointed keeps the shape it had.
		local points
		if drag.fixedIsSource then
			local x0, y0 = Graph.outAnchor(
				fixed,
				Graph.heightOf(drag.fixedKey),
				Graph.portY(drag.fixedKey, "out", drag.port),
				-- A picked-up wire still leaves from the end of its port's name, which stays on
				-- show until the drop.
				drag.pickedUp and Graph.portX(drag.fixedKey, drag.port) or 0
			)
			points = Graph.curveBetween(x0, y0, cx, cy, Graph.LIVE_SEGMENTS)
		else
			local x3, y3 = Graph.inAnchor(fixed, Graph.heightOf(drag.fixedKey))
			points = Graph.curveBetween(cx, cy, x3, y3, Graph.LIVE_SEGMENTS)
		end
		if not points then
			Graph.hideLiveEdge()
			return
		end
		for segment = 1, Graph.LIVE_SEGMENTS do
			local element = el(Graph.liveSegmentId(segment))
			if element then
				local left, top, width, angle = Graph.segmentStyle(points[segment], points[segment + 1])
				-- The same caps as a settled connector, or the one being dragged reads as a
				-- different kind of line from the ones it is about to join.
				local drawn = math.max(1, Graph.px(GRAPH.edgePx))
				element.style.left = Graph.px(left) .. "px"
				element.style.top = Graph.px(top) .. "px"
				element.style.width = Graph.px(width) .. "px"
				element.style.height = drawn .. "px"
				element.style["border-radius"] = math.max(1, math.floor(drawn / 2)) .. "px"
				element.style.transform = string.format("rotate(%.2fdeg)", angle)
				element:SetClass("hidden", false)
			end
		end
		Graph.layLiveLabel(points, drag.label)
	end

	--- Drop it. This is where the picture becomes an edit.
	function Graph.endPortDrag()
		local drag = S.portDrag
		Graph.setHint("")
		Graph.markLegalTargets(false)
		S.portDrag = nil
		Graph.hideLiveEdge()
		if not drag then
			return
		end
		if drag.hoverKey then
			local element = el(Graph.nodeElementId(drag.hoverKey))
			if element then
				element:SetClass("ng-node-drop", false)
			end
		end

		local targetKey = drag.hoverKey
		if not targetKey then
			-- Dropped on empty canvas, and what that means depends on which drag this was.
			--
			-- A wire that was PICKED UP off a port has been carried away and put down on nothing,
			-- which is how a designer cuts one: the gesture reads as taking it out. A wire that
			-- was STARTED from a bare port has no far end yet, so letting go over nothing simply
			-- abandons it (and is where the create palette hangs).
			if drag.pickedUp then
				Graph.severEdge(drag.pickedUp)
			else
				-- The wire is kept alive across the palette rather than thrown away: `drag` still
				-- knows the end that is anchored, and that is what the new node gets wired to.
				local px, py = Graph.pointerScreen()
				if not Graph.openPalette(px, py, drag) then
					echo("connector dropped on empty canvas; nothing changed")
					render()
				end
			end
			return
		end

		local sourceKey, sinkKey
		if drag.fixedIsSource then
			sourceKey, sinkKey = drag.fixedKey, targetKey
		else
			sourceKey, sinkKey = targetKey, drag.fixedKey
		end

		local picked = drag.pickedUp
		if picked and picked.from == sourceKey and picked.to == sinkKey then
			render()
			return
		end

		local ok, message = Graph.linkNodes(sourceKey, sinkKey, drag.port)
		if ok then
			-- Only now: a re-point that could not be made must not leave the connector deleted.
			if picked then
				Graph.unlinkNodes(picked.from, picked.to, picked.port)
			end
			Graph.host.edited()
			Graph.host.analyse()
		end
		echo(message)
		render()
	end
end
