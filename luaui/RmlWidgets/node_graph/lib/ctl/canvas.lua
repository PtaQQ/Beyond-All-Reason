-- The GRAPH window's canvas controller: what a node shows (its rows and summary), where its
-- ports and connectors go and how they are styled, the canvas's keys and help overlay, the
-- live connector, the pointer and node hit test, and `Graph.render`, which draws the whole
-- canvas (refactor plan, Phase 3.3, GRAPH slice 4). The canvas stays IMPERATIVE on purpose:
-- nodes are placed in raw pixels, the agreed canvas exception to the data binding.
--
-- Same shape as ctl/edit.lua: a constructor handed exactly what it uses, which
-- FILLS the `Graph` table it is given, because `Graph` is the namespace the timeline and the
-- rest of the widget read too.
--
--     VFS.Include(".../ctl/canvas.lua")(deps)

---@param deps table
return function(deps)
	local Graph = deps.Graph
	local Bind = deps.Bind
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
		"Bind",
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
		assert(deps[name] ~= nil, "ctl/canvas: missing dependency " .. name)
	end

	Graph.EDGE = Graph.lib.EDGE

	--- The path a connector takes between two nodes, as points along a cubic bezier.
	---
	--- The curve leaves the source horizontally and arrives at the target horizontally, which is
	--- what makes a node graph readable: the direction lives in the shape, so a node dragged
	--- above or below the one it feeds still reads as feeding it. A straight bar between two
	--- centres said nothing about direction and swung about like a compass needle when either
	--- end moved.
	---
	--- The control offset grows with the horizontal gap and never shrinks past a minimum. A
	--- target parked to the LEFT of its source gets a bigger one still, so the connector bows
	--- out and comes back instead of doubling straight back through both nodes.
	---
	--- `segments` pins the tessellation. A drag passes the count the edge was built with, so the
	--- bars it is restyling are the bars that exist -- recomputing it mid-drag would leave a
	--- stale tail behind whenever the count fell.
	---@return table|nil points `points[i]` is `{x, y}`; `points.n` is the number of bars
	--- What a node SAYS is the adapter's (stage G1): its rows, its shut summary, its subtitle
	--- and its badge (`Graph.adapter.rows/summary/subtitle/badge`). This is the canvas's handle
	--- on the rows, which the layout, the heights and the harness all ask for.
	function Graph.rowsFor(kind, entry)
		return Graph.adapter.rows(kind, entry)
	end

	--- The one line a collapsed node shows: the first few parameters, and how many were left.
	function Graph.summaryLine(rows)
		if #rows == 0 then
			return ""
		end
		local parts = {}
		for index = 1, math.min(#rows, GRAPH.summaryFields) do
			parts[#parts + 1] = rows[index].label .. " " .. rows[index].value
		end
		local line = table.concat(parts, "  ")
		if #rows > GRAPH.summaryFields then
			line = line .. "  +" .. (#rows - GRAPH.summaryFields)
		end
		return line
	end

	--- Every row as one run of text, for a shut node with room to wrap it.
	function Graph.summaryText(rows)
		local parts = {}
		for _, row in ipairs(rows) do
			parts[#parts + 1] = row.label ~= "" and (row.label .. " " .. row.value) or row.value
		end
		return table.concat(parts, "   ")
	end

	--- Geometry in core.lua (Graph.lib); this passes the widget's state in.
	function Graph.measureNode(key, rows)
		return Graph.lib.MeasureNode(#rows, #Graph.outPortsOf(key), S.expanded[key] == true)
	end

	function Graph.heightOf(key)
		return Graph.lib.HeightOf(S.nodeH, key)
	end

	--- A node's output ports, from the adapter.
	function Graph.outPorts(kind, entry)
		return Graph.adapter.outPorts(kind, entry)
	end

	--- The output ports of the node this key names, looked up for callers that have only a key.
	function Graph.outPortsOf(key)
		local kind, id = Graph.splitKey(key or "")
		if not kind then
			return {}
		end
		return Graph.outPorts(kind, Graph.adapter.find(kind, id))
	end

	--- Does this node fire, activate or point at anything, and so get an output port at all?
	function Graph.hasOutPort(kind, entry)
		return #Graph.outPorts(kind, entry) > 0
	end

	Graph.portMetrics = Graph.lib.PortMetrics

	Graph.portOffset = Graph.lib.PortOffset

	function Graph.portY(key, side, name)
		return Graph.lib.PortY(Graph.heightOf(key), Graph.outPortsOf(key), side, name)
	end

	--- How far past the node's edge a wire off this port starts: the end of its label.
	function Graph.portX(key, name)
		return Graph.lib.PortLabelEnd(Graph.outPortsOf(key), name)
	end

	--- Can this port hold more than one wire?
	---
	--- A port that writes a FIELD holds one, so a second drop replaces the first; a port that
	--- appends to a LIST holds as many as the author wants. That difference is what the square
	--- port dot says, and it is also what decides whether a press on a port picks the wire up
	--- instead of starting a new one.
	function Graph.portIsSingle(key, name)
		for _, port in ipairs(Graph.outPortsOf(key)) do
			if port.name == name then
				return port.single == true
			end
		end
		return false
	end

	Graph.outAnchor = Graph.lib.OutAnchor

	Graph.inAnchor = Graph.lib.InAnchor

	Graph.curveBetween = Graph.lib.CurveBetween

	---@param segments number|nil pins the tessellation; see Graph.curveBetween
	---@param heightA number|nil how tall the node it leaves is drawn
	---@param heightB number|nil how tall the node it arrives at is drawn
	---@param outY number|nil where on the source's edge the wire leaves, for a named port
	---@param outX number|nil how far past the edge it leaves (the end of a named port's label)
	function Graph.edgeCurve(a, b, segments, heightA, heightB, outY, outX)
		if not (a and b) then
			return nil
		end
		local x0, y0 = Graph.outAnchor(a, heightA, outY, outX)
		local x3, y3 = Graph.inAnchor(b, heightB)
		return Graph.curveBetween(x0, y0, x3, y3, segments)
	end

	--- A connector is tinted from the colour of the node it leaves to the colour of the node it
	--- arrives at, one step per bar. It is the cheapest way to say which way a link runs -- the
	--- shape says it too, but colour says it at a glance and across a crowded canvas.
	---
	--- EVERY connector is graded this way (PtaQ, 2026-09-26): the two colours ARE the kind of
	--- link, so a stage-to-objective wire reads violet into amber and nothing needs a colour of
	--- its own. These are the node border colours from the stylesheet, except the objective's:
	--- a DARKER gold, because the bright one is the picked-wire highlight and an objective's
	--- wires read as selected in it. Two copies of a colour drift, so if those change these
	--- follow.
	--- The tints themselves are the adapter's (`Graph.adapter.kinds[i].tint`).
	Graph.TINT_FALLBACK = { 0x8a, 0x8f, 0x9a }

	--- What the canvas is, so a wire can be blended onto it and drawn OPAQUE.
	---
	--- A connector is a run of forty-odd straight bars with round caps, and consecutive caps
	--- overlap by half a thickness -- which is exactly what makes the joints smooth. Drawn at
	--- less than full alpha, every one of those overlaps paints twice, and the wire reads as a
	--- string of beads with a visible seam at each one. Blending the tint onto the background
	--- here and emitting an opaque colour gives the same colour on the canvas with nothing left
	--- to double up.
	---
	--- It has to match `.ng-graph-viewport`'s `background-color`. Nothing can ask RmlUi for that,
	--- so if the canvas ever changes colour this changes with it.
	Graph.CANVAS_BG = { 0x0e, 0x0e, 0x14 }

	function Graph.tintOf(key)
		local kind = key:match("^(%a+):")
		for _, entry in ipairs(Graph.adapter.kinds) do
			if entry.kind == kind then
				return entry.tint or Graph.TINT_FALLBACK
			end
		end
		return Graph.TINT_FALLBACK
	end

	--- The tint a wire carries at `t` along its length, already flattened onto the canvas.
	---
	--- `alpha` still means how STRONG the tint is, 0 to 255, but it is applied here rather than
	--- handed to the renderer: what comes back is opaque. See `Graph.CANVAS_BG`.
	function Graph.mixTint(from, to, t, alpha)
		local strength = (alpha or 255) / 255
		local bg = Graph.CANVAS_BG
		local out = {}
		for channel = 1, 3 do
			local tint = from[channel] + (to[channel] - from[channel]) * t
			out[channel] = math.floor(bg[channel] + (tint - bg[channel]) * strength + 0.5)
		end
		return string.format("#%02x%02x%02x", out[1], out[2], out[3])
	end

	--- Canvas units to rendered pixels. One place, so nothing drifts half a pixel from
	--- everything else.
	function Graph.px(value)
		return math.floor(value * S.graphView.zoom + 0.5)
	end

	--- Is the canvas zoomed out far enough that shut nodes show only their names?
	function Graph.isOverview()
		return S.graphView.zoom < GRAPH.overviewZoom
	end

	--- How wide `text` is at a font size of 1, in the bold face, near enough to size by: a
	--- per-glyph guess (narrow i/l/t, wide m/w, capitals), plus a margin. A flat average
	--- clipped names heavy in capitals and wide letters.
	local GLYPH_EM = {
		i = 0.3,
		l = 0.3,
		j = 0.3,
		["."] = 0.3,
		["_"] = 0.55,
		f = 0.38,
		r = 0.4,
		t = 0.4,
		m = 0.9,
		w = 0.82,
		M = 0.92,
		W = 1.0,
	}
	function Graph.textEm(text)
		local em = 0
		for char in text:gmatch(".") do
			em = em + (GLYPH_EM[char] or (char:match("%u") and 0.7) or (char:match("%d") and 0.6) or 0.6)
		end
		return em * 1.06
	end

	--- The overview's name: ONE line, never wrapped (PtaQ, 2026-09-27), in the biggest font
	--- (screen px) at which the whole name fits `width` and `height`. A name too long even at
	--- the smallest size is cut and ends in "..".
	---@return number fontPx, string text
	function Graph.overviewFit(name, width, height)
		name = tostring(name)
		local em = Graph.textEm(name)
		local font = math.floor(math.min(GRAPH.overviewMaxPx, height / 1.15, width / math.max(em, 1)))
		if font >= GRAPH.overviewMinPx then
			return font, name
		end
		font = GRAPH.overviewMinPx
		local cut = #name
		while cut > 1 and Graph.textEm(name:sub(1, cut) .. "..") * font > width do
			cut = cut - 1
		end
		return font, name:sub(1, cut) .. ".."
	end

	--- The inline style for one bar of a connector, at the current zoom.
	---
	--- **The radius has to be written here, not in the stylesheet.** The thickness is written
	--- inline and scales with the zoom; a radius left in the RCSS does not, so at 2x the bars were
	--- eight pixels thick with two pixel corners and every joint showed as a step. Half the drawn
	--- thickness gives genuine semicircular caps, and the cap of the next bar fills the joint --
	--- which is how a polyline is drawn as a stroke, and what the overlap was always reaching for.
	---
	--- One function, because the settled connectors, the one being dragged and the hover overlay
	--- all have to agree about what a bar looks like or the differences show.
	---@param thickness number|nil drawn thickness in canvas units; `GRAPH.edgePx` if omitted
	function Graph.barStyle(left, top, width, angle, thickness)
		local drawn = math.max(1, Graph.px(thickness or GRAPH.edgePx))
		return string.format(
			"left: %dpx; top: %dpx; width: %dpx; height: %dpx; border-radius: %dpx; transform: rotate(%.2fdeg);",
			Graph.px(left),
			Graph.px(top),
			Graph.px(width),
			drawn,
			-- CEIL, and this is the difference between a smooth wire and a rippled one. A bar's
			-- cap has to be a true semicircle: consecutive bars meet at an angle and it is the cap
			-- that fills the wedge between them. Floored, an odd thickness produced a rounded
			-- RECTANGLE -- a 7px bar with a 3px radius -- and every joint left a notch, which read
			-- as the wire changing thickness along its length. RmlUi clamps the radius to half the
			-- side, so rounding up can never overshoot.
			math.max(1, math.ceil(drawn / 2)),
			angle
		)
	end

	--- left, top, width and angle for the bar that covers one step of the curve.
	function Graph.segmentStyle(from, to)
		local dx, dy = to.x - from.x, to.y - from.y
		local length = math.sqrt(dx * dx + dy * dy)
		-- At least the thickness, so the round cap of the next bar always reaches over the joint.
		-- A fixed overlap stopped being enough the moment the connectors got fatter.
		local overlap = math.max(Graph.EDGE.overlapPx, GRAPH.edgePx)
		return math.floor(from.x),
			math.floor(from.y),
			math.max(1, math.floor(length + overlap)),
			math.deg(math.atan2(dy, dx))
	end

	--- The id of one bar of a connector, and of a node's port dots.
	function Graph.segmentElementId(edgeIndex, segment)
		return "ng-edge-" .. edgeIndex .. "-" .. segment
	end

	--- `name` is the field a named port writes, and is left off a node's only port so that every
	--- id a single-port node has ever had is unchanged.
	function Graph.portElementId(key, side, name)
		local base = "ng-port-" .. side .. "-" .. (key:gsub(":", "-", 1))
		return name and (base .. "--" .. name) or base
	end

	--------------------------------------------------------------------------------
	-- Dragging a connector off a port
	--------------------------------------------------------------------------------

	--- The live connector is drawn with a fixed number of bars, because it is restyled on every
	--- drag event and a changing count would leave a tail behind.
	Graph.LIVE_SEGMENTS = 14

	--- How many bars the hover overlay has. The most any connector can be drawn with, so the
	--- highlight always covers the whole wire rather than stopping part way along a long bend.
	Graph.HOVER_SEGMENTS = Graph.EDGE.maxSegments

	--- The letters a named port's label is laid along the wire in flight with, one element
	--- each, built hidden with the canvas. The longest port label is shorter than this.
	Graph.LIVE_LABEL_CHARS = 16

	--- The sever button's diameter, in canvas units.
	Graph.SEVER_ICON_PX = 22

	function Graph.liveCharId(index)
		return "ng-live-char-" .. index
	end

	--- RmlUi's mouse button numbering, which is NOT SDL's.
	---
	--- RmlUi counts left, right, middle as 0, 1, 2; SDL counts left, middle, right as 1, 2, 3. The
	--- events this panel listens to carry RmlUi's, and `attachDraggable` in the shared helper is
	--- already written against them (`p.button ~= 0` to mean "not the left one").
	Graph.RMLUI_BUTTON = { left = 0, right = 1, middle = 2 }

	--- Every control the canvas has, in the order somebody would meet them.
	---
	--- Here rather than typed into the RML, so a shortcut added later is one line beside the code
	--- that added it. A control this table does not mention is a control nobody will find.
	Graph.HELP = {
		{ group = "Getting around" },
		{ "Wheel", "scroll up and down" },
		{ "Shift + wheel", "scroll sideways" },
		{ "Ctrl + wheel", "zoom, towards the pointer" },
		{ "Middle-drag", "pan" },
		{ "Space + drag", "pan" },
		{ "F", "frame the selection" },
		{ "Home", "frame the whole graph" },
		{ "Enter in Find", "frame the next match" },
		{ "Drag to the edge", "the canvas follows" },
		{ "M", "show or hide the minimap" },
		{ "Click the minimap", "jump there; drag to pan" },

		{ group = "Choosing things" },
		{ "Click", "select one node" },
		{ "Ctrl-click", "add or remove one" },
		{ "Shift-click", "add one" },
		{ "Drag empty space", "rubber band; Ctrl adds" },
		{ "Ctrl+A", "select everything" },
		{ "]", "grow downstream" },
		{ "[", "grow upstream" },
		{ "Escape", "clear, or cancel" },

		{ group = "Wiring" },
		{ "Drag a port", "new connector" },
		{ "Drag a wire's end", "re-point it" },
		{ "...drop on nothing", "cut it" },
		{ "Click a wire", "pick it" },
		{ "Click a wire's middle", "cut it (the x shows)" },
		{ "Alt-click a wire", "cut it" },
		{ "Alt-click a port", "cut everything on it" },
		{ "C", "connect the selection" },
		{ "Delete", "remove what is selected" },

		{ group = "Undo and the clipboard" },
		{ "Ctrl+Z", "undo the last change" },
		{ "Ctrl+Y / Ctrl+Shift+Z", "redo it" },
		{ "Ctrl+C", "copy the selected nodes" },
		{ "Ctrl+X", "cut them" },
		{ "Ctrl+V", "paste at the pointer, wires between them kept" },

		{ group = "Making things" },
		{ "Right-click", "add a node here" },
		{ "Drop a wire on empty", "add a node, wired up" },
		{ "Ctrl+D", "duplicate the selection, wires between them kept" },
		{ "Ctrl+G", "wrap selection in a grouping" },
		{ "Double-click its title", "rename a grouping in place" },

		{ group = "Editing a node" },
		{ "Double-click name", "rename it in place" },
		{ "Double-click its type", "change it, where the graph allows" },
		{ "Drag a port's name", "new connector, like its dot" },
		{ "Double-click a node", "open or shut it" },
		{ "Tab in a node field", "next field; Shift goes back" },
		{ "Chevron under a node", "edit its parameters" },

		{ group = "Tidying up" },
		{ "Arrows", "nudge; Shift is finer" },
		{ "Ctrl + arrows", "line them up that way" },
		{ "H", "spread evenly across" },
		{ "V", "spread evenly down" },
	}

	--- Which action an SDL keycode means, or nil.
	function Graph.actionForKey(key)
		for name in pairs(Graph.KEY) do
			if Graph.isKey(name, key) then
				return name
			end
		end
		return nil
	end

	--- The engine's key call-in, mapped onto an action. Kept because Escape still arrives this
	--- way, and because a build that stops letting RmlUi eat keys would go back to using it.
	function Graph.handleKey(key, ctrl, shift, alt)
		local name = Graph.actionForKey(key)
		if not name then
			return false
		end
		return Graph.handleAction(name, ctrl, shift, alt)
	end

	--- RmlUi's own key identifiers, mapped onto the same action names.
	---
	--- Resolved ONCE, on first use. `RmlUi.key_identifier` is a function that rebuilds its table
	--- on every access, so reading it per keystroke is both wasteful and, written without the
	--- parentheses, a throw that a pcall swallows into a nil that never matches anything.
	Graph.RML_ACTION = nil

	function Graph.resolveRmlKeys()
		if Graph.RML_ACTION ~= nil then
			return Graph.RML_ACTION
		end
		local ids
		local ok = pcall(function()
			ids = RmlUi.key_identifier()
		end)
		if not ok or type(ids) ~= "table" then
			pcall(function()
				ids = RmlUi.key_identifier
			end)
		end
		Graph.RML_ACTION = {}
		if type(ids) ~= "table" then
			-- Say so once rather than leaving the whole canvas keyboard quietly dead, which is
			-- precisely the failure this is fixing.
			echo("this RmlUi build exposes no key identifiers; the graph's shortcuts will not work")
			return Graph.RML_ACTION
		end

		-- RmlUi's names, which are its own enum and not SDL's. OEM_4 and OEM_6 are `[` and `]`.
		local named = {
			ESCAPE = "escape",
			DELETE = "del",
			BACK = "backspace",
			A = "a",
			C = "c",
			D = "d",
			F = "f",
			G = "g",
			H = "h",
			M = "m",
			V = "v",
			X = "x",
			Y = "y",
			Z = "z",
			HOME = "home",
			LEFT = "left",
			RIGHT = "right",
			UP = "up",
			DOWN = "down",
			OEM_4 = "leftBracket",
			OEM_6 = "rightBracket",
		}
		local found = 0
		for identifier, action in pairs(named) do
			local value = ids[identifier]
			if value ~= nil then
				Graph.RML_ACTION[value] = action
				found = found + 1
			end
		end
		if found == 0 then
			echo("this RmlUi build named none of the graph's keys; its shortcuts will not work")
		end
		return Graph.RML_ACTION
	end

	--- How many key events are logged before the log goes quiet. Unconditional, because a
	--- diagnostic behind a toggle nobody remembers to switch on produces an empty log, and an
	--- empty log reads exactly like a listener that never fired.
	Graph.KEY_LOG_BUDGET = 10

	--- A key from RmlUi. The path that actually carries Delete.
	function Graph.onRmlKey(event)
		local parameters = event and event.parameters
		if not parameters then
			return
		end
		-- A proxy, not a table: index it by name. `pairs` over it yields nothing at all.
		local identifier = parameters.key_identifier
		local action = Graph.resolveRmlKeys()[identifier]

		if Graph.KEY_LOG_BUDGET > 0 then
			Graph.KEY_LOG_BUDGET = Graph.KEY_LOG_BUDGET - 1
			echo(
				string.format(
					"graph key: rmlui id %s -> %s (field focused: %s, over canvas: %s)",
					tostring(identifier),
					tostring(action),
					tostring(Graph.host.typing()),
					tostring(Graph.inGraphViewport(Graph.pointerScreen()))
				)
			)
			if Graph.KEY_LOG_BUDGET == 0 then
				echo("graph key logging spent")
			end
		end

		if not action or Graph.host.typing() then
			return
		end
		if not Graph.host.showing() then
			return
		end
		if not Graph.inGraphViewport(Graph.pointerScreen()) then
			return
		end
		if Graph.keyAlreadyHandled(action) then
			return
		end

		local ctrl = parameters.ctrl_key
		local shift = parameters.shift_key
		local alt = parameters.alt_key
		local ok, err = pcall(
			Graph.handleAction,
			action,
			ctrl ~= nil and ctrl ~= 0 and ctrl ~= false,
			shift ~= nil and shift ~= 0 and shift ~= false,
			alt ~= nil and alt ~= 0 and alt ~= false
		)
		if not ok then
			echo("graph key handler error: " .. tostring(err))
		end
	end

	--- True when this action has already been dealt with on this frame.
	---
	--- Both doors can deliver the same press: RmlUi takes most keys, but Escape reaches
	--- `widget:KeyPress` as well, and a build that changed its mind about which it ate would
	--- deliver everything twice. Deleting a selection twice is not a thing that can be undone in
	--- one step, so this is not merely tidiness.
	function Graph.keyAlreadyHandled(action)
		if S.lastKeyAction == action and S.lastKeyTick == Graph.host.frame() then
			return true
		end
		S.lastKeyAction = action
		S.lastKeyTick = Graph.host.frame()
		return false
	end

	--- Show or hide the controls card.
	function Graph.setHelp(open)
		-- Built on the way in, whatever opened it: the edge tab opened an EMPTY card, because
		-- only the KEYS chip's handler used to build it.
		if open then
			Graph.renderHelp()
		end
		S.helpOpen = open and true or false
		Graph.syncFlags()
	end

	--- Build the card's contents. Once, on the first open: it never changes.
	function Graph.renderHelp()
		if S.helpBuilt then
			return
		end
		local body = el("ng-graph-help-body")
		if not body then
			return
		end
		local parts = {}
		for _, entry in ipairs(Graph.HELP) do
			if entry.group then
				parts[#parts + 1] = string.format('<div class="ng-help-group">%s</div>', escapeRml(entry.group))
			else
				parts[#parts + 1] = string.format(
					'<div class="ng-help-row"><div class="ng-help-key">%s</div><div class="ng-help-what">%s</div></div>',
					escapeRml(entry[1]),
					escapeRml(entry[2])
				)
			end
		end
		body.inner_rml = table.concat(parts)
		S.helpBuilt = true
	end

	--- The id of one bar of the hover overlay.
	function Graph.hoverSegmentId(index)
		return "ng-edge-hoverbar-" .. index
	end

	function Graph.liveSegmentId(index)
		return "ng-live-" .. index
	end

	function Graph.hideLiveEdge()
		for index = 1, Graph.LIVE_SEGMENTS do
			local element = el(Graph.liveSegmentId(index))
			if element then
				element:SetClass("hidden", true)
			end
		end
		Graph.layLiveLabel(nil, nil)
	end

	--- Lay a port's name ALONG the wire in flight, one letter per element, each turned to the
	--- curve under it (PtaQ, 2026-09-26): the names float beside the node only while it is
	--- hovered, so once a wire is pulled off a port this is what says which field it writes.
	---
	--- Centred on the curve's length and lifted off it by a little over the wire's thickness.
	--- The letter widths are an estimate (RmlUi cannot measure text from here), which is close
	--- enough for a label a handful of letters long. `points` nil hides every letter.
	---@param points table|nil the live curve, `{ n = bars, ... }` in canvas units
	---@param text string|nil
	function Graph.layLiveLabel(points, text)
		local count = 0
		if points and text and text ~= "" then
			-- Read left to right whichever way the wire was pulled.
			local path = {}
			for index = 1, points.n + 1 do
				path[index] = points[index]
			end
			if path[#path].x < path[1].x then
				local reversed = {}
				for index = #path, 1, -1 do
					reversed[#reversed + 1] = path[index]
				end
				path = reversed
			end
			local lengths, total = { 0 }, 0
			for index = 2, #path do
				local dx, dy = path[index].x - path[index - 1].x, path[index].y - path[index - 1].y
				total = total + math.sqrt(dx * dx + dy * dy)
				lengths[index] = total
			end
			local font = GRAPH.paramPx
			local advance = font * 0.6
			local letters = math.min(#text, Graph.LIVE_LABEL_CHARS)
			local start = total / 2 - letters * advance / 2
			local lift = GRAPH.edgePx / 2 + font * 0.75
			local segment = 2
			for index = 1, letters do
				local at = start + (index - 0.5) * advance
				local element = el(Graph.liveCharId(index))
				if element and at >= 0 and at <= total then
					while segment < #path and lengths[segment] < at do
						segment = segment + 1
					end
					local a, b = path[segment - 1], path[segment]
					local span = math.max(0.0001, lengths[segment] - lengths[segment - 1])
					local t = (at - lengths[segment - 1]) / span
					local dx, dy = b.x - a.x, b.y - a.y
					local length = math.max(0.0001, math.sqrt(dx * dx + dy * dy))
					-- Lifted along the normal that points UP the screen.
					local nx, ny = dy / length, -dx / length
					if ny > 0 then
						nx, ny = -nx, -ny
					end
					local x = a.x + dx * t + nx * lift
					local y = a.y + dy * t + ny * lift
					local box = font * 1.2
					element.inner_rml = escapeRml(text:sub(index, index))
					element.style.left = Graph.px(x - box / 2) .. "px"
					element.style.top = Graph.px(y - box / 2) .. "px"
					element.style.width = Graph.px(box) .. "px"
					element.style.height = Graph.px(box) .. "px"
					element.style["line-height"] = Graph.px(box) .. "px"
					element.style["font-size"] = Graph.px(font) .. "px"
					element.style.transform = string.format("rotate(%.2fdeg)", math.deg(math.atan2(dy, dx)))
					element:SetClass("hidden", false)
				elseif element then
					-- Off the end of a wire too short for the whole name.
					element:SetClass("hidden", true)
				end
			end
			count = letters
		end
		for index = count + 1, Graph.LIVE_LABEL_CHARS do
			local element = el(Graph.liveCharId(index))
			if element then
				element:SetClass("hidden", true)
			end
		end
	end

	--- Where the pointer is, in the space element boxes are measured in.
	---
	--- NOT the drag event's own `mouse_x`/`mouse_y`. Those come from RmlUi, and inside a canvas
	--- carrying a transform it is not clear which space they are in: the connector's free end
	--- came out to the LEFT of the cursor at every zoom but 1:1, and an unprojected pointer is
	--- exactly what that looks like. Spring's cursor position is unambiguous.
	---
	--- Spring's BUTTON state genuinely cannot be used during an RmlUi drag -- see Graph.beginNodeDrag
	--- for why -- but its position is fine, and it is the same position the element boxes are
	--- measured against once y is flipped.
	---
	--- Where the two spaces agree this changes nothing, which is what makes it safe to use for
	--- the node drag as well as the connector.
	function Graph.pointerScreen(fallbackX, fallbackY)
		local ok, mx, my = pcall(Spring.GetMouseState)
		if not ok or not mx then
			return fallbackX, fallbackY
		end
		-- Into RmlUi window space: the mouse is view-relative, and the view's x offset is
		-- non-zero in dual-screen mode, where the canvas usually sits on the free half.
		local _, vsy, viewPosX = Spring.GetViewGeometry()
		return mx + (viewPosX or 0), vsy - my
	end

	--- Geometry in core.lua (Graph.lib); this passes the widget's state in.
	---@param pad number|nil canvas pixels of tolerance, see Graph.lib.NodeAt
	function Graph.nodeAt(cx, cy, pad)
		return Graph.lib.NodeAt(S.layout, S.nodeH, cx, cy, pad)
	end

	Graph.splitKey = Graph.lib.SplitKey

	--- Did this event start inside an element of one of these classes, within its node?
	function Graph.eventFrom(event, classes)
		local target = event and event.target_element
		while target do
			for _, class in ipairs(classes) do
				if target:IsClassSet(class) then
					return true
				end
			end
			if target:IsClassSet("ng-node") then
				return false
			end
			target = target.parent_node
		end
		return false
	end

	--- Did this drag start in one of an open node's editor rows? A text field is its OWN drag
	--- source (that is how RmlUi selects text in it), and its drag events bubble up to the
	--- node: pressing into a field and dragging to select moved the node. So the node stands
	--- down, and the event is stopped so the canvas behind never starts a rubber band either.
	function Graph.dragFromField(event)
		if Graph.eventFrom(event, { "ng-node-edit" }) then
			if event.StopPropagation then
				event:StopPropagation()
			end
			return true
		end
		return false
	end

	--- Two clicks on one node within this many seconds open or shut it (PtaQ, 2026-09-26).
	Graph.DOUBLE_CLICK_S = 0.4

	--- Is this click the second of a double-click on the node? Timed here rather than RmlUi's
	--- `dblclick`, because the first click re-renders the canvas and the element the second
	--- one lands on is a new one. The title (double-click renames), the editor rows, the stub
	--- and the ports are left out: each has a click of its own.
	---@return boolean|string double true, "title" when both clicks were on the node's NAME
	function Graph.isDoubleClick(key, event)
		if
			Graph.eventFrom(event, { "ng-node-edit", "ng-node-expand", "ng-port", "ng-port-label", "ng-node-hoverpad" })
		then
			S.lastNodeClick = nil
			return false
		end
		-- WHERE on the node: the name renames, the type line (under it) changes the type.
		local onTitle = Graph.eventFrom(event, { "ng-node-title" }) and "title"
			or Graph.eventFrom(event, { "ng-node-sub" }) and "type"
			or false
		local now = Spring.GetTimer()
		local last = S.lastNodeClick
		if
			last
			and last.key == key
			and last.title == onTitle
			and Spring.DiffTimers(now, last.at) <= Graph.DOUBLE_CLICK_S
		then
			S.lastNodeClick = nil
			return onTitle or true
		end
		S.lastNodeClick = { key = key, at = now, title = onTitle }
		return false
	end

	--- Draw the graph. Nodes are real elements so they stay clickable and styleable; edges
	--- are thin divs rotated into place, which RmlUi supports because RCSS registers the
	--- `transform` property. No GL, no render target, no engine change.
	--- An open node's editor rows: one fixed-height row per parameter, a label and a live
	--- control. Generated markup (the canvas exception: raw pixels, zoom baked in), but every
	--- control calls the same bound `Bind.form*` callbacks as the panel's form, through the host
	--- `node:<key>` that the adapter's `form` registered. No listeners are attached here.
	function Graph.nodeEditorRows(rows)
		local parts = {}
		local h, font = Graph.px(GRAPH.editRowPx), Graph.px(GRAPH.editPx)
		local controlH = math.max(1, h - Graph.px(6))
		for _, row in ipairs(rows) do
			local host, index = escapeRml(row.host), row.index
			local call = function(name, extra)
				return string.format("%s('%s', %d%s)", name, host, index, extra or "")
			end
			local control
			if row.isText or row.control == "dropdown" then
				control = string.format(
					'<input type="text" class="ng-node-input" id="%s" value="%s" placeholder="unset" '
						.. 'style="height: %dpx; line-height: %dpx; font-size: %dpx;" data-event-focus="%s" data-event-blur="%s" data-event-keydown="%s" />',
					escapeRml(row.inputId),
					escapeRml(row.text),
					controlH,
					controlH - 2,
					font,
					call("formFocus"),
					call("formCommit"),
					call("formKey")
				)
			elseif row.control == "checkbox" then
				-- Sized inline at the zoom like everything else in the canvas: the panel's `dp` box
				-- stayed one size while the row shrank round it when zoomed out.
				local box = math.max(6, Graph.px(18))
				control = string.format(
					'<div class="ng-check-row" style="height: %dpx;" data-event-click="%s"><div class="ng-check%s" '
						.. 'style="width: %dpx; height: %dpx; border-width: %dpx; border-radius: %dpx;"></div></div>',
					controlH,
					call("formToggle"),
					row.checked and " checked" or "",
					box,
					box,
					math.max(1, Graph.px(2)),
					math.max(1, Graph.px(4))
				)
			elseif row.control == "select" then
				local options = {}
				for _, option in ipairs(row.options) do
					options[#options + 1] = string.format(
						'<option value="%s"%s>%s</option>',
						escapeRml(option.value),
						option.selected and ' selected="selected"' or "",
						escapeRml(option.label)
					)
				end
				-- RmlUi's own arrow is a child element with no inline style, so it cannot follow
				-- the zoom; it is hidden and this chevron, sized inline like everything else in
				-- the canvas, is laid over the select's right end instead.
				local chevron = math.max(4, Graph.px(9))
				control = string.format(
					'<div class="ng-node-selectwrap" style="height: %dpx;">'
						.. '<select class="ng-node-select" style="height: %dpx; line-height: %dpx; font-size: %dpx; '
						.. 'padding-right: %dpx;" data-event-change="%s">%s</select>'
						.. '<div class="ng-node-selectarrow" style="right: %dpx; top: %dpx; width: %dpx; height: %dpx; '
						.. 'border-right-width: %dpx; border-bottom-width: %dpx;"></div></div>',
					controlH,
					controlH,
					controlH - 2,
					font,
					chevron + Graph.px(14),
					call("formSelect"),
					table.concat(options),
					Graph.px(10),
					math.floor((controlH - chevron) / 2) - Graph.px(2),
					chevron,
					chevron,
					math.max(1, Graph.px(2)),
					math.max(1, Graph.px(2))
				)
			else
				-- Read-only: a picked area or point, an engine constant, a set, something opaque.
				-- The pipette where there is one; the panel for the rest.
				control = string.format(
					'<div class="ng-node-ro" style="font-size: %dpx;">%s</div>',
					font,
					escapeRml(row.text ~= "" and row.text or "-")
				)
				if row.canPick then
					control = control
						.. string.format('<div class="ng-node-pick" data-event-click="%s">PICK</div>', call("formPick"))
				end
				if row.isExtra then
					control = control
						.. string.format(
							'<div class="ng-node-pick" data-event-click="%s">REMOVE</div>',
							call("formRemove")
						)
				end
			end
			parts[#parts + 1] = string.format(
				'<div class="ng-node-edit%s" style="height: %dpx;">'
					.. '<div class="ng-node-elabel%s" style="font-size: %dpx;">%s</div>'
					.. '<div class="ng-node-econtrol">%s</div></div>',
				row.invalid and " ng-node-edit-invalid" or "",
				h,
				row.required and " ng-node-elabel-req" or "",
				font,
				escapeRml(row.name),
				control
			)
		end
		return table.concat(parts)
	end

	--- The expand bar pressed. Bound; stops the click so it does not also select the node.
	function Graph.bound.graphExpand(event, key)
		if event and event.StopPropagation then
			event:StopPropagation()
		end
		Graph.toggleExpanded(key)
	end

	function Graph.render()
		-- A field inside a node has the caret: rebuilding the canvas now would destroy it
		-- mid-word. The form view asks for a render when it lets go.
		local formFocus = Graph.host.formFocus()
		if formFocus and formFocus:find("^node:") then
			return
		end
		local canvas = el("ng-graph-canvas")
		if not canvas or not Graph.host.hasDocument() then
			return
		end

		if not S.layout or not next(S.layout) then
			S.layout = Graph.autoLayout()
		else
			Graph.placeNewNodes()
		end
		Graph.sizeCanvas()

		-- What the adapter marks: nodes on a cycle (only while CYCLES is on) and nodes carrying
		-- a dangling reference.
		local marks = Graph.adapter.marks()
		local inCycle = (S.graph.showCycles and Graph.adapter.markToggle) and marks.cycle or {}
		local parts = {}

		-- Comment frames FIRST, so everything else paints over them. Only the title bar takes a
		-- press (the body is `pointer-events: none` in the stylesheet), or a frame would swallow
		-- every click meant for the nodes standing inside it.
		for _, frame in ipairs(Graph.comments()) do
			local selected = S.graphSelComment == frame.id and " ng-comment-selected" or ""
			local tint = math.max(1, math.min(GRAPH.commentTints, tonumber(frame.tint) or 1))
			-- No rename button: a double-click on the title renames in place, like a node's name.
			parts[#parts + 1] = string.format(
				'<div class="ng-comment ng-comment-t%d%s" id="%s" style="left: %dpx; top: %dpx; '
					.. 'width: %dpx; height: %dpx;">'
					.. '<div class="ng-comment-head" id="ng-gcommenthead-%s" style="width: %dpx; height: %dpx;">'
					.. '<div class="ng-comment-title" id="ng-gcommenttitle-%s" style="font-size: %dpx; height: %dpx; line-height: %dpx; '
					.. 'margin-left: %dpx; max-width: %dpx;">%s</div></div>'
					.. '<div class="ng-comment-grip" id="ng-gcommentgrip-%s" style="width: %dpx; height: %dpx;"></div>'
					.. "</div>",
				tint,
				selected,
				Graph.commentElementId(frame.id),
				Graph.px(frame.x),
				Graph.px(frame.y),
				Graph.px(frame.w),
				Graph.px(frame.h),
				escapeRml(tostring(frame.id)),
				Graph.px(frame.w),
				Graph.px(GRAPH.commentHeadPx),
				escapeRml(tostring(frame.id)),
				Graph.px(GRAPH.commentTitlePx),
				Graph.px(GRAPH.commentHeadPx),
				Graph.px(GRAPH.commentHeadPx),
				Graph.px(GRAPH.commentTitleInsetPx),
				Graph.px(math.max(40, frame.w - GRAPH.commentTitleInsetPx * 2)),
				escapeRml(tostring(frame.title or "")),
				escapeRml(tostring(frame.id)),
				Graph.px(GRAPH.commentGripPx),
				Graph.px(GRAPH.commentGripPx)
			)
		end

		-- Edges first so nodes paint over their endpoints.
		-- Which edges touch which node, so a drag can move them without rebuilding the canvas.
		-- Connectors touching the selection are picked out, so that choosing a trigger shows
		-- what it reaches without anyone having to trace a line across the canvas.
		Graph.pruneSelection()
		local selectedKeys = Graph.selectionSet()

		-- Heights FIRST. The connector anchors, the port boxes, the canvas size and the drop hit
		-- test all ask `Graph.heightOf`, and every one of them runs below this point, so the
		-- answer has to already be right by the time the first edge is laid out.
		S.nodeH = {}
		local nodeRows, nodeForms = {}, {}
		for _, section in ipairs(Graph.adapter.kinds) do
			for _, record in ipairs(Graph.adapter.records(section.kind)) do
				local key = nodeKey(section.kind, record.id)
				local rows = Graph.rowsFor(section.kind, record)
				nodeRows[key] = rows
				-- An OPEN node edits its parameters in place (stage three, Q8): every parameter of
				-- its type, as a live control, through the same form the panel uses. A kind with
				-- no form (a stage) keeps its read-only rows.
				local form = S.expanded[key] == true and Graph.adapter.form("node:" .. key, section.kind, record.id)
					or nil
				if form then
					nodeForms[key] = form
					S.nodeH[key] = Graph.lib.MeasureNode(#form, #Graph.outPortsOf(key), true, GRAPH.editRowPx)
				else
					S.nodeH[key] = Graph.measureNode(key, rows)
				end
			end
		end

		S.graphEdgesByNode = {}
		-- How many bars each connector was built with, so a drag restyles exactly those.
		S.graphEdgeSegments = {}
		-- The curve itself, kept so a click can be hit-tested against it. Point-to-polyline in
		-- canvas units, rather than making several hundred one-pixel divs clickable: RmlUi would
		-- have to hit-test every one of them on every mouse move, and a two-pixel bar is not
		-- something anybody can hit anyway.
		S.graphEdgePoints = {}
		-- Which nodes a connector leaves and arrives at, for the port dots below.
		local hasOut, hasIn = {}, {}
		local edges = Graph.adapter.edges()
		S.graphEdgeList = edges
		for index, edge in ipairs(edges) do
			local points = Graph.edgeCurve(
				S.layout[edge.from],
				S.layout[edge.to],
				nil,
				Graph.heightOf(edge.from),
				Graph.heightOf(edge.to),
				Graph.portY(edge.from, "out", edge.port),
				Graph.portX(edge.from, edge.port)
			)
			if points then
				S.graphEdgeSegments[index] = points.n
				S.graphEdgePoints[index] = points
				local onCycle = inCycle[edge.from] and inCycle[edge.to]
				local onSelection = selectedKeys[edge.from] or selectedKeys[edge.to]
				local classes = "ng-edge"
				if onCycle then
					classes = classes .. " ng-edge-cycle"
				end
				-- A wire's KIND is the adapter's word for it, and it rides on the bars as a class
				-- (`ng-edge-<kind>`) for anything that wants to style one kind apart.
				if edge.kind then
					classes = classes .. " ng-edge-" .. edge.kind
				end
				if onSelection then
					classes = classes .. " ng-edge-selected"
				end
				local picked = S.graphSelEdge
				if picked and picked.from == edge.from and picked.to == edge.to then
					classes = classes .. " ng-edge-picked"
				end

				-- EVERY wire carries the gradient of the two kinds it joins (PtaQ, 2026-09-26);
				-- only a cycle (it pulses) and the picked wire (bright gold) are the stylesheet's,
				-- because an inline colour would win over it. A wire touching the selection keeps
				-- its gradient at full strength, so it stands out without losing what it links.
				local fromTint, toTint = Graph.tintOf(edge.from), Graph.tintOf(edge.to)
				local pickedEdge = S.graphSelEdge
				local isPicked = pickedEdge and pickedEdge.from == edge.from and pickedEdge.to == edge.to
				local tinted = not (onCycle or isPicked)
				-- How strongly an ordinary wire is drawn is the adapter's call (a mission draws a
				-- prerequisite faint); one touching the selection is always full strength.
				local alpha = onSelection and 0xff or Graph.adapter.edgeStrength(edge)

				-- NO ARROWHEAD. It was a small square turned 45 degrees at the midpoint, and at
				-- the thickness these are drawn at it read as a lump on the curve rather than as
				-- a chevron. Which way a wire runs is already said by the ports it joins: every
				-- one leaves the right-hand side of a node and arrives at the left-hand side of
				-- another, so every curve in the graph runs left to right.
				for segment = 1, points.n do
					local left, top, width, angle = Graph.segmentStyle(points[segment], points[segment + 1])
					local colour = ""
					if tinted then
						local along = points.n > 1 and (segment - 1) / (points.n - 1) or 0
						colour = " background-color: " .. Graph.mixTint(fromTint, toTint, along, alpha) .. ";"
					end
					parts[#parts + 1] = string.format(
						'<div class="%s" id="%s" style="%s%s"></div>',
						classes,
						Graph.segmentElementId(index, segment),
						Graph.barStyle(left, top, width, angle),
						colour
					)
				end
				hasOut[edge.from] = true
				hasIn[edge.to] = true
			end
			for _, key in ipairs({ edge.from, edge.to }) do
				S.graphEdgesByNode[key] = S.graphEdgesByNode[key] or {}
				local touching = S.graphEdgesByNode[key]
				-- The two ENDS are not the whole edge, and everything that reads this index treats
				-- what it gets back as one. `Graph.clearPort` filters by the port a wire left, a
				-- picked-up wire is re-pointed through the port it was written from, and
				-- `Graph.describeEdge` reads the kind and the hook to build its sentence -- so an
				-- entry carrying only `from` and `to` made alt-clicking a named port find nothing
				-- to cut and made a picked-up hook describe itself as something else.
				touching[#touching + 1] = {
					index = index,
					from = edge.from,
					to = edge.to,
					kind = edge.kind,
					port = edge.port,
					hook = edge.hook,
				}
			end
		end

		local search = (S.graphFind or ""):lower()

		local function nodeMarkup(kind, entry)
			local key = nodeKey(kind, entry.id)
			local position = S.layout[key]
			if not position then
				return
			end
			local classes = "ng-node ng-node-" .. kind
			-- Searching dims what does not match rather than hiding it: a node that vanished would
			-- take its edges' meaning with it, and the point of the search is to find something in
			-- the shape you already have.
			local found = Graph.findMatch(kind, entry)
			if found == true then
				classes = classes .. " ng-node-found"
			elseif found == false then
				classes = classes .. " ng-node-dim"
			end
			if selectedKeys[key] then
				classes = classes .. " ng-node-selected"
			end
			if inCycle[key] then
				classes = classes .. " ng-node-cycle"
			end
			-- The adapter's optional fades: `fade` pushes a node back (a mission: already happened
			-- at the checkpoint), `dim` further (a mission: not on the difficulty tier shown).
			if marks.fade and marks.fade[key] then
				classes = classes .. " ng-node-fade"
			end
			if marks.dim and marks.dim[key] then
				classes = classes .. " ng-node-dim"
			end
			-- The ports are CHILDREN of the node, so they travel with it for free and a plain
			-- `.ng-node:hover .ng-port-idle` rule is all it takes to reveal the unused ones.
			-- They sit just inside the box because .ng-node clips what overflows it.
			--
			-- Only a trigger gets an output: a trigger is the only thing in the model that fires
			-- anything. Both kinds get an input, because an action is fired by a trigger and a
			-- trigger can be listed as another's prerequisite.
			-- Every measurement is written inline at the current zoom. The stylesheet keeps the
			-- same numbers as its 1:1 defaults, so the placeholder markup in the RML still looks
			-- right and anything not listed here degrades to a sensible size.
			-- The grab strip: full node height, `portHitPx` wide, transparent, hard against the
			-- node's edge. The visible dot is a child of it, centred vertically and pushed to the
			-- outer end, so what is DRAWN has not moved and what can be GRABBED is far bigger.
			local nodeH = Graph.heightOf(key)
			local outList = Graph.outPortsOf(key)
			local outMetrics = Graph.portMetrics(#outList)
			-- The INPUT strip still runs the node's full height: a node has one input and there is
			-- nothing for it to collide with.
			local portStyle =
				string.format("top: 0px; width: %dpx; height: %dpx;", Graph.px(GRAPH.portHitPx), Graph.px(nodeH))
			-- The strip STRADDLES the node's edge: half of it lies over the canvas, which is the
			-- half a pointer approaching from outside crosses first. Everything inside it is then
			-- placed from the strip's own outer edge, and the node's edge is its middle.
			local stripEdge = Graph.px(-GRAPH.portHitPx / 2)
			local dotEdge = Graph.px((GRAPH.portHitPx - GRAPH.portPx) / 2)
			local haloEdge = Graph.px((GRAPH.portHitPx - GRAPH.portHaloPx) / 2)
			-- The ring's own border has to be written inline with its size, or it stays one pixel
			-- at every zoom while the circle it outlines grows: the same rule the dot's radius and
			-- the connectors' caps are written by.
			local haloStyle = string.format(
				"top: %dpx; width: %dpx; height: %dpx; border-radius: %dpx; border-width: %dpx;",
				Graph.px(nodeH / 2 - GRAPH.portHaloPx / 2),
				Graph.px(GRAPH.portHaloPx),
				Graph.px(GRAPH.portHaloPx),
				Graph.px(GRAPH.portHaloPx / 2),
				math.max(1, Graph.px(1))
			)
			local dotStyle = string.format(
				"top: %dpx; width: %dpx; height: %dpx; border-radius: %dpx;",
				Graph.px(nodeH / 2 - GRAPH.portPx / 2),
				Graph.px(GRAPH.portPx),
				Graph.px(GRAPH.portPx),
				Graph.px(GRAPH.portPx / 2)
			)
			-- The square variant, for a port that holds exactly one wire. It has to be written
			-- inline like the rest: the radius above is inline, and an inline value beats the
			-- stylesheet, so a `.ng-port-single` rule on its own would never be seen.
			local dotStyleSingle = string.format(
				"top: %dpx; width: %dpx; height: %dpx; border-radius: %dpx;",
				Graph.px(nodeH / 2 - GRAPH.portPx / 2),
				Graph.px(GRAPH.portPx),
				Graph.px(GRAPH.portPx),
				math.max(1, Graph.px(1))
			)
			local ports = string.format(
				'<div class="ng-port ng-port-in%s" id="%s" style="%s left: %dpx;">'
					.. '<div class="ng-port-halo" style="%s left: %dpx;"></div>'
					.. '<div class="ng-port-dot" style="%s left: %dpx;"></div></div>',
				hasIn[key] and "" or " ng-port-idle",
				Graph.portElementId(key, "in"),
				portStyle,
				stripEdge,
				haloStyle,
				haloEdge,
				dotStyle,
				dotEdge
			)
			-- One output port per thing the node can do. A trigger fires, a stage activates, an
			-- action names at most one thing -- all single ports, unchanged. An OBJECTIVE carries
			-- six, each writing its own field, each labelled, because one dot could not say which
			-- of the six a dropped wire meant.
			--
			-- `hasOut` is per NODE and a named port needs to know about itself, so which ports
			-- actually carry a wire is read off the edges this render already indexed.
			local wired = {}
			for _, edge in ipairs(S.graphEdgeList or {}) do
				if edge.from == key then
					wired[edge.port or true] = true
				end
			end
			for index, port in ipairs(outList) do
				local offset = Graph.portOffset(index, #outList, nodeH)
				local stripH = outMetrics.pitch or nodeH
				local stripTop = (outMetrics.pitch and (offset - stripH / 2)) or 0
				-- NOT `(#outList > 1) and wired[port.name] or hasOut[key]`. An `and`/`or` chain
				-- whose middle term is nil falls through to the third, so every unwired port on a
				-- node that had ANY wire leaving it read as connected, and all six of an
				-- objective's dots showed filled the moment one of them was used.
				local live
				if #outList > 1 then
					live = wired[port.name] == true
				else
					live = hasOut[key] == true
				end
				-- The name floats OUTSIDE the node, past the dot, and only while the node is hovered
				-- (PtaQ, 2026-09-26): inside, six names took a column the parameter rows needed and
				-- the rows' controls ran over them.
				local label = ""
				if port.label then
					-- A WIRED port keeps its name on show, and its wire leaves from the name's far
					-- end (Graph.portX), so the name reads as the start of the wire.
					local text = port.label:upper()
					label = string.format(
						'<div class="ng-port-label%s" id="%s" style="left: %dpx; top: %dpx; width: %dpx; font-size: %dpx; height: %dpx; '
							.. 'line-height: %dpx; border-radius: %dpx;">%s</div>',
						wired[port.name] and " ng-port-label-wired" or "",
						Graph.portElementId(key, "out", port.name) .. "-label",
						Graph.px(GRAPH.nodeWidth + Graph.lib.PortLabelLead()),
						Graph.px(offset - GRAPH.subRowPx / 2),
						Graph.px(Graph.lib.PortLabelBoxWidth(outList)),
						Graph.px(GRAPH.portLabelPx),
						Graph.px(GRAPH.subRowPx),
						Graph.px(GRAPH.subRowPx),
						Graph.px(4),
						escapeRml(text)
					)
				end
				-- Every measurement inline at the current zoom, and the radii with them: a radius
				-- left in the stylesheet stays one size while the box it rounds grows, which is the
				-- trap this canvas has paid for three times.
				ports = ports
					.. label
					.. string.format(
						'<div class="ng-port ng-port-out%s%s" id="%s" style="top: %dpx; width: %dpx; '
							.. 'height: %dpx; right: %dpx;">'
							.. '<div class="ng-port-halo" style="top: %dpx; width: %dpx; height: %dpx; '
							.. 'border-radius: %dpx; border-width: %dpx; right: %dpx;"></div>'
							.. '<div class="ng-port-dot" style="top: %dpx; width: %dpx; height: %dpx; '
							.. 'border-radius: %dpx; right: %dpx;"></div></div>',
						live and "" or " ng-port-idle",
						port.single and " ng-port-single" or "",
						Graph.portElementId(key, "out", port.name),
						Graph.px(stripTop),
						Graph.px(GRAPH.portHitPx),
						Graph.px(stripH),
						stripEdge,
						Graph.px(stripH / 2 - outMetrics.halo / 2),
						Graph.px(outMetrics.halo),
						Graph.px(outMetrics.halo),
						Graph.px(outMetrics.halo / 2),
						math.max(1, Graph.px(1)),
						Graph.px((GRAPH.portHitPx - outMetrics.halo) / 2),
						Graph.px(stripH / 2 - GRAPH.portPx / 2),
						Graph.px(GRAPH.portPx),
						Graph.px(GRAPH.portPx),
						port.single and math.max(1, Graph.px(1)) or Graph.px(GRAPH.portPx / 2),
						dotEdge
					)
			end
			-- A node with port NAMES keeps its hover for half its width past its right edge, so
			-- the pointer can travel out to a name without it vanishing (PtaQ, 2026-09-26). The
			-- pad is `visibility: hidden` until the node is hovered, so it never takes a press on
			-- its own.
			if Graph.lib.PortLabelBoxWidth(outList) > 0 then
				ports = ports
					.. string.format(
						'<div class="ng-node-hoverpad" style="left: %dpx; top: 0px; width: %dpx; height: %dpx;"></div>',
						Graph.px(GRAPH.nodeWidth),
						Graph.px(GRAPH.nodeWidth / 2),
						Graph.px(nodeH)
					)
			end
			-- The body: one summary line when the node is shut, one row per set parameter when it
			-- is open. This is what makes a node worth reading -- `TimeElapsed` says nothing on its
			-- own, `TimeElapsed / frame 900` says what the trigger does.
			local rows = nodeRows[key] or {}
			local open = S.expanded[key] == true
			local body = ""
			-- An open node is taller than the layout's row pitch, so it is drawn ABOVE its
			-- neighbours rather than under the next one down.
			if open then
				classes = classes .. " ng-node-open"
			end
			if open and nodeForms[key] then
				body = Graph.nodeEditorRows(nodeForms[key])
			elseif open then
				for _, row in ipairs(rows) do
					body = body
						.. string.format(
							'<div class="ng-node-param" style="font-size: %dpx; height: %dpx;">'
								.. '<div class="ng-node-plabel">%s</div>'
								.. '<div class="ng-node-pvalue">%s</div></div>',
							Graph.px(GRAPH.paramPx),
							Graph.px(GRAPH.paramRowPx),
							escapeRml(row.label),
							escapeRml(row.value)
						)
				end
			elseif #rows > 0 then
				-- As many lines as the shut box has room for, WRAPPED (PtaQ, 2026-09-26): an
				-- objective is tall for its six ports and its summary ran off one line past
				-- empty space. Everything else has room for exactly one, as before.
				local room = Graph.heightOf(key) - GRAPH.titleBarPx - GRAPH.bodyGapPx - GRAPH.subRowPx - GRAPH.bottomPx
				local lines = math.max(1, math.floor(room / GRAPH.paramRowPx))
				-- What a SHUT node says is the adapter's (a shut objective: only its text).
				rows = Graph.adapter.summary(kind, entry, rows)
				body = string.format(
					'<div class="ng-node-param ng-node-summary%s" style="font-size: %dpx; height: %dpx; line-height: %dpx;">'
						.. '<div class="ng-node-pvalue">%s</div></div>',
					lines > 1 and " ng-node-summary-wrap" or "",
					Graph.px(GRAPH.paramPx),
					Graph.px(lines * GRAPH.paramRowPx),
					Graph.px(GRAPH.paramRowPx),
					escapeRml(lines > 1 and Graph.summaryText(rows) or Graph.summaryLine(rows))
				)
			end

			-- The badge: a short chip the adapter puts on the node (a mission: its bound zone).
			local zone = Graph.adapter.badge(kind, entry)
			local zoneChip = ""
			if zone then
				zoneChip = string.format(
					'<div class="ng-node-badge" id="ng-gbadge-%s-%s" style="font-size: %dpx; height: %dpx;">%s</div>',
					kind,
					escapeRml(entry.id),
					Graph.px(GRAPH.subPx),
					Graph.px(GRAPH.subRowPx),
					escapeRml(zone)
				)
			end

			-- The adapter's optional second chip (`marks().chips`, key -> text), beside the badge
			-- (a mission: the difficulty tiers a trigger is limited to).
			local tiers = marks.chips and marks.chips[key]
			if tiers then
				zoneChip = zoneChip
					.. string.format(
						'<div class="ng-node-chip" style="font-size: %dpx; height: %dpx;">%s</div>',
						Graph.px(GRAPH.subPx),
						Graph.px(GRAPH.subRowPx),
						escapeRml(tiers)
					)
			end

			-- A red dot on a node with a dangling reference. VALIDATE has always counted these and
			-- the count told nobody WHICH box to look in.
			local flag = ""
			if marks.warn[key] then
				classes = classes .. " ng-node-warn"
				flag = string.format(
					'<div class="ng-node-flag" style="width: %dpx; height: %dpx; border-radius: %dpx;"></div>',
					Graph.px(GRAPH.flagPx),
					Graph.px(GRAPH.flagPx),
					Graph.px(GRAPH.flagPx / 2)
				)
			end

			-- The second line. A trigger and an action have a type to show; an objective and a
			-- stage have none, so they say what they are -- and a stage says whether it is the one
			-- the mission OPENS in, which `doc.initialStage` names and which nothing on the canvas
			-- used to say at all.
			local subtitle, subtitleClass = Graph.adapter.subtitle(kind, entry)
			if subtitleClass then
				classes = classes .. " " .. subtitleClass
			end

			-- The EXPAND STUB (PtaQ, 2026-09-26; it replaced the full-width EDIT PARAMETERS bar): a
			-- pill with a chevron on the node's bottom edge, half of it hanging below the box, so it
			-- takes almost no room and is still easy to hit. Bound (`graphExpand`); it stops its
			-- click, so it never also selects the node. A node with nothing to edit has none.
			local caret = ""
			local count = nodeForms[key] and #nodeForms[key] or #rows
			local canOpen = count > 0 or Graph.adapter.editable(kind)
			if canOpen then
				local chevron = Graph.px(8)
				caret = string.format(
					'<div class="ng-node-expand%s" id="ng-gexpand-%s-%s" title="%s" '
						.. 'style="left: %dpx; top: %dpx; width: %dpx; height: %dpx; border-radius: %dpx;" '
						.. "data-event-click=\"graphExpand('%s')\">"
						.. '<div class="ng-node-chevron" style="left: %dpx; top: %dpx; width: %dpx; height: %dpx; '
						.. 'border-right-width: %dpx; border-bottom-width: %dpx;"></div></div>',
					open and " ng-node-expand-open" or "",
					kind,
					escapeRml(entry.id),
					open and "Hide the parameters"
						or ("Edit the parameters" .. (count > 0 and (" (" .. count .. ")") or "")),
					Graph.px((GRAPH.nodeWidth - GRAPH.stubW) / 2),
					Graph.px(Graph.heightOf(key) - GRAPH.stubH / 2),
					Graph.px(GRAPH.stubW),
					Graph.px(GRAPH.stubH),
					Graph.px(GRAPH.stubH / 2),
					escapeRml(key),
					math.floor((Graph.px(GRAPH.stubW) - chevron) / 2),
					-- A down chevron sits a little high in its box and an up one a little low,
					-- so each reads as centred once it is turned.
					math.floor((Graph.px(GRAPH.stubH) - chevron) / 2) + (open and Graph.px(2) or -Graph.px(2)),
					chevron,
					chevron,
					math.max(1, Graph.px(2)),
					math.max(1, Graph.px(2))
				)
			end

			-- OVERVIEW: zoomed out, a shut node is its name and nothing else, the title bar filling
			-- the box and the name on one line as big as fits (Graph.overviewFit). Same box, same ports, same
			-- ids for the title and the node, so wires, clicks and rename behave as they do above it.
			if not open and Graph.isOverview() then
				local innerW = Graph.px(GRAPH.nodeWidth - 2 * GRAPH.padX)
				local boxH = Graph.px(nodeH)
				local font, text = Graph.overviewFit(entry.id, innerW, boxH - Graph.px(12))
				local lineH = math.ceil(font * 1.15)
				local textH = lineH
				local padTop = math.max(0, math.floor((boxH - textH) / 2))
				parts[#parts + 1] = string.format(
					'<div class="%s ng-node-overview" id="ng-gnode-%s-%s" style="left: %dpx; top: %dpx; width: %dpx; '
						.. 'height: %dpx; padding: 0px %dpx;">'
						.. '<div class="ng-node-titlebar" style="height: %dpx; padding-top: %dpx; margin: 0px -%dpx; border-radius: %dpx;">'
						.. '<div class="ng-node-title" id="ng-gtitle-%s-%s" style="font-size: %dpx; line-height: %dpx; height: %dpx; '
						.. 'margin-left: %dpx; max-width: %dpx;">%s</div></div>'
						.. "%s%s</div>",
					classes,
					kind,
					escapeRml(entry.id),
					Graph.px(position.x),
					Graph.px(position.y),
					Graph.px(GRAPH.nodeWidth),
					boxH,
					Graph.px(GRAPH.padX),
					boxH - padTop,
					padTop,
					Graph.px(GRAPH.padX),
					Graph.px(5),
					kind,
					escapeRml(entry.id),
					font,
					lineH,
					textH,
					Graph.px(GRAPH.padX),
					innerW,
					escapeRml(text),
					flag,
					ports
				)
				return
			end

			-- The title bar spans the whole box: negative side margins undo the port gutter.
			parts[#parts + 1] = string.format(
				'<div class="%s" id="ng-gnode-%s-%s" style="left: %dpx; top: %dpx; width: %dpx; '
					.. 'height: %dpx; padding: 0px %dpx;">'
					.. '<div class="ng-node-titlebar" style="height: %dpx; margin: 0px -%dpx %dpx -%dpx; '
					.. 'border-radius: %dpx %dpx 0px 0px;">'
					.. '<div class="ng-node-title" id="ng-gtitle-%s-%s" style="font-size: %dpx; height: %dpx; '
					.. 'line-height: %dpx; margin-left: %dpx; max-width: %dpx;">%s</div></div>'
					.. '<div class="ng-node-subrow" style="height: %dpx;">'
					.. '<div class="ng-node-sub" style="font-size: %dpx; height: %dpx;">%s</div>%s</div>'
					.. "%s%s%s%s</div>",
				classes,
				kind,
				escapeRml(entry.id),
				Graph.px(position.x),
				Graph.px(position.y),
				Graph.px(GRAPH.nodeWidth),
				Graph.px(Graph.heightOf(key)),
				Graph.px(GRAPH.padX),
				Graph.px(GRAPH.titleBarPx),
				Graph.px(GRAPH.padX),
				Graph.px(GRAPH.bodyGapPx),
				Graph.px(GRAPH.padX),
				Graph.px(5),
				Graph.px(5),
				kind,
				escapeRml(entry.id),
				Graph.px(GRAPH.titlePx),
				Graph.px(GRAPH.titleBarPx),
				Graph.px(GRAPH.titleBarPx),
				Graph.px(GRAPH.padX),
				Graph.px(GRAPH.nodeWidth - 2 * GRAPH.padX),
				escapeRml(entry.id),
				Graph.px(GRAPH.subRowPx),
				Graph.px(GRAPH.subPx),
				Graph.px(GRAPH.subRowPx),
				escapeRml(subtitle),
				zoneChip,
				body,
				caret,
				flag,
				ports
			)
		end

		-- In the adapter's kind order, which is paint order: stages sit at the bottom, then the
		-- objectives they activate, then the triggers those fire, then the actions. Where boxes
		-- overlap, the thing further along the flow draws over the thing that caused it.
		for _, section in ipairs(Graph.adapter.kinds) do
			for _, record in ipairs(Graph.adapter.records(section.kind)) do
				nodeMarkup(section.kind, record)
			end
		end

		-- The bars of the connector that follows the pointer while one is being dragged off a
		-- port. They are built here, hidden, rather than while the drag is running: building
		-- markup inside an event is what replaces the element RmlUi is dispatching to, and this
		-- panel has already paid for that once. A drag only ever restyles them.
		for index = 1, Graph.LIVE_SEGMENTS do
			parts[#parts + 1] =
				string.format('<div class="ng-edge ng-edge-live hidden" id="%s"></div>', Graph.liveSegmentId(index))
		end
		-- And the hover overlay's bars, built here and hidden for the same reason: markup is never
		-- built inside an event, and a hover arrives as one.
		for index = 1, Graph.HOVER_SEGMENTS do
			parts[#parts + 1] =
				string.format('<div class="ng-edge ng-edge-hover hidden" id="%s"></div>', Graph.hoverSegmentId(index))
		end
		-- The SEVER button, shown at the middle of the hovered wire while the pointer is there;
		-- a click there cuts it (`Graph.clickCanvasAt`). It never takes the pointer itself: the
		-- click is the canvas's, hit-tested against the wire like every other wire click. The
		-- cross is two bars, so it scales with the zoom like everything else in here.
		local icon = Graph.px(Graph.SEVER_ICON_PX)
		local barW, barH = math.floor(icon * 0.5), math.max(2, Graph.px(2))
		local bar = string.format(
			"left: %dpx; top: %dpx; width: %dpx; height: %dpx;",
			math.floor((icon - barW) / 2),
			math.floor((icon - barH) / 2),
			barW,
			barH
		)
		parts[#parts + 1] = string.format(
			'<div class="ng-edge-sever hidden" id="ng-edge-sever" style="width: %dpx; height: %dpx; border-radius: %dpx; border-width: %dpx;">'
				.. '<div class="ng-edge-sever-bar" style="%s transform: rotate(45deg);"></div>'
				.. '<div class="ng-edge-sever-bar" style="%s transform: rotate(-45deg);"></div></div>',
			icon,
			icon,
			math.ceil(icon / 2),
			math.max(1, Graph.px(1)),
			bar,
			bar
		)
		-- The letters of a named port's label, laid along the wire in flight (Graph.layLiveLabel).
		for index = 1, Graph.LIVE_LABEL_CHARS do
			parts[#parts + 1] =
				string.format('<div class="ng-live-char hidden" id="%s"></div>', Graph.liveCharId(index))
		end

		canvas.inner_rml = table.concat(parts)
		-- The zoom this markup was built at: an animated zoom scales it by transform from here.
		if S.viewAnim then
			S.rendersDuringGlide = (S.rendersDuringGlide or 0) + 1
		end
		S.renderedZoom = S.graphView.zoom
		-- The overlay bars the hover was drawn on have just been destroyed and replaced by hidden
		-- ones, so the next poll has to work it out again from scratch.
		S.hoverEdge = nil
		S.hoverSever = nil
		S.hoverPointerX = nil

		local nodeCount = 0
		for _, section in ipairs(Graph.adapter.kinds) do
			nodeCount = nodeCount + #Graph.adapter.records(section.kind)
		end
		setText(
			"ng-graph-status",
			Graph.adapter.markToggle
					and string.format(
						"%d nodes, %d edges, %d %s%s",
						nodeCount,
						#edges,
						marks.loops or 0,
						(Graph.adapter.markToggle.label or "marks"):lower(),
						Graph.selectionNote()
					)
				or string.format("%d nodes, %d edges%s", nodeCount, #edges, Graph.selectionNote())
		)

		-- The adapter's warning about the graph as a whole, or none. The
		-- HOST decides where it shows.
		Graph.host.notice(Graph.adapter.notice())

		-- Rebuild killed the old handles, so re-wire selection and dragging.
		--
		-- Both, on the same element: mousedown starts a drag and `click` still selects, so a
		-- grab that never moved reads as a click. The mousedown must NOT stop propagation --
		-- nothing else on the canvas listens for it, and swallowing it would cost the click.
		S.elementCache = {}

		-- The comment frames' title bars. Only the bar is live; the frame body is
		-- `pointer-events: none` so the nodes inside it still take their own clicks.
		for _, frame in ipairs(Graph.comments()) do
			local headId = "ng-gcommenthead-" .. tostring(frame.id)
			local captured = frame.id
			onClick(headId, function(event)
				local onTitle = false
				local target = event and event.target_element
				while target do
					if target:IsClassSet("ng-comment-title") then
						onTitle = true
					end
					if target:IsClassSet("ng-comment-head") then
						break
					end
					target = target.parent_node
				end
				local now = Spring.GetTimer()
				local last = S.lastCommentClick
				if
					onTitle
					and last
					and last.id == captured
					and Spring.DiffTimers(now, last.at) <= Graph.DOUBLE_CLICK_S
				then
					S.lastCommentClick = nil
					Graph.editCommentTitle(captured)
					return
				end
				S.lastCommentClick = onTitle and { id = captured, at = now } or nil
				S.graphSelComment = captured
				Graph.clearSelection()
				S.graphSelComment = captured
				S.elementCache = {}
				render()
			end)
			local grip = el("ng-gcommentgrip-" .. tostring(frame.id))
			if grip then
				grip:AddEventListener("dragstart", function(event)
					local q = event and event.parameters or {}
					local px, py = Graph.pointerScreen(q.mouse_x, q.mouse_y)
					Graph.beginCommentResize(captured, px, py)
					if event and event.StopPropagation then
						event:StopPropagation()
					end
				end, false)
				grip:AddEventListener("drag", function(event)
					local q = event and event.parameters or {}
					Graph.resizeCommentTo(Graph.pointerScreen(q.mouse_x, q.mouse_y))
				end, false)
				grip:AddEventListener("dragend", function()
					Graph.endCommentResize()
				end, false)
			end

			local head = el(headId)
			if head then
				head:AddEventListener("dblclick", function()
					Graph.editCommentTitle(captured)
				end, false)
				head:AddEventListener("dragstart", function(event)
					local q = event and event.parameters or {}
					local px, py = Graph.pointerScreen(q.mouse_x, q.mouse_y)
					Graph.beginCommentDrag(captured, px, py)
				end, false)
				head:AddEventListener("drag", function(event)
					local q = event and event.parameters or {}
					local px, py = Graph.pointerScreen(q.mouse_x, q.mouse_y)
					Graph.dragCommentTo(px, py)
				end, false)
				head:AddEventListener("dragend", function()
					Graph.endCommentDrag()
				end, false)
			end
		end

		-- The adapter's kinds, so every kind the canvas PAINTS is also a kind that can be clicked,
		-- dragged, renamed, expanded and wired. This was its own copy of the list, with triggers
		-- and actions in it and nothing else, so objectives drew as nodes and then ignored every
		-- gesture aimed at them.
		for _, section in ipairs(Graph.adapter.kinds) do
			local kind = section.kind
			for _, record in ipairs(Graph.adapter.records(kind)) do
				local id, key = record.id, nodeKey(kind, record.id)
				local elementId = "ng-gnode-" .. kind .. "-" .. id
				onClick(elementId, function(event)
					if S.palette or S.commentEdit or S.nodeRename then
						Graph.closePalette()
						Graph.closeCommentEdit()
						Graph.closeNodeRename()
						return
					end
					-- The click RmlUi raises at the end of a drag that actually moved something.
					-- Releasing a drag is not choosing what to select, and letting it through
					-- collapsed a multi-selection to one node the moment it was put down.
					if S.graphDragMoved then
						S.graphDragMoved = nil
						return
					end
					-- The second click of a double-click opens or shuts the node; the first has
					-- already selected it.
					-- A click on the hover pad is a click on nothing.
					if Graph.eventFrom(event, { "ng-node-hoverpad" }) then
						return
					end
					-- On the NAME it renames in place, like a folder (the first click re-rendered
					-- the element, so RmlUi's own dblclick cannot be relied on).
					local double = Graph.isDoubleClick(key, event)
					if double == "title" then
						Graph.editNodeTitle(key)
						return
					elseif double == "type" and Graph.openRetype(key, Graph.pointerScreen()) then
						return
					elseif double then
						Graph.toggleExpanded(key)
						return
					end
					-- Plain click replaces the selection; ctrl toggles, shift adds.
					--
					-- Only a plain click moves the panel. Building a selection of six nodes should
					-- not drag the inspector through six different forms on the way, and following
					-- the last one added would leave the panel somewhere nobody asked for.
					if Graph.clickNode(key) then
						-- A stage and an objective are both inspected under OBJECTIVES: the stage
						-- chips and the objective list live in that one section, and
						-- `Graph.syncPrimary` has already put the id in `S.selected` for it.
						Graph.adapter.inspect(kind, id)
					end
					S.elementCache = {}
					render()
				end)
				-- The caret, and rename-on-double-click. Both are on their OWN elements and both
				-- stop the event: a listener on the node would fire for every click anywhere in the
				-- box, which is what "only catches the actual text" rules out.
				local capturedKey = key
				local title = el("ng-gtitle-" .. kind .. "-" .. id)
				if title then
					title:AddEventListener("dblclick", function(event)
						Graph.editNodeTitle(capturedKey)
						if event and event.StopPropagation then
							event:StopPropagation()
						end
					end, false)
				end

				local element = el(elementId)
				if element then
					-- RmlUi's drag events and nothing else. They need `drag: drag` on .ng-node in
					-- the RCSS, and they carry the pointer, which is the only reliable source of it
					-- while RmlUi owns the press.
					-- Each one stands down while a connector is being pulled off one of this
					-- node's ports. The port sits inside the node, so its drag events reach these
					-- listeners as well, and without this the node is dragged along with the
					-- connector.
					-- Every press clears the "that drag moved something" flag, whether or not it
					-- turns into a drag. `mousedown` arrives before both `dragstart` and `click`,
					-- so a plain click on a node is never mistaken for the end of a drag.
					element:AddEventListener("mousedown", function()
						S.graphDragMoved = nil
					end, false)
					element:AddEventListener("dragstart", function(event)
						if S.portDrag or Graph.dragFromField(event) then
							return
						end
						local p = event and event.parameters or {}
						Graph.beginNodeDrag(key, Graph.pointerScreen(p.mouse_x, p.mouse_y))
					end, false)
					element:AddEventListener("drag", function(event)
						if S.portDrag or Graph.dragFromField(event) then
							return
						end
						local p = event and event.parameters or {}
						local px, py = Graph.pointerScreen(p.mouse_x, p.mouse_y)
						if px then
							Graph.dragNodeTo(px, py)
						end
					end, false)
					element:AddEventListener("dragend", function(event)
						if S.portDrag or Graph.dragFromField(event) then
							return
						end
						Graph.endNodeDrag()
					end, false)
				end

				-- Every port on the node, not one per side: an objective has six outputs and each
				-- of them needs its own listeners, or five of them would be dots that do nothing.
				local handles = { { side = "in" } }
				for _, entry in ipairs(Graph.outPorts(kind, record)) do
					handles[#handles + 1] = { side = "out", name = entry.name }
				end
				for _, handle in ipairs(handles) do
					local side, portName = handle.side, handle.name
					-- The dot's strip, and for a named output its NAME box: a wire can be pulled
					-- off either (PtaQ, 2026-09-26).
					local grabs = { Graph.portElementId(key, side, portName) }
					if side == "out" and portName then
						grabs[2] = Graph.portElementId(key, side, portName) .. "-label"
					end
					for _, grabId in ipairs(grabs) do
						local port = el(grabId)
						if port then
							local capturedSide, capturedPort = side, portName
							-- Alt-click empties the port. The listener has to check the modifier itself
							-- rather than the drag doing it, because a click and a drag start the same
							-- way and only one of them means this.
							port:AddEventListener("click", function(event)
								local alt = Spring.GetModKeyState()
								if not alt then
									return
								end
								Graph.clearPort(key, capturedSide, capturedPort)
								if event and event.StopPropagation then
									event:StopPropagation()
								end
							end, false)
							port:AddEventListener("dragstart", function(event)
								local p = event and event.parameters or {}
								local dx, dy = Graph.pointerScreen(p.mouse_x, p.mouse_y)
								Graph.beginPortDrag(key, capturedSide, dx, dy, capturedPort)
								-- The node under this port is draggable too. Without stopping here
								-- the same press would also pick the node up and the connector would
								-- drag the box along with it.
								if event and event.StopPropagation then
									event:StopPropagation()
								end
							end, false)
							port:AddEventListener("drag", function(event)
								local p = event and event.parameters or {}
								local px, py = Graph.pointerScreen(p.mouse_x, p.mouse_y)
								if px then
									-- With `S.graphDebug` on this prints both spaces, so if these ever
									-- disagree again it is one line in the log rather than a guess.
									if S.graphDebug then
										echo(
											string.format(
												"port drag: rmlui %s,%s spring %s,%s zoom %.2f pan %d,%d",
												tostring(p.mouse_x),
												tostring(p.mouse_y),
												tostring(px),
												tostring(py),
												S.graphView.zoom,
												math.floor(S.graphView.panX),
												math.floor(S.graphView.panY)
											)
										)
									end
									Graph.dragPortTo(px, py)
								end
								if event and event.StopPropagation then
									event:StopPropagation()
								end
							end, false)
							port:AddEventListener("dragend", function(event)
								Graph.endPortDrag()
								if event and event.StopPropagation then
									event:StopPropagation()
								end
							end, false)
						end
					end
				end
			end
		end

		-- The map is drawn from the same layout this pass just placed, so it is rebuilt here and
		-- nowhere else. Panning does NOT come through here: that moves one rectangle, in
		-- `Graph.applyGraphView`.
		Graph.renderMinimap()
	end
end
