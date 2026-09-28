-- THE GRAPH'S NODES AND KEYS (P1 stage H3, 2026-09-27): the keyboard's keycodes, the kind
-- chips, the automatic and FIT layouts, the canvas size, moving a node, and the node drag. They
-- were locals of gui_mission_editor.lua handed to the other controllers as dependencies; here
-- they are `Graph.*`, read when called, so a host builds this with the rest and passes nothing.

---@param deps table
return function(deps)
	local Graph = deps.Graph
	local Bind = deps.Bind
	local GRAPH = deps.GRAPH
	local S = deps.S
	local echo = deps.echo
	local el = deps.el
	local nodeKey = deps.nodeKey
	local render = deps.render
	for _, name in ipairs({ "Graph", "Bind", "GRAPH", "S", "echo", "el", "nodeKey", "render" }) do
		assert(deps[name] ~= nil, "ctl/nodes: missing dependency " .. name)
	end

	--- Keycodes for the graph's own keyboard.
	---
	--- Written out rather than read from `KEYSYMS`: the engine ships a `keysym.h.lua` that is
	--- included into an empty environment, so a widget reading that table gets nil for everything
	--- and every shortcut silently does nothing forever. On the table, not in a global, because
	--- LuaUI's environment is shared.
	---
	--- **These are SDL 1.2 numbers, which is what Recoil's own header uses**: LEFT is 276 and
	--- HOME is 278. They were written as SDL2 (1073741904, 1073741898) and every arrow and Home
	--- silently did nothing. The ASCII ones agree in both families, which is why Escape, Delete,
	--- Tab and the letters looked as though they should have worked.
	Graph.KEY = {
		escape = 27,
		del = 127,
		backspace = 8,
		a = 97,
		c = 99,
		d = 100,
		f = 102,
		g = 103,
		h = 104,
		m = 109,
		v = 118,
		-- Ctrl+X / Ctrl+Y / Ctrl+Z: cut, redo, undo.
		x = 120,
		y = 121,
		z = 122,
		-- `[` and `]`, which grow the selection along the wires.
		leftBracket = 91,
		rightBracket = 93,
		home = 278,
		left = 276,
		right = 275,
		up = 273,
		down = 274,
	}

	--- The SDL2 spelling of the ones that differ, accepted as well.
	---
	--- Both, rather than picking a side, because this file already carried
	--- `RETURN_KEYS = { [13] = true, [1073741912] = true }`: 1073741912 is SDL2's keypad Enter,
	--- so somebody once watched an SDL2 value arrive at this very call-in. Accepting both costs a
	--- comparison and removes a whole class of "the key does nothing and nothing says why".
	Graph.KEY_ALSO = {
		home = 1073741898,
		left = 1073741904,
		right = 1073741903,
		up = 1073741906,
		down = 1073741905,
	}

	--- Is this the key called `name`, in either numbering?
	function Graph.isKey(name, key)
		return key == Graph.KEY[name] or key == Graph.KEY_ALSO[name]
	end

	--- Every node kind on the canvas, its records and its paint order are the ADAPTER's
	--- (`Graph.adapter.kinds`, `Graph.adapter.records(kind)`; stage G1). ONE list: the layout, FIT,
	--- the search, framing, the height pass, the paint and the event wiring all read it, because a
	--- kind present in one copy and missing from another is not left where it was, it is dropped.

	--- Is this one of the kinds the canvas draws?
	--- The kind chips (FIND's and the palette's), one per `adapter.kinds` entry, as the bound
	--- list `graphKinds`. A kind may name itself with `label` (the palette) and `short` (FIND);
	--- otherwise its name is used. Reassigned only when something in it changed, because a new
	--- table makes RmlUi rebuild every chip.
	--- How many kind chips are bound, whatever the adapter declares.
	Graph.KIND_SLOTS = 8
	function Graph.blankKind()
		return {
			kind = "",
			label = "",
			short = "",
			find = false,
			findId = "",
			findTitle = "",
			paletteId = "",
			palette = false,
			disabled = false,
			blank = true,
		}
	end

	function Graph.syncKindChips()
		local m = Graph.model
		if not m then
			return
		end
		local palette = S.palette
		local available = palette and Graph.paletteKindsAvailable() or {}
		local rows, signature = {}, {}
		for _, entry in ipairs(Graph.adapter.kinds) do
			local kind = entry.kind
			local label = entry.label or kind:upper()
			local row = {
				kind = kind,
				label = label,
				short = entry.short or label:sub(1, 3),
				find = S.findKinds[kind] == true,
				findId = "ng-find-" .. kind,
				findTitle = "Pick out every " .. kind,
				paletteId = "ng-palette-kind-" .. kind,
				palette = palette ~= nil and palette.kind == kind,
				disabled = palette ~= nil and not available[kind],
				blank = false,
			}
			rows[#rows + 1] = row
			signature[#signature + 1] = string.format(
				"%s|%s|%s|%s|%s|%s",
				kind,
				row.label,
				row.short,
				tostring(row.find),
				tostring(row.palette),
				tostring(row.disabled)
			)
		end
		-- Fixed length (Gap 11): another adapter can declare fewer kinds, and a bound list that
		-- shrinks floods binding warnings. The blanks are hidden.
		for index = #rows + 1, Graph.KIND_SLOTS do
			rows[index] = Graph.blankKind()
		end
		signature = table.concat(signature, ";")
		if signature ~= S.kindChipsSignature then
			S.kindChipsSignature = signature
			m.graphKinds = rows
		end
	end

	--- A palette kind chip pressed. Bound.
	function Graph.bound.graphPaletteKind(_, kind)
		Graph.setPaletteKind(kind)
	end

	function Graph.isNodeKind(kind)
		for _, entry in ipairs(Graph.adapter.kinds) do
			if entry.kind == kind then
				return true
			end
		end
		return false
	end

	--- Geometry in core.lua (Graph.lib); this passes the widget's state in.
	function Graph.autoLayout()
		return Graph.adapter.layout(function(kind, entry)
			return Graph.measureNode(nodeKey(kind, entry.id), Graph.rowsFor(kind, entry))
		end)
	end

	--- Gives a position to any node that does not have one yet, leaving the placed ones alone.
	---
	--- A trigger added after the layout was built was **never drawn**: Graph.render only builds a
	--- layout when there is none at all, and nodeMarkup skips a node with no position, so the
	--- status line counted a node the canvas did not show. Recomputing the whole layout instead
	--- would be correct and would throw away the arrangement the designer dragged into place, so
	--- new nodes are stacked under the last one of their own kind.
	---@return number placed
	function Graph.placeNewNodes()
		if not Graph.host.hasDocument() then
			return 0
		end
		S.layout = S.layout or {}

		-- Where each band currently sits, and how far down it reaches.
		local band = {}
		for _, section in ipairs(Graph.adapter.kinds) do
			band[section.kind] = { x = nil, bottom = nil }
		end
		for _, section in ipairs(Graph.adapter.kinds) do
			for _, record in ipairs(Graph.adapter.records(section.kind)) do
				local position = S.layout[nodeKey(section.kind, record.id)]
				if position then
					local slot = band[section.kind]
					slot.x = slot.x and math.min(slot.x, position.x) or position.x
					slot.bottom = slot.bottom and math.max(slot.bottom, position.y) or position.y
				end
			end
		end

		-- An empty band falls back to where Graph.autoLayout would have put it.
		local fallback = Graph.autoLayout()
		local placed = 0
		-- EVERY kind, stages and objectives included. This ran over triggers and actions alone, so
		-- a stage or an objective added after the layout existed was given no position -- and the
		-- renderer silently skips a node that has none, so the status line counted a node the
		-- canvas did not show.
		for _, section in ipairs(Graph.adapter.kinds) do
			local kind = section.kind
			local slot = band[kind]
			for _, record in ipairs(Graph.adapter.records(kind)) do
				local key = nodeKey(kind, record.id)
				if not S.layout[key] then
					local spot = fallback[key] or { x = GRAPH.padding, y = GRAPH.padding }
					local x = slot.x or spot.x
					local y = slot.bottom and (slot.bottom + GRAPH.rowGap) or spot.y
					S.layout[key] = { x = x, y = y }
					slot.x = x
					slot.bottom = y
					placed = placed + 1
				end
			end
		end
		return placed
	end

	--- Packs every node into the viewport, in as many columns as it takes.
	---
	--- The viewport clips and does not scroll, so a node outside it cannot be reached at all --
	--- not to click, not to drag. FIT is what gets them back, and it is the only way to see a
	--- 75-node mission whole.
	function Graph.fitLayout()
		local viewport = el("ng-graph-viewport")
		if not (viewport and Graph.host.hasDocument()) then
			return nil
		end
		local width = math.max(viewport.offset_width - GRAPH.padding, GRAPH.nodeWidth + GRAPH.padding)
		local height = math.max(viewport.offset_height - GRAPH.padding, GRAPH.nodeHeight + GRAPH.padding)

		-- The adapter's kinds, and it has to be: `S.layout` is REPLACED with what comes back, so a
		-- kind left out of it is dropped from the canvas entirely. That is what happened the first
		-- time objectives became nodes -- they drew fine until somebody pressed FIT, and then they
		-- were gone -- and it is why there is now one list rather than a copy per caller.
		local nodes = {}
		for _, section in ipairs(Graph.adapter.kinds) do
			for _, record in ipairs(Graph.adapter.records(section.kind)) do
				nodes[#nodes + 1] = nodeKey(section.kind, record.id)
			end
		end
		if #nodes == 0 then
			return {}
		end

		-- Shrink the step until the whole lot fits, rather than picking a column count and
		-- hoping. Nodes overlap at the tightest settings, which beats being off screen.
		local columnGap, rowGap = GRAPH.columnGap, GRAPH.rowGap
		local columns, rows
		for _ = 1, 24 do
			columns = math.max(1, math.floor(width / columnGap))
			rows = math.ceil(#nodes / columns)
			if GRAPH.padding + rows * rowGap <= height then
				break
			end
			-- These floors are low on purpose. At the tightest settings the nodes overlap, and
			-- overlapping beats being off screen: the viewport clips and does not scroll, so a
			-- node outside it cannot be clicked, dragged or even seen. They were 0.34 and 0.55 and
			-- stopped being enough the moment the nodes grew.
			columnGap = math.max(GRAPH.nodeWidth * 0.22, columnGap * 0.88)
			rowGap = math.max(GRAPH.nodeHeight * 0.28, rowGap * 0.88)
		end

		local layout = {}
		for index, key in ipairs(nodes) do
			layout[key] = {
				x = GRAPH.padding + ((index - 1) % columns) * columnGap,
				y = GRAPH.padding + math.floor((index - 1) / columns) * rowGap,
			}
		end
		return layout
	end

	-- (Looking at the canvas: zoom, pan and the minimap: moved to ctl/view.lua)

	--- The canvas has to be told how big it is, or the viewport has nothing to scroll over
	--- and everything below the fold is simply unreachable.
	function Graph.sizeCanvas()
		local canvas = el("ng-graph-canvas")
		if not canvas then
			return
		end
		local maxX, maxY = 0, 0
		for key, position in pairs(S.layout or {}) do
			maxX = math.max(maxX, position.x + GRAPH.nodeWidth)
			maxY = math.max(maxY, position.y + Graph.heightOf(key))
		end
		-- A frame drawn round the outermost nodes sticks out past them, and a canvas sized to the
		-- nodes alone would clip its edge off.
		for _, frame in ipairs(Graph.commentsIfAny()) do
			maxX = math.max(maxX, (tonumber(frame.x) or 0) + (tonumber(frame.w) or 0))
			maxY = math.max(maxY, (tonumber(frame.y) or 0) + (tonumber(frame.h) or 0))
		end
		S.graphView.contentW = maxX + GRAPH.padding
		S.graphView.contentH = maxY + GRAPH.padding
		-- THE GRAPH'S OWN EXTENT, kept before the clamp below widens it. The two are different
		-- things and the minimap needs this one: `contentW` is padded out to whatever the viewport
		-- covers, which depends on the ZOOM, so a map scaled from it zoomed out whenever the main
		-- view did. What the map is a picture of only changes when a node moves.
		S.graphView.graphW = S.graphView.contentW
		S.graphView.graphH = S.graphView.contentH
		-- Never smaller than what is on screen. A canvas that stopped at the last node left bare
		-- viewport around it that belonged to nothing, so a press there did not pan -- the graph
		-- felt walled in at its top-left corner. Divided by the zoom because this is a canvas
		-- measurement and the viewport's is a screen one.
		local viewport = el("ng-graph-viewport")
		if viewport and viewport.offset_width > 0 and S.graphView.zoom > 0 then
			S.graphView.contentW = math.max(S.graphView.contentW, viewport.offset_width / S.graphView.zoom)
			S.graphView.contentH = math.max(S.graphView.contentH, viewport.offset_height / S.graphView.zoom)
		end
		canvas.style.width = Graph.px(S.graphView.contentW) .. "px"
		canvas.style.height = Graph.px(S.graphView.contentH) .. "px"
		Graph.applyGraphView()
	end

	-- (Node rows, ports, connector geometry and styling: moved to ctl/canvas.lua)

	--- The element id Graph.render gives a node. Record ids are plain identifiers, so they carry
	--- no hyphen and `<kind>-<id>` cannot be ambiguous.
	function Graph.nodeElementId(key)
		return "ng-gnode-" .. (key:gsub(":", "-", 1))
	end

	--- Moves a node in the layout. The one place that writes a node position, so the drag and
	--- anything else that ever moves a node agree about clamping and about the fact that the
	--- layout is saved state.
	---@return boolean moved
	function Graph.moveNode(key, x, y)
		if not (S.layout and S.layout[key]) then
			return false
		end
		-- Anywhere, including negative. The canvas used to refuse it, because it is sized from
		-- the furthest node and anything at a negative offset would have been off the edge of it
		-- with no way back. `Graph.settleLayout` removes that reason instead: after the drag the
		-- whole layout is re-based so its top-left corner is the origin again.
		x = math.floor(x)
		y = math.floor(y)
		local position = S.layout[key]
		if position.x == x and position.y == y then
			return false
		end
		position.x, position.y = x, y
		return true
	end

	--- Redraws one node and the edges touching it, by writing styles rather than markup.
	---
	--- A drag cannot rebuild the canvas: replacing its inner_rml would destroy the element RmlUi
	--- is dispatching to, which is the crash this panel already paid for once, and it would be
	--- per-frame DOM churn besides. So the handful of elements that actually moved are nudged,
	--- and the canvas is rebuilt once on drop.
	function Graph.refreshNodeElements(key)
		local position = S.layout and S.layout[key]
		if not position then
			return
		end
		local node = el(Graph.nodeElementId(key))
		if node then
			node.style.left = Graph.px(position.x) .. "px"
			node.style.top = Graph.px(position.y) .. "px"
		end
		-- The ports need nothing here: they are children of the node, so moving the node moves
		-- them. Writing canvas positions onto them, as this used to, dragged them out of the
		-- box they live in.

		-- NOTE for the re-curve below: the heights come from `Graph.heightOf`, so a connector
		-- touching an expanded node still meets it in the middle of the box rather than in the
		-- middle of where the box used to be.
		-- Every connector that touches this node is re-curved, not merely re-aimed: the control
		-- points move with the ends, so the shape changes as the node is dragged. The bar count
		-- is the one the connector was built with, so there is never a bar left over pointing at
		-- where the node used to be.
		for _, edge in ipairs((S.graphEdgesByNode or {})[key] or {}) do
			local count = (S.graphEdgeSegments or {})[edge.index]
			if count then
				local points = Graph.edgeCurve(
					S.layout[edge.from],
					S.layout[edge.to],
					count,
					Graph.heightOf(edge.from),
					Graph.heightOf(edge.to),
					-- A named port's wire leaves its own dot, not the middle of the node, and from
					-- the end of its name.
					Graph.portY(edge.from, "out", edge.port),
					Graph.portX(edge.from, edge.port)
				)
				for segment = 1, count do
					local element = el(Graph.segmentElementId(edge.index, segment))
					if element then
						if points then
							local left, top, width, angle = Graph.segmentStyle(points[segment], points[segment + 1])
							-- Position and length only. The thickness and the cap were written when
							-- the bar was built and a drag does not change either.
							element.style.left = Graph.px(left) .. "px"
							element.style.top = Graph.px(top) .. "px"
							element.style.width = Graph.px(width) .. "px"
							element.style.transform = string.format("rotate(%.2fdeg)", angle)
							element:SetClass("hidden", false)
						else
							-- The two nodes overlap, so there is no curve to draw. Hiding beats
							-- leaving a stale one pointing at where the node used to be.
							element:SetClass("hidden", true)
						end
					end
				end
			end
		end
	end

	--- Starts dragging a node, from RmlUi's own dragstart.
	---
	--- **Spring.GetMouseState cannot be used here.** MouseHandler::MousePress returns the moment
	--- RmlGui::ProcessMousePress reports the press handled, BEFORE it records the button, so a
	--- press that lands on an RmlUi element never sets `buttons[LEFT].pressed` and the engine
	--- reports the left button as up for the whole drag. A per-frame tick that treated the
	--- button as the authority therefore ended the drag on its very next frame: the node moved
	--- by whatever the first drag event carried, and let go.
	---
	--- So the pointer comes from the events, which carry it, and the drag ends when RmlUi says
	--- it ends. The floating windows get away with polling only because their helper never
	--- looks at the button either -- it stops on the document's mouseup.
	---
	--- `pointerX`/`pointerY` are RmlUi's top-down screen pixels.
	function Graph.beginNodeDrag(key, pointerX, pointerY)
		if not (S.layout and S.layout[key]) then
			return
		end
		local startX, startY = S.layout[key].x, S.layout[key].y

		-- EVERYTHING THAT MOVES WITH IT. A node dragged out of a multi-selection carries the rest
		-- of the selection: the arrows have moved the whole selection since they were written, and
		-- a mouse that moved only the box under the pointer was the odd one out.
		--
		-- A node that is NOT in the selection carries only itself, which is what every other editor
		-- does, and the click that follows the drag selects it anyway.
		--
		-- Membership is decided ONCE, here, exactly as a grouping's is: recomputing it per frame
		-- would let the selection change underneath a drag that is already running.
		local members = {}
		if #S.graphSel > 1 and Graph.isSelected(key) then
			for _, other in ipairs(S.graphSel) do
				local position = other ~= key and S.layout[other]
				if position then
					members[#members + 1] = {
						key = other,
						dx = position.x - startX,
						dy = position.y - startY,
					}
				end
			end
		end

		-- A new press. Whatever the last one ended as is no longer true of this one.
		S.graphDragMoved = nil
		S.graphDrag = {
			key = key,
			grabX = pointerX,
			grabY = pointerY,
			startX = startX,
			startY = startY,
			members = members,
			moved = false,
		}
		if S.graphDebug then
			echo(string.format("drag start %s at %s,%s", key, tostring(pointerX), tostring(pointerY)))
		end
	end

	--- Moves the node being dragged to follow a pointer, in RmlUi's top-down screen pixels.
	function Graph.dragNodeTo(pointerX, pointerY)
		local drag = S.graphDrag
		if not drag then
			return
		end
		-- Screen pixels into canvas pixels: at 50% zoom the pointer covers twice the canvas
		-- per pixel, and without this the node lags or races the cursor.
		local zoom = S.graphView.zoom
		local x = drag.startX + (pointerX - drag.grabX) / zoom
		local y = drag.startY + (pointerY - drag.grabY) / zoom
		if Graph.moveNode(drag.key, x, y) then
			drag.moved = true
			Graph.refreshNodeElements(drag.key)
		end
		-- The rest of the selection keeps the offset it had from the node under the pointer, so a
		-- group of nodes arrives at the far end of the drag in the arrangement it left in.
		for _, member in ipairs(drag.members or {}) do
			if Graph.moveNode(member.key, x + member.dx, y + member.dy) then
				drag.moved = true
				Graph.refreshNodeElements(member.key)
			end
		end
	end

	--- Ends the drag. A grab that never moved is just a click, and the click handler has already
	--- selected the node, so nothing is marked dirty for it.
	function Graph.endNodeDrag()
		local drag = S.graphDrag
		if not drag then
			return
		end
		S.graphDrag = nil
		-- RmlUi raises `click` at the end of a drag as well, and the node's click handler replaces
		-- the selection with the one node clicked. After dragging six nodes across the canvas that
		-- reads as the selection collapsing the instant the button comes up. The flag is consumed
		-- by that click and cleared by the next press either way, so it cannot go stale if a
		-- particular gesture turns out not to raise one.
		S.graphDragMoved = drag.moved or nil
		if S.graphDebug then
			echo(string.format("drag end %s, moved=%s", tostring(drag.key), tostring(drag.moved)))
		end
		if not drag.moved then
			return
		end
		-- The layout is saved state, so a moved node is an unsaved change like any other.
		Graph.host.edited()
		Graph.normaliseLayout()
		Graph.sizeCanvas()
		render()
	end
end
