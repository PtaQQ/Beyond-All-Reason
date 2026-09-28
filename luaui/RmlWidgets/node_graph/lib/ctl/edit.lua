-- The GRAPH window's editing controller: the canvas selection, the marquee, search and
-- framing, nudge/align/distribute, node clicks, the selection verbs (grow, quick connect,
-- duplicate, delete) and `Graph.handleAction`, the dispatch every canvas key and button
-- goes through (refactor plan, Phase 3.3, GRAPH slice 1).
--
-- Same shape as me_ctl_file.lua, a constructor handed exactly what it uses, with one
-- difference: it FILLS the `Graph` table it is given instead of returning a new one.
-- `Graph` is the namespace the timeline and the rest of the widget read too, so it has to
-- exist from file scope; this adds its functions to it in `widget:Initialize`.
--
--     VFS.Include(".../ctl/edit.lua")(deps)

---@param deps table
return function(deps)
	local Graph = deps.Graph
	local Bind = deps.Bind
	local GRAPH = deps.GRAPH
	local S = deps.S
	local deepCopy = deps.deepCopy
	local echo = deps.echo
	local el = deps.el
	local nodeKey = deps.nodeKey
	local render = deps.render
	for _, name in ipairs({ "Graph", "Bind", "GRAPH", "S", "deepCopy", "echo", "el", "nodeKey", "render" }) do
		assert(deps[name] ~= nil, "ctl/edit: missing dependency " .. name)
	end

	--------------------------------------------------------------------------------
	-- The canvas selection
	--------------------------------------------------------------------------------

	--- The selection as a lookup, rebuilt on demand rather than kept beside the list.
	---
	--- A second copy that has to be maintained is a second copy that goes stale, and a mission
	--- graph is tens of nodes, not thousands: one pass per render costs nothing measurable.
	function Graph.selectionSet()
		local set = {}
		for _, key in ipairs(S.graphSel) do
			set[key] = true
		end
		return set
	end

	function Graph.isSelected(key)
		for _, existing in ipairs(S.graphSel) do
			if existing == key then
				return true
			end
		end
		return false
	end

	--- The selection changed: the adapter points its inspector at it (a mission: the last
	--- node picked of each kind).
	function Graph.syncPrimary()
		Graph.adapter.syncInspector(S.graphSel)
	end

	--- Replace the selection outright. `keys` may be a single key or a list.
	function Graph.setSelection(keys)
		if type(keys) == "string" then
			keys = { keys }
		end
		S.graphSel = {}
		for _, key in ipairs(keys or {}) do
			-- No check that the node has a layout entry. A record selected from a list before the
			-- graph window has ever been opened has none yet, and dropping it here would leave the
			-- canvas showing nothing selected the first time it was opened.
			if not Graph.isSelected(key) then
				S.graphSel[#S.graphSel + 1] = key
			end
		end
		S.graphSelEdge = nil
		-- A frame and a node selection are never both live: Delete has to be unambiguous.
		S.graphSelComment = nil
		Graph.syncPrimary()
	end

	--- Add a node, or take it back out if it is already in. Ctrl-click.
	function Graph.toggleSelected(key)
		for index, existing in ipairs(S.graphSel) do
			if existing == key then
				table.remove(S.graphSel, index)
				return false
			end
		end
		S.graphSel[#S.graphSel + 1] = key
		S.graphSelEdge = nil
		Graph.syncPrimary()
		return true
	end

	--- Add without removing. Shift-click.
	function Graph.addSelected(key)
		if not Graph.isSelected(key) then
			S.graphSel[#S.graphSel + 1] = key
			S.graphSelEdge = nil
			Graph.syncPrimary()
		end
	end

	--- Nothing selected on the canvas. `S.selected` is deliberately left alone; see syncPrimary.
	function Graph.clearSelection()
		S.graphSel = {}
		S.graphSelEdge = nil
		S.graphSelComment = nil
	end

	--- Carry everything keyed by a node id across a rename.
	---
	--- `Document.Rename` already moves the saved position inside `doc.layout`, but the canvas
	--- works from `S.layout`, which is a DIFFERENT table whenever the layout was built by
	--- `Graph.autoLayout` rather than read from the file. So the renamed node had no position, and
	--- `Graph.placeNewNodes` dropped it underneath the last node of its kind: renaming a trigger threw
	--- away wherever it had been dragged to.
	---
	--- The selection is keyed the same way and needs the same treatment, or a renamed node
	--- quietly stops being selected.
	function Graph.renameNodeKey(kind, oldId, newId)
		local oldKey, newKey = nodeKey(kind, oldId), nodeKey(kind, newId)
		if S.layout and S.layout[oldKey] then
			S.layout[newKey] = S.layout[oldKey]
			S.layout[oldKey] = nil
		end
		for index, key in ipairs(S.graphSel) do
			if key == oldKey then
				S.graphSel[index] = newKey
			end
		end
		local edge = S.graphSelEdge
		if edge then
			if edge.from == oldKey then
				edge.from = newKey
			end
			if edge.to == oldKey then
				edge.to = newKey
			end
		end
	end

	--- Drop anything in the selection that no longer exists, after a delete or a reload.
	function Graph.pruneSelection()
		local kept = {}
		for _, key in ipairs(S.graphSel) do
			local kind, id = Graph.splitKey(key)
			if kind and Graph.adapter.find(kind, id) then
				kept[#kept + 1] = key
			end
		end
		S.graphSel = kept
		local edge = S.graphSelEdge
		if edge then
			local fromKind, fromId = Graph.splitKey(edge.from)
			local toKind, toId = Graph.splitKey(edge.to)
			if
				not (fromKind and Graph.adapter.find(fromKind, fromId) and toKind and Graph.adapter.find(toKind, toId))
			then
				S.graphSelEdge = nil
			end
		end
	end

	--------------------------------------------------------------------------------
	-- The marquee
	--------------------------------------------------------------------------------

	--- Is space held? Space-drag pans, which is the gesture people try first because Figma and
	--- Blender both have it, and it is what leaves the plain left drag free for the marquee.
	---
	--- The raw keycode rather than `KEYSYMS`: the engine ships a `keysym.h.lua` that is included
	--- into an empty environment, so reading KEYSYMS from a widget is not reliably available, and
	--- space is 32 in every table that has ever existed.
	function Graph.spaceHeld()
		local ok, held = pcall(Spring.GetKeyState, 32)
		return ok and held == true
	end

	--- Start a rubber band at a screen point.
	---@param additive boolean|nil keep what was already selected
	function Graph.beginMarquee(pointerX, pointerY, additive)
		if not (pointerX and Graph.inGraphViewport(pointerX, pointerY)) then
			return false
		end
		local _, ctrl, _, shift = Spring.GetModKeyState()
		-- Ctrl or shift adds to what is already selected, so a band can be drawn twice over two
		-- separate clusters. Without a modifier it replaces, which is what a bare drag means.
		local keepExisting = additive == true or ctrl == true or shift == true
		S.graphMarquee = {
			screenX = pointerX,
			screenY = pointerY,
			additive = keepExisting,
			base = keepExisting and deepCopy(S.graphSel) or {},
			-- What was selected before, so a band that turns out to have been a click can put it
			-- back before the click is worked out.
			wasSel = deepCopy(S.graphSel),
			wasEdge = S.graphSelEdge and {
				from = S.graphSelEdge.from,
				to = S.graphSelEdge.to,
				kind = S.graphSelEdge.kind,
			} or nil,
			grew = false,
		}
		return true
	end

	--- The band, and the selection it currently covers. Called on every drag event, so it writes
	--- styles and never markup.
	function Graph.dragMarquee(pointerX, pointerY)
		local band = S.graphMarquee
		local viewport = el("ng-graph-viewport")
		if not (band and viewport and pointerX) then
			return
		end
		local left = math.min(band.screenX, pointerX) - viewport.absolute_left
		local top = math.min(band.screenY, pointerY) - viewport.absolute_top
		local width = math.abs(pointerX - band.screenX)
		local height = math.abs(pointerY - band.screenY)
		-- Below this it is a click that wobbled, not a band. RmlUi starts a drag on the first pixel
		-- of movement with no threshold of its own, so without this a click on a connector began a
		-- marquee whose own drop then cleared the very selection the click was making. That is
		-- almost certainly why Delete on a connector did nothing.
		if width > GRAPH.clickSlopPx or height > GRAPH.clickSlopPx then
			band.grew = true
		end
		if not band.grew then
			return
		end

		local element = el("ng-graph-marquee")
		if element then
			element.style.left = math.floor(left) .. "px"
			element.style.top = math.floor(top) .. "px"
			element.style.width = math.floor(width) .. "px"
			element.style.height = math.floor(height) .. "px"
			element:SetClass("hidden", false)
		end

		-- CROSSING, not containing: a node the band touches is selected. That is what both of the
		-- editors designers arrive here from do, and on a graph whose nodes are 184px wide,
		-- requiring full containment means almost nothing is ever caught.
		local x0, y0 = Graph.canvasPoint(math.min(band.screenX, pointerX), math.min(band.screenY, pointerY))
		local x1, y1 = Graph.canvasPoint(math.max(band.screenX, pointerX), math.max(band.screenY, pointerY))
		if not x0 then
			return
		end
		local keys = {}
		for _, key in ipairs(band.base) do
			keys[#keys + 1] = key
		end
		local already = {}
		for _, key in ipairs(keys) do
			already[key] = true
		end
		for key, position in pairs(S.layout or {}) do
			local touches = position.x <= x1
				and position.x + GRAPH.nodeWidth >= x0
				and position.y <= y1
				and position.y + Graph.heightOf(key) >= y0
			if touches and not already[key] then
				keys[#keys + 1] = key
				already[key] = true
			end
		end
		Graph.setSelection(keys)
		-- Light them AS the band reaches them (PtaQ, 2026-09-27), so the drag shows what the
		-- release will select. Classes only: the canvas is not rebuilt under a live gesture.
		for key in pairs(S.layout or {}) do
			local element = el(Graph.nodeElementId(key))
			if element then
				element:SetClass("ng-node-selected", already[key] == true)
			end
		end
	end

	--- Let go. The band goes away and the selection it left stands.
	function Graph.endMarquee()
		local band = S.graphMarquee
		if not band then
			return false
		end
		S.graphMarquee = nil
		local element = el("ng-graph-marquee")
		if element then
			element:SetClass("hidden", true)
		end
		if not band.grew then
			-- It never became a band. Put back what was selected before it started, and let the
			-- ordinary click logic decide what the press actually meant.
			S.graphSel = band.wasSel or {}
			S.graphSelEdge = band.wasEdge
			Graph.clickCanvasAt(Graph.pointerScreen())
			return true
		end
		-- A render, because the nodes have to be redrawn with their new selection classes and
		-- the connectors touching them picked out. Only on the drop: the drag itself has written
		-- styles and touched no markup.
		render()
		return true
	end

	--- What the status line says about the selection, or nothing when there is none.
	---
	--- A multi-selection is otherwise only visible as a border colour on a few boxes, which on a
	--- graph that does not fit the window is no answer to "how many did I just catch".
	function Graph.selectionNote()
		if S.graphSelComment then
			local frame = Graph.commentById(S.graphSelComment)
			return "  |  block '" .. tostring(frame and frame.title or S.graphSelComment) .. "' selected"
		end
		if S.graphSelEdge then
			return "  |  " .. Graph.describeEdge(S.graphSelEdge) .. " selected"
		end
		if #S.graphSel == 1 then
			local _, id = Graph.splitKey(S.graphSel[1])
			return "  |  " .. tostring(id) .. " selected"
		end
		if #S.graphSel > 1 then
			return string.format("  |  %d selected", #S.graphSel)
		end
		return ""
	end

	--- Every node whose id or type contains the search text, in draw order.
	--- Is FIND doing anything: text typed, or a kind chip on?
	function Graph.findActive()
		if (S.graphFind or "") ~= "" then
			return true
		end
		for _, on in pairs(S.findKinds) do
			if on then
				return true
			end
		end
		return false
	end

	--- Does this node match FIND? nil when FIND is idle (nothing is dimmed then).
	---
	--- The ONE rule, used by the canvas's dimming and by Enter's walk, so the two cannot
	--- disagree about what was found. Kind chips and text narrow together: with TRG on and
	--- "gate" typed, only triggers mentioning a gate match.
	---@return boolean|nil
	function Graph.findMatch(kind, record)
		if not Graph.findActive() then
			return nil
		end
		local anyKind = false
		for _, on in pairs(S.findKinds) do
			anyKind = anyKind or on
		end
		if anyKind and not S.findKinds[kind] then
			return false
		end
		local needle = (S.graphFind or ""):lower()
		return needle == "" or Graph.adapter.haystack(kind, record):find(needle, 1, true) ~= nil
	end

	function Graph.searchMatches()
		if not Graph.findActive() then
			return {}
		end
		local hits = {}
		for _, section in ipairs(Graph.adapter.kinds) do
			for _, record in ipairs(Graph.adapter.records(section.kind)) do
				if Graph.findMatch(section.kind, record) then
					hits[#hits + 1] = nodeKey(section.kind, record.id)
				end
			end
		end
		return hits
	end

	--- A kind chip pressed: pick out (or stop picking out) every node of that kind. Bound.
	function Graph.bound.graphFindKind(_, kind)
		if not Graph.isNodeKind(kind) then
			return
		end
		S.findKinds[kind] = not S.findKinds[kind]
		S.searchAt = 0
		Graph.syncFlags()
		S.elementCache = {}
		render()
	end

	--- The x: clear the text and every kind chip. Bound; Escape in the box does the same.
	function Graph.bound.graphFindClear()
		S.graphFind = ""
		for kind in pairs(S.findKinds) do
			S.findKinds[kind] = false
		end
		S.searchAt = 0
		-- The one imperative write left in FIND: an input's typed value. Binding it with
		-- `data-value` is the pattern RmlUi-practices.md warns about (the value lands a frame
		-- late and raises a change that reads as typing), so the clear sets it directly.
		local input = el("ng-graph-search")
		if input then
			pcall(function()
				input:SetAttribute("value", "")
			end)
		end
		Graph.syncFlags()
		render()
	end

	--- Frame the next node the search matched, and select it. Enter in the search box.
	---
	--- Cycles, so holding Enter walks the matches. The dimming stays as it is: a node that
	--- vanished would take its connectors' meaning with it, and the point of searching is to find
	--- something in the shape you already have.
	---@return boolean consumed
	function Graph.findNext()
		local hits = Graph.searchMatches()
		if #hits == 0 then
			echo((S.graphFind or "") == "" and "type something to find" or "nothing matches")
			return true
		end
		S.searchAt = ((S.searchAt or 0) % #hits) + 1
		local key = hits[S.searchAt]
		Graph.setSelection(key)
		Graph.frameKeys({ key })
		local _, id = Graph.splitKey(key)
		echo(string.format("%s  (%d of %d)", tostring(id), S.searchAt, #hits))
		return true
	end

	function Graph.boundsOf(keys)
		return Graph.lib.BoundsOf(S.layout, S.nodeH, keys)
	end

	--- Every node key in the document, for framing the lot.
	function Graph.allKeys()
		local keys = {}
		for _, section in ipairs(Graph.adapter.kinds) do
			for _, record in ipairs(Graph.adapter.records(section.kind)) do
				keys[#keys + 1] = nodeKey(section.kind, record.id)
			end
		end
		return keys
	end

	--- Move the VIEW so these nodes fill the viewport. Nothing in the layout changes.
	---
	--- Distinct from FIT, which re-lays the nodes out to make them fit and throws away the
	--- arrangement somebody dragged into place. Framing is the non-destructive one, and it is
	--- what `F` and `Home` should do: a designer pressing a key to look at something does not
	--- expect their graph to be rearranged.
	---@return boolean framed
	function Graph.frameKeys(keys)
		local viewport = el("ng-graph-viewport")
		if not viewport or viewport.offset_height == 0 then
			return false
		end
		local minX, minY, maxX, maxY = Graph.boundsOf(keys)
		if not minX then
			return false
		end
		local margin = GRAPH.frameMargin
		local availableW = viewport.offset_width * (1 - margin)
		local availableH = viewport.offset_height * (1 - margin)
		local zoom = math.min(availableW / math.max(1, maxX - minX), availableH / math.max(1, maxY - minY))
		zoom = math.max(GRAPH.minZoom, math.min(GRAPH.maxZoom, zoom))

		local view = S.graphView
		local z0, x0, y0 = Graph.visualView()
		view.zoom = zoom
		-- Centre the box: the canvas offset that puts the box's middle at the viewport's middle.
		view.panX = viewport.offset_width / 2 - ((minX + maxX) / 2) * zoom
		view.panY = viewport.offset_height / 2 - ((minY + maxY) / 2) * zoom
		Graph.sizeCanvas()
		Graph.clampPan()
		-- Glides there; the rebuild at the new zoom is on the last frame.
		Graph.animateView(z0, x0, y0)
		return true
	end

	--- Move the selected nodes by a whole number of pixels. Arrow keys.
	---@return boolean moved
	function Graph.nudgeSelection(dx, dy)
		if #S.graphSel == 0 then
			return false
		end
		local moved = false
		for _, key in ipairs(S.graphSel) do
			local position = S.layout and S.layout[key]
			if position and Graph.moveNode(key, position.x + dx, position.y + dy) then
				moved = true
			end
		end
		if not moved then
			return false
		end
		-- One undo step per key press, which is what a designer means by "undo that nudge".
		Graph.host.edited()
		Graph.normaliseLayout()
		Graph.sizeCanvas()
		render()
		return true
	end

	--- Put the selected nodes in a line. `edge` is "left", "right", "top" or "bottom".
	---
	--- Aligned on the EDGE named, not on centres, because a row of nodes of different heights
	--- reads as a row when their tops line up and as a mess when their middles do.
	---@return boolean consumed
	function Graph.alignSelection(edge)
		if #S.graphSel < 2 then
			echo("select two or more nodes to line them up")
			return true
		end
		local minX, minY, maxX, maxY = Graph.boundsOf(S.graphSel)
		if not minX then
			return true
		end

		local moved = false
		for _, key in ipairs(S.graphSel) do
			local position = S.layout and S.layout[key]
			if position then
				local x, y = position.x, position.y
				if edge == "left" then
					x = minX
				elseif edge == "right" then
					x = maxX - GRAPH.nodeWidth
				elseif edge == "top" then
					y = minY
				elseif edge == "bottom" then
					y = maxY - Graph.heightOf(key)
				end
				if Graph.moveNode(key, x, y) then
					moved = true
				end
			end
		end
		if not moved then
			echo("already lined up")
			return true
		end
		Graph.host.edited()
		Graph.normaliseLayout()
		Graph.sizeCanvas()
		render()
		echo(string.format("aligned %d nodes to the %s", #S.graphSel, edge))
		return true
	end

	--- Spread the selected nodes evenly between the two furthest apart.
	---
	--- The outermost two stay where they are and everything between them is respaced, which is
	--- what "distribute" means everywhere else and what makes it safe to press twice.
	---@param horizontal boolean
	---@return boolean consumed
	function Graph.distributeSelection(horizontal)
		if #S.graphSel < 3 then
			echo("select three or more nodes to spread them out")
			return true
		end

		-- Sorted along the axis, so the gaps are handed out in the order they appear rather than
		-- in the order they were clicked.
		local sorted = {}
		for _, key in ipairs(S.graphSel) do
			if S.layout and S.layout[key] then
				sorted[#sorted + 1] = key
			end
		end
		if #sorted < 3 then
			return true
		end
		table.sort(sorted, function(a, b)
			if horizontal then
				return S.layout[a].x < S.layout[b].x
			end
			return S.layout[a].y < S.layout[b].y
		end)

		local first, last = S.layout[sorted[1]], S.layout[sorted[#sorted]]
		local from = horizontal and first.x or first.y
		local to = horizontal and last.x or last.y
		local step = (to - from) / (#sorted - 1)

		local moved = false
		for index = 2, #sorted - 1 do
			local key = sorted[index]
			local position = S.layout[key]
			local at = from + step * (index - 1)
			local ok
			if horizontal then
				ok = Graph.moveNode(key, at, position.y)
			else
				ok = Graph.moveNode(key, position.x, at)
			end
			moved = moved or ok
		end
		if not moved then
			echo("already evenly spaced")
			return true
		end
		Graph.host.edited()
		Graph.normaliseLayout()
		Graph.sizeCanvas()
		render()
		echo(string.format("spread %d nodes %s", #sorted, horizontal and "across" or "down"))
		return true
	end

	--- What a click on a node means, given the modifiers held at the time.
	---
	--- Taken from Spring rather than from the RmlUi event: the event's modifier fields are not
	--- carried through the SolLua binding in a shape that can be relied on, and `GetModKeyState`
	--- is the same source every other gesture in the suite reads.
	---@return boolean changedMode whether the caller should follow the panel to this record
	function Graph.clickNode(key)
		local _, ctrl, _, shift = Spring.GetModKeyState()
		if ctrl then
			Graph.toggleSelected(key)
			return false
		end
		if shift then
			Graph.addSelected(key)
			return false
		end
		Graph.setSelection(key)
		return true
	end

	--- Grow the selection along the wires, one hop at a time until nothing new is reached.
	---
	--- `]` follows them forwards and `[` backwards, which is how a designer asks "what does this
	--- set off" and "what has to happen before this". Transitive rather than one hop: a questline
	--- branch is the thing being asked about, not the next node along.
	---
	--- It walks `S.graphEdgeList`, which is what the CANVAS drew, so it follows all three edge
	--- kinds and never claims a link that is not on screen.
	---@param forwards boolean
	---@return boolean consumed
	function Graph.growSelection(forwards)
		if #S.graphSel == 0 then
			echo("select a node first, then [ or ] to follow its connectors")
			return true
		end
		local reached = Graph.selectionSet()
		local order = {}
		for _, key in ipairs(S.graphSel) do
			order[#order + 1] = key
		end

		local added = true
		while added do
			added = false
			for _, edge in ipairs(S.graphEdgeList or {}) do
				local from, to = edge.from, edge.to
				if not forwards then
					from, to = to, from
				end
				if reached[from] and not reached[to] then
					reached[to] = true
					order[#order + 1] = to
					added = true
				end
			end
		end

		local before = #S.graphSel
		Graph.setSelection(order)
		local grew = #S.graphSel - before
		if grew == 0 then
			echo(forwards and "nothing further downstream" or "nothing further upstream")
		else
			echo(
				string.format("%s %d more (%d selected)", forwards and "downstream:" or "upstream:", grew, #S.graphSel)
			)
		end
		render()
		return true
	end

	--- Connect everything selected, in one press (C). The adapter decides WHICH pairs the
	--- selection means (a mission: triggers fire the selected actions, or chain as prerequisites
	--- in pick order); this makes them, as one undo step with one message at the end.
	---@return boolean consumed
	function Graph.quickConnect()
		local wanted, why = Graph.adapter.connect(S.graphSel)
		if not wanted then
			echo(why)
			return true
		end
		local made, refused, firstRefusal = 0, 0, nil
		for _, pair in ipairs(wanted) do
			local ok, message = Graph.linkNodes(pair.from, pair.to)
			if ok then
				made = made + 1
			else
				refused = refused + 1
				firstRefusal = firstRefusal or message
			end
		end
		if made == 0 then
			echo(firstRefusal or "nothing to connect")
			return true
		end
		Graph.host.edited()
		Graph.host.analyse()
		render()
		if refused > 0 then
			echo(string.format("connected %d, skipped %d (%s)", made, refused, tostring(firstRefusal)))
		else
			echo(string.format("connected %d", made))
		end
		return true
	end

	--- Duplicate the selected nodes, carrying the wires that run BETWEEN them.
	---
	--- A wire arriving from outside the selection is dropped, which is PtaQ's call and the one
	--- every node editor makes: carrying it would mean writing to a record nobody selected, and a
	--- prerequisite is stored on the far end, so that write would be invisible from here.
	---@return boolean consumed
	function Graph.duplicateSelection()
		if #S.graphSel == 0 then
			echo("select something to duplicate")
			return true
		end

		-- The adapter copies the records and the wires between them; this places the copies,
		-- offset so they are visibly a second set rather than landing on the originals.
		local copies = Graph.adapter.duplicate(S.graphSel)
		if #copies == 0 then
			echo("nothing in the selection can be duplicated")
			return true
		end
		local selection = {}
		for _, entry in ipairs(copies) do
			local from = S.layout and S.layout[entry.fromKey]
			if from then
				S.layout[entry.key] = {
					x = from.x + GRAPH.duplicateOffset,
					y = from.y + GRAPH.duplicateOffset,
				}
			end
			selection[#selection + 1] = entry.key
		end
		-- The COPIES are what is selected afterwards, so the next gesture acts on them. Dragging
		-- them off the originals is almost always the next thing that happens.
		Graph.setSelection(selection)

		Graph.host.edited()
		Graph.host.analyse()
		render()
		echo(string.format("duplicated %d node(s)", #copies))
		return true
	end

	--- Ctrl+C: the selected nodes, as plain data (the adapter's copy), with where each one sat.
	--- The clipboard is the editor's, not the document's, so it survives an OPEN: a set of
	--- triggers copied out of one mission pastes into the next.
	---@return boolean consumed
	function Graph.copySelection()
		if not Graph.adapter.copy then
			echo("this graph cannot copy")
			return true
		end
		if #S.graphSel == 0 then
			echo("select something to copy")
			return true
		end
		local payload = Graph.adapter.copy(S.graphSel)
		if #payload.entries == 0 then
			echo("nothing in the selection can be copied")
			return true
		end
		local positions = {}
		for _, entry in ipairs(payload.entries) do
			local at = S.layout and S.layout[entry.fromKey]
			if at then
				positions[entry.fromKey] = { x = at.x, y = at.y }
			end
		end
		S.graphClipboard = { payload = payload, positions = positions, pastes = 0 }
		echo(string.format("copied %d node(s)", #payload.entries))
		return true
	end

	--- Ctrl+X: copy, then delete (one undo step, the delete's).
	---@return boolean consumed
	function Graph.cutSelection()
		Graph.copySelection()
		if S.graphClipboard and #S.graphSel > 0 then
			Graph.deleteSelection()
		end
		return true
	end

	--- Ctrl+V: the clipboard into the document under fresh names, laid out as it was copied,
	--- its top-left corner at the pointer (or, with the pointer off the canvas, a step down and
	--- right of where it was, further each paste). The copies become the selection. One undo step.
	---@return boolean consumed
	function Graph.pasteClipboard()
		local clip = S.graphClipboard
		if not (clip and Graph.adapter.paste) then
			echo("nothing copied")
			return true
		end
		if not Graph.host.hasDocument() then
			return true
		end
		local copies = Graph.adapter.paste(clip.payload)
		if #copies == 0 then
			echo("nothing to paste")
			return true
		end
		clip.pastes = clip.pastes + 1
		local minX, minY
		for _, at in pairs(clip.positions) do
			minX = math.min(minX or at.x, at.x)
			minY = math.min(minY or at.y, at.y)
		end
		local anchorX, anchorY
		local pointerX, pointerY = Graph.pointerScreen()
		if minX and Graph.inGraphViewport(pointerX, pointerY) then
			anchorX, anchorY = Graph.canvasPoint(pointerX, pointerY)
		elseif minX then
			anchorX = minX + GRAPH.duplicateOffset * clip.pastes
			anchorY = minY + GRAPH.duplicateOffset * clip.pastes
		end
		S.layout = S.layout or {}
		local selection = {}
		for index, entry in ipairs(copies) do
			local at = clip.positions[entry.fromKey]
			if at and anchorX then
				S.layout[entry.key] = { x = math.floor(anchorX + at.x - minX), y = math.floor(anchorY + at.y - minY) }
			end
			selection[index] = entry.key
		end
		Graph.setSelection(selection)
		Graph.host.edited()
		Graph.host.analyse()
		S.elementCache = {}
		render()
		echo(string.format("pasted %d node(s)", #copies))
		return true
	end

	--- Delete what is selected on the canvas: a wire if one is picked, the nodes otherwise.
	---
	--- ONE undo step for the whole lot. `Graph.host.edited()` is the undo hook, so it is called once
	--- after the batch rather than once per record; calling it inside the loop would make undoing
	--- a six-node delete take six presses, which is not what anybody means by "undo that".
	---@return boolean deleted
	function Graph.deleteSelection()
		if S.graphSelComment then
			return Graph.deleteComment(S.graphSelComment)
		end
		if S.graphSelEdge then
			return Graph.severEdge(S.graphSelEdge)
		end
		if #S.graphSel == 0 then
			return false
		end

		local names, details = {}, {}
		-- Copied, because removeRecord prunes `S.selected` and the loop must not walk a list
		-- anything else is editing underneath it.
		local doomed = {}
		for _, key in ipairs(S.graphSel) do
			doomed[#doomed + 1] = key
		end
		for _, key in ipairs(doomed) do
			local kind, id = Graph.splitKey(key)
			if kind then
				local removed, detail = Graph.adapter.remove(kind, id)
				if removed then
					names[#names + 1] = id
					if detail then
						details[#details + 1] = detail
					end
				end
			end
		end
		if #names == 0 then
			return false
		end

		Graph.clearSelection()
		Graph.host.edited()
		Graph.host.analyse()
		render()
		for _, detail in ipairs(details) do
			echo(detail)
		end
		if #names == 1 then
			echo(string.format("deleted '%s'", names[1]))
		else
			echo(string.format("deleted %d nodes: %s", #names, table.concat(names, ", ")))
		end
		return true
	end

	--- The graph's own keys, dispatched from `widget:KeyPress`.
	---
	--- Claimed only while the pointer is inside the viewport, which is checked by the caller.
	--- Returns true when the key was ours, and the caller passes that straight back to the
	--- engine: anything not listed here goes to the game untouched.
	---@return boolean consumed
	function Graph.handleAction(name, ctrl, shift, alt)
		-- An overlay that is open but does NOT have the caret. `widget:KeyPress` only gets here
		-- when no text field is focused, so this is never the case where somebody is typing into
		-- one: it is the case where one was left open and the designer has moved on.
		--
		-- Escape shuts it. Anything else shuts it and then means what it always means. The
		-- alternative, swallowing every key while one is open, made the whole canvas unresponsive
		-- for the rest of the session the first time one was left behind.
		if S.palette or S.commentEdit or S.nodeRename then
			Graph.closePalette()
			Graph.closeCommentEdit()
			Graph.closeNodeRename()
			if name == "escape" then
				return true
			end
		end

		if name == "g" and ctrl then
			return Graph.addComment()
		end

		if name == "escape" then
			if S.portDrag then
				-- Abandon a connector in flight without editing anything.
				Graph.markLegalTargets(false)
				S.portDrag = nil
				Graph.hideLiveEdge()
				render()
				return true
			end
			if S.graphMarquee then
				S.graphMarquee = nil
				local band = el("ng-graph-marquee")
				if band then
					band:SetClass("hidden", true)
				end
				render()
				return true
			end
			-- All three, or a frame left selected would still be what Delete acted on.
			if #S.graphSel > 0 or S.graphSelEdge or S.graphSelComment then
				Graph.clearSelection()
				render()
				return true
			end
			return false
		end

		if name == "del" or name == "backspace" then
			return Graph.deleteSelection()
		end

		if name == "rightBracket" then
			return Graph.growSelection(true)
		end

		if name == "leftBracket" then
			return Graph.growSelection(false)
		end

		if name == "c" and not ctrl then
			return Graph.quickConnect()
		end

		if name == "d" and ctrl then
			return Graph.duplicateSelection()
		end

		-- Undo and redo, the editor's own history (every edit on the canvas is one step). Only
		-- here, with the pointer over the canvas: the terraform brush owns Ctrl+Z on the map.
		if name == "z" and ctrl then
			if shift then
				return Graph.host.redo()
			end
			return Graph.host.undo()
		end
		if name == "y" and ctrl then
			return Graph.host.redo()
		end

		-- The clipboard. Before the plain `v` below, which spreads the selection.
		if name == "c" and ctrl then
			return Graph.copySelection()
		end
		if name == "x" and ctrl then
			return Graph.cutSelection()
		end
		if name == "v" and ctrl then
			return Graph.pasteClipboard()
		end

		if name == "a" and ctrl then
			Graph.setSelection(Graph.allKeys())
			echo(string.format("selected %d nodes", #S.graphSel))
			render()
			return true
		end

		if name == "f" then
			-- The selection if there is one, the whole graph if there is not, which is what
			-- pressing it twice in a row is for.
			local keys = #S.graphSel > 0 and S.graphSel or Graph.allKeys()
			return Graph.frameKeys(keys)
		end

		if name == "home" then
			return Graph.frameKeys(Graph.allKeys())
		end

		if name == "m" then
			Graph.setMinimap(not S.graph.minimap)
			return true
		end

		if name == "h" then
			return Graph.distributeSelection(true)
		end

		if name == "v" then
			return Graph.distributeSelection(false)
		end

		-- Ctrl turns a nudge into an align, in the direction the arrow already points.
		local step = shift and 1 or GRAPH.nudgePx
		if name == "left" then
			return ctrl and Graph.alignSelection("left") or Graph.nudgeSelection(-step, 0)
		elseif name == "right" then
			return ctrl and Graph.alignSelection("right") or Graph.nudgeSelection(step, 0)
		elseif name == "up" then
			return ctrl and Graph.alignSelection("top") or Graph.nudgeSelection(0, -step)
		elseif name == "down" then
			return ctrl and Graph.alignSelection("bottom") or Graph.nudgeSelection(0, step)
		end

		return false
	end
end
