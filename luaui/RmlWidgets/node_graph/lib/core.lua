-- THE GRAPH CORE: generic node-graph geometry. Keys, sizes, ports, curves, hit tests, bounds
-- and layout, in canvas px, plus the adapter contract. It knows nothing about any one kind of
-- graph: what the kinds are, which records exist and which wires are legal belong to an
-- ADAPTER. Pure: every function takes what it reads. Specs: spec/node_graph/core_spec.lua.

local M = {}

-- THE ADAPTER CONTRACT. An adapter is a table with these fields; every one is required.
-- adapters/toy_ceg.lua answers each of them simply and is the one to copy.
--
--   kinds                      ordered { kind, tint = {r, g, b}, label?, short? }: paint order,
--                              layout bands, the palette (`label`, default KIND) and FIND
--                              (`short`, default the label's first three letters) chips, the
--                              wire gradient's colours. A node's LOOK is `.ng-node-<kind>` in
--                              the stylesheet (the toy's kinds are the template); `tint` is that
--                              kind's border colour, for the wires. Kind names are plain words
--   records(kind)              the records of a kind, each with an `id`
--   find(kind, id)             one record, or nil
--   layout(measure)            key -> { x, y } for every node (`M.LayoutBands` does bands)
--   outPorts(kind, record)     { name, label, wants, single } per output port
--   edges()                    { from, to, kind, port, hook } per wire
--   canLink(from, to, port)    ok, message
--   canLinkNew(pending, kind, type)  could a NEW node of this kind take the wire in flight
--   link(from, to, port)       ok, message (writes the document)
--   unlink(from, to, port)     ok
--   describeEdge(edge)         the wire in the document's own words, for the status line
--   edgeStrength(edge)         0..255, how strongly an ordinary wire's gradient is drawn
--   editable(kind)             can a node of this kind be opened to edit it
--   rows(kind, record)         read-only { label, value } rows (the open node, FIND)
--   summary(kind, record, rows)  the rows a SHUT node shows
--   subtitle(kind, record)     text under the title, and an extra node class or nil
--   badge(kind, record)        a short chip on the node, or nil
--   form(host, kind, id)       the node's editor rows (a bound form host), or nil
--   palette(pending)           { kind, type, new } the create palette offers
--   create(option)             key, message: a new record made from a palette option
--   inspect(kind, id, created) follow a node click (or a creation) with your inspector
--   syncInspector(keys)        the selection changed: point your inspector at it
--   haystack(kind, record)     lower-case words FIND searches
--   duplicate(keys)            { { fromKey, key } } copies, wires between them carried
--   remove(kind, id)           removed, detail
--   rename(kind, id, newId)    rename a record everywhere it is referenced; the id it now has,
--                              or nil when refused (the graph then moves its layout and selection)
--   connect(keys)              { { from, to } } the pairs a "connect the selection" makes,
--                              or nil, message
--   marks()                    { cycle = set of keys, warn = set of keys, loops = count }, and
--                              optionally `fade` / `dim` (sets of keys drawn pushed back) and
--                              `chips` (key -> short text, a second chip beside the badge)
--   notice()                   a warning about the graph as a whole, or nil
--   store()                    the table the GRAPH keeps its own data on, or nil: groupings in
--                              `store.comments`, saved positions in `store.layout`
--
-- OPTIONAL fields (a missing one turns its feature off):
--   contract                   the contract version the adapter was written for (node_graph.lua
--                              `CONTRACT`); a mismatch is echoed once
--   markToggle                 { label, title }: a toolbar chip that shows `marks().cycle` (a
--                              mission: CYCLES); without it the chip is hidden and the status
--                              line leaves out the loop count
--   copy(keys) -> payload, paste(payload) -> copies   Ctrl+C / Ctrl+V; `duplicate` is both
--   retypable(kind), retype(kind, id, type) -> ok, message   a double click on a node's type line

--- The required fields, as data: the host refuses an adapter that lacks one, and the contract
--- spec checks every adapter in the tree against it and against the list above.
M.ADAPTER_CONTRACT = {
	"kinds",
	"records",
	"find",
	"layout",
	"outPorts",
	"edges",
	"canLink",
	"canLinkNew",
	"link",
	"unlink",
	"describeEdge",
	"edgeStrength",
	"editable",
	"rows",
	"summary",
	"subtitle",
	"badge",
	"form",
	"palette",
	"create",
	"inspect",
	"syncInspector",
	"haystack",
	"duplicate",
	"remove",
	"rename",
	"connect",
	"marks",
	"notice",
	"store",
}

--- The contract fields an adapter does not have, in contract order.
---@param adapter table
---@return string[]
function M.MissingFields(adapter)
	local missing = {}
	for _, name in ipairs(M.ADAPTER_CONTRACT) do
		if type(adapter) ~= "table" or adapter[name] == nil then
			missing[#missing + 1] = name
		end
	end
	return missing
end

--- "emitter:muzzle". Every node on the canvas is keyed by its kind and its record id.
function M.Key(kind, id)
	return kind .. ":" .. id
end

function M.SplitKey(key)
	return key:match("^(%a+):(.+)$")
end

-------------------------------------------------------------------------------
-- Geometry: sizes, ports, curves, hit testing, layout. Canvas space, px (the canvas is px
-- by agreement: node positions are raw pixels). Every function takes the layout, the
-- measured heights or the view it reads.
-------------------------------------------------------------------------------

M.GRAPH = {
	-- These are what the LAYOUT believes a node is, and the stylesheet has to agree: the
	-- connector anchors, the port dots and the drop hit test are all derived from them.
	-- The height said 34 while the stylesheet drew 42, so connectors met the node four
	-- pixels above their own port and the bottom of every node was not a drop target.
	--
	-- Wider than it was, because the titles are record ids and they were being cut off.
	-- Wider and taller than they were, because a node now carries a line of its own
	-- parameters: `TimeElapsed` on its own never told anybody WHEN. Then 30% bigger again,
	-- with the palette, because both were hard to read.
	nodeWidth = 302,
	--- The COLLAPSED height, and it must stay equal to what `Graph.measureNode` returns for a
	--- shut node: title bar (34) + gap (12) + type (24) + one summary row (22) + the bottom
	--- room the expand stub's upper half sits in (10). Keep it EVEN: the connector anchors sit
	--- at half of it.
	---
	--- An expanded node is taller, and `Graph.heightOf` is what answers for a particular one.
	--- Everything that used to read this and meant "this node" now asks that instead.
	nodeHeight = 102,
	-- Everything inside a node, at 1:1. The renderer multiplies each of these by the zoom
	-- and writes it inline, which is what keeps the text sharp: a scaled TRANSFORM stretches
	-- the glyph textures, a scaled FONT SIZE is rasterised at the size it is drawn.
	-- Wide enough to clear the invisible grab strip down each edge, or the text starts
	-- underneath it: the first characters of every title vanished behind it, and a
	-- double-click meant for the title landed on the connector handle instead.
	-- The left edge every line of text in a node starts at, the title included (PtaQ,
	-- 2026-09-26: one axis). It clears the half of the input port's grab strip that lies inside
	-- the box, and no more.
	padX = 16,
	padY = 5,
	-- THE TITLE BAR (PtaQ, 2026-09-26): the node's name on a backdrop of its own, the full
	-- width of the box and centred in it, so the name is the first thing read.
	titleBarPx = 34,
	titlePx = 20,
	-- The gap between the title bar and the type line under it. Generous (PtaQ, 2026-09-26):
	-- the type sat hard under the bar.
	bodyGapPx = 12,
	subPx = 18,
	subRowPx = 24,
	-- The summary rows under the type. One of them when the node is collapsed, one per set
	-- parameter when it is open.
	paramPx = 15,
	-- Chosen so the collapsed height comes out EVEN. A connector meets a node at `height / 2`
	-- and the renderer writes whole pixels, so an odd height leaves every anchor half a pixel
	-- above its own port.
	paramRowPx = 22,
	-- How many parameters the collapsed line tries to fit before it gives up and says how many
	-- more there are.
	summaryFields = 4,
	-- THE EXPAND STUB (PtaQ, 2026-09-26, replacing the full-width EDIT PARAMETERS bar): a small
	-- pill with a chevron, centred on the node's bottom edge and half outside it, so it costs
	-- the node almost no height and is still a big thing to click. `bottomPx` is the room kept
	-- inside the node for the stub's upper half.
	stubW = 46,
	stubH = 20,
	bottomPx = 10,
	-- One EDITOR row in an expanded node: a label and a live control (text box, checkbox,
	-- select, pipette). Taller than a summary row because a control needs room to be hit.
	-- Even, like every height here.
	editRowPx = 32,
	editPx = 15,
	-- The dot on a node with a dangling reference.
	flagPx = 10,
	-- THE PORT DOT, centred on the node's edge rather than tucked inside it.
	--
	-- `Graph.outAnchor` starts a connector at exactly `x + nodeWidth` -- the node's own edge --
	-- so a dot drawn four pixels inside that left a gap between the dot and the wire it was
	-- supposedly attached to, and the wire appeared to start in mid air beside it. Centred on
	-- the anchor, the spline emerges from the middle of the dot, which is the only placement
	-- that reads as a connection. Bigger too, because it is now a thing to aim at.
	portPx = 14,
	-- The soft ring that appears under the pointer, so the grab area says where it is BEFORE
	-- the click rather than after it. Centred on the dot, so it reads as a halo, not a box.
	portHaloPx = 32,
	-- The INVISIBLE grab strip the dot sits in, running the full height of the node down its
	-- edge. The dot is 9px and asking anyone to hit 9px with a mouse is asking too much, so
	-- what takes the drag is this instead. It listens for `dragstart` only, which is what lets
	-- a plain CLICK in the same place still select the node.
	portHitPx = 32,
	-- The gap between two ports on a node that has more than one. An objective carries six,
	-- and six 44px grab strips down a 74px edge would be six strips on top of one another
	-- with nothing to aim at, so a multi-port node is spaced by this and made tall enough to
	-- hold them: see `Graph.portMetrics` and the floor in `Graph.measureNode`.
	portPitchPx = 24,
	-- A named port's NAME (an objective's six): capitals, beside its dot, outside the node. A
	-- wired port shows it always and its wire leaves from the end of it (`PortLabelEnd`), so
	-- the width has to be a number the layout knows, not something RmlUi measures.
	portLabelPx = 14,
	portLabelPadPx = 5,
	-- Average advance of a capital in the node font, as a fraction of its size. An estimate
	-- (Lua cannot measure text); the label box is written at the estimated width, so the wire
	-- meets the box exactly whatever the glyphs do inside it.
	portLabelAdvance = 0.62,
	edgePx = 5,
	-- 150 of this is the node, so the gap between two columns is what is left. It used to be
	-- 60px, which is less than a connector's own control offset: every curve was forced into
	-- a hairpin and the columns read as one wall of boxes. Widened so the connectors have
	-- room to leave horizontally and arrive horizontally, which is the whole look.
	columnGap = 440,
	-- The row PITCH, not the space between rows: it has to stay a clear gap above `nodeHeight`
	-- or the auto-layout stacks shut nodes on top of each other (it was 98 with 92px nodes).
	rowGap = 126,
	padding = 24,
	rowsPerColumn = 10,
	-- Zoom bounds. Below the minimum the labels stop being readable and the graph is only
	-- a shape; above the maximum a node fills the window and there is nothing to navigate.
	minZoom = 0.35,
	maxZoom = 2.2,
	zoomStep = 1.25, -- per wheel notch; 1.12 was sluggish (PtaQ, 2026-09-27)
	-- OVERVIEW (PtaQ, 2026-09-27): below this zoom a SHUT node shows only its name, filling the
	-- box on ONE line in the biggest type that fits (never wrapped). SCREEN
	-- pixels, not canvas units: the point is text that stays readable as the graph shrinks.
	overviewZoom = 0.6,
	overviewMinPx = 10,
	overviewMaxPx = 22,
	-- How far one wheel notch scrolls the canvas, in SCREEN pixels. The wheel scrolls and
	-- Ctrl+wheel zooms, the Windows convention (PtaQ, 2026-09-26).
	scrollStepPx = 60,
	-- The background grid: a line every `gridPx` canvas pixels, the spacing doubled until it is
	-- at least `gridMinPx` on screen so a zoomed-out canvas is not a grey wash.
	gridPx = 40,
	gridMinPx = 16,
	-- The shortest a scrollbar thumb gets, in screen pixels, so it can always be grabbed.
	scrollThumbMinPx = 28,
	-- However far the canvas is pushed, this much of it stays in the viewport, or a pan
	-- could throw the whole graph off screen with no way to find it again.
	panKeepPx = 90,
	-- How close to the viewport's edge a gesture has to come before the canvas starts moving
	-- under it, and how fast it moves at the very edge. The viewport clips and does not
	-- scroll, so without this a node cannot be dragged anywhere that is not already on screen.
	autoPanMarginPx = 56,
	autoPanSpeedPx = 14,
	-- How far a press may wander and still count as a click rather than a drag. RmlUi has no
	-- threshold of its own: it reports a drag on the first pixel of movement.
	clickSlopPx = 3,
	-- An arrow key moves the selection this far, and Shift makes it one pixel for the last
	-- bit of tidying. Eight, because it divides the row gap and nodes nudged with it stay in
	-- line with nodes the auto-layout placed.
	nudgePx = 8,
	-- Breathing room left around the selection when it is framed, as a fraction of the
	-- viewport. Framing a single node to the pixel puts its edges against the window and it
	-- reads as though it is about to fall out.
	frameMargin = 0.12,
	-- How far a node has to be offset when it is duplicated. Far enough to see that there are
	-- two, near enough to still read as a copy of that one.
	duplicateOffset = 36,
	-- A comment frame's title bar, and the room left around the nodes it was built from.
	commentHeadPx = 32,
	commentTitlePx = 18,
	-- Where a grouping's title starts, from the frame's left edge (the nodes' own axis).
	commentTitleInsetPx = 14,
	commentPadPx = 34,
	-- A frame made with nothing selected, so there is something to drag nodes into.
	commentBlankW = 546,
	commentBlankH = 338,
	-- THE MINIMAP. `minimapPadPx` is the margin left inside its box so a node sitting on the
	-- very edge of the graph still draws as a dot rather than as a line on the border, and
	-- `minimapDotPx` is the smallest a node may draw: a real mission scaled into 190dp puts a
	-- node at well under a pixel, and a map of invisible dots is a blank box.
	minimapPadPx = 4,
	minimapDotPx = 2,
	-- A grouping never shrinks below its own title bar plus somewhere to put a node.
	commentMinW = 180,
	commentMinH = 110,
	-- The corner a grouping is resized from.
	commentGripPx = 18,
	commentTints = 6,
}

local GRAPH = M.GRAPH

M.EDGE = {
	-- A short hop still has to curve, or it reads as the old straight bar.
	minTangent = 46,
	tangentRatio = 0.55,
	maxTangent = 190,
	-- Bars are spent on CURVATURE, not on length. A connector between two nodes at the same
	-- height is a straight line however long it is, and drawing it with fourteen bars instead
	-- of two costs a whole graph's worth of elements for no visible difference.
	--
	-- Bars are spent where the curve BENDS. A connector between two nodes at the same height
	-- is a straight line however long it is, and drawing that with thirty bars costs a whole
	-- graph's worth of elements for no visible difference.
	--
	-- Tightened again with the round caps, because the two work together: caps hide the joint,
	-- density keeps the chord close to the curve, and it takes both for a hard bend to read as
	-- a stroke rather than as a polygon.
	segmentPx = 9,
	minSegments = 6,
	maxSegments = 26,
	-- How far consecutive bars overlap. `Graph.barStyle` raises this to the drawn thickness
	-- whenever that is larger, because the notch a bar leaves when it turns grows with how fat
	-- it is, and a fixed number stops being enough the moment the thickness changes.
	overlapPx = 3,
	portSize = 9,
	-- How close, in SCREEN pixels, the pointer has to be to a connector to hover or pick it.
	-- Wider than the drawn wire (PtaQ, 2026-09-26: easier not to miss).
	hitPx = 14,
	-- How close to a connector's MIDDLE the pointer has to be for the sever button to show,
	-- and for a click there to cut the wire.
	severPx = 16,
}

--- How tall one node is drawn, in canvas units.
---
--- `S.nodeH` is filled by the renderer, which is the only thing that knows how many summary
--- rows a node ended up with. Anything asking between renders gets the collapsed height, which
--- is right for every node that is not open.
function M.HeightOf(heights, key)
	return (heights or {})[key] or GRAPH.nodeHeight
end

--- How tall a node with this many parameter rows is drawn.
---@param rowCount number parameter rows the node shows when open
---@param portCount number its output ports
---@param expanded boolean is it open
---@param rowPx number|nil the height of one expanded row: `editRowPx` for editor rows,
--- `paramRowPx` (the default) for read-only ones
function M.MeasureNode(rowCount, portCount, expanded, rowPx)
	-- One row is ALWAYS reserved when the node is shut, even if it has nothing to put in it.
	-- Two different collapsed heights on one canvas, depending on whether somebody had filled
	-- a form in, reads as a bug rather than as information.
	local body = GRAPH.paramRowPx
	if expanded then
		body = math.max(1, rowCount or 0) * (rowPx or GRAPH.paramRowPx)
	end
	local height = GRAPH.titleBarPx + GRAPH.bodyGapPx + GRAPH.subRowPx + body + GRAPH.bottomPx
	-- At least as tall as its own ports need. An objective carries six and they do not fit a
	-- 98px edge: the dots would overlap and there would be nothing to aim at. A node with one
	-- port is untouched by this, which is every trigger, action and stage. The ports sit
	-- below the title bar (`PortOffset`), so that is part of what they need.
	if (portCount or 0) > 1 then
		height = math.max(height, GRAPH.titleBarPx + portCount * GRAPH.portPitchPx + GRAPH.bottomPx)
	end
	return height
end

--- How big a port is drawn on a node with `count` of them.
---
--- One port keeps every number the single-port nodes were built with. Several share the edge,
--- so the grab strip shrinks to the pitch: at 44px each they would lie on top of one another
--- and the top port would take every press meant for the second.
function M.PortMetrics(count)
	if (count or 1) <= 1 then
		return { pitch = nil, hit = GRAPH.portHitPx, halo = GRAPH.portHaloPx }
	end
	return {
		pitch = GRAPH.portPitchPx,
		hit = GRAPH.portPitchPx,
		halo = math.min(GRAPH.portHaloPx, GRAPH.portPitchPx),
	}
end

--- Where port `index` of `count` sits down a node's edge, in canvas units from its top.
---
--- With ONE port this is exactly the middle, which is where every port was before and what
--- `Graph.outAnchor` has always assumed, so no trigger, action or stage connector moves by a
--- pixel.
function M.PortOffset(index, count, height)
	height = height or GRAPH.nodeHeight
	if (count or 1) <= 1 then
		return height / 2
	end
	-- Below the title bar and above the stub: the bar is the node's name, not a port lane.
	local usable = math.max(1, height - GRAPH.titleBarPx - GRAPH.bottomPx)
	return GRAPH.titleBarPx + usable * ((index - 0.5) / count)
end

--- The canvas-unit offset of a named port down a node's edge.
---
--- The renderer, the connectors and the live drag all have to agree about this or a wire
--- leaves a node somewhere other than the dot it is supposed to come out of, which is the
--- mistake the port dots were moved onto the edge to fix in the first place.
---@param name string|nil the field the port writes, nil for the node's only port
---@param height number the node's height
---@param ports table its output ports (M.OutPorts)
function M.PortY(height, ports, side, name)
	if side ~= "out" or #(ports or {}) <= 1 then
		return height / 2
	end
	for index, port in ipairs(ports) do
		if port.name == name then
			return M.PortOffset(index, #ports, height)
		end
	end
	return height / 2
end

--- How wide a named port's label box is drawn, in canvas units.
function M.PortLabelWidth(label)
	return math.ceil(#tostring(label or "") * GRAPH.portLabelPx * GRAPH.portLabelAdvance) + GRAPH.portLabelPadPx * 2
end

--- The width EVERY label box on a node is drawn at: the widest of them. One width, so the
--- names start on one left edge and the wires leave from one vertical line (PtaQ, 2026-09-26).
---@param ports table the node's output ports (M.OutPorts)
function M.PortLabelBoxWidth(ports)
	local widest = 0
	for _, port in ipairs(ports or {}) do
		if port.label then
			widest = math.max(widest, M.PortLabelWidth(port.label))
		end
	end
	return widest
end

--- How far right of the node's edge the label box starts: past the dot, with a small gap.
function M.PortLabelLead()
	return GRAPH.portPx / 2 + 3
end

--- How far right of the node's edge a WIRED named port's connector starts: the far end of its
--- label. 0 for a port with no label (every trigger, action and stage port).
---@param ports table the node's output ports (M.OutPorts)
function M.PortLabelEnd(ports, name)
	if #(ports or {}) <= 1 then
		return 0
	end
	for _, port in ipairs(ports) do
		if port.name == name and port.label then
			return M.PortLabelLead() + M.PortLabelBoxWidth(ports)
		end
	end
	return 0
end

--- Where a connector leaves a node, and where it arrives at one.
---
--- The height is passed in rather than read from `GRAPH`, because nodes are not all the same
--- height any more: an expanded one is as tall as it has parameters. A caller that does not
--- know gets the collapsed height, which is what every node used to be.
---@param offsetY number|nil how far down the node's edge the wire leaves, for a named port
---@param offsetX number|nil how far past the node's edge it leaves (a named port's label)
function M.OutAnchor(position, height, offsetY, offsetX)
	return position.x + GRAPH.nodeWidth + (offsetX or 0), position.y + (offsetY or (height or GRAPH.nodeHeight) / 2)
end

function M.InAnchor(position, height)
	return position.x, position.y + (height or GRAPH.nodeHeight) / 2
end

function M.CurveBetween(x0, y0, x3, y3, segments)
	local dx, dy = x3 - x0, y3 - y0
	local chord = math.sqrt(dx * dx + dy * dy)
	if chord <= 1 then
		return nil
	end

	local tangent = math.max(M.EDGE.minTangent, math.min(M.EDGE.maxTangent, math.abs(dx) * M.EDGE.tangentRatio))
	if dx < 0 then
		tangent = tangent + math.min(M.EDGE.maxTangent, -dx * 0.35)
	end
	local x1, y1 = x0 + tangent, y0
	local x2, y2 = x3 - tangent, y3

	-- How far the curve strays from the straight line between its ends: the vertical gap,
	-- plus a share of the bow a backward connector takes to get around itself.
	local sag = math.abs(dy) + tangent * 0.15
	local count = segments
		or math.max(M.EDGE.minSegments, math.min(M.EDGE.maxSegments, 2 + math.floor(sag / M.EDGE.segmentPx + 0.5)))
	local points = { n = count }
	for index = 0, count do
		-- Not an even walk along the curve: smoothstep on the parameter clusters the points
		-- at the two ENDS, where a bezier with horizontal tangents does all of its bending,
		-- and spreads them thin through the straight middle. That is what keeps the
		-- horizontal departure and arrival visible when a connector is drawn with few bars,
		-- and an even walk loses it -- the first bar is then long enough to cut the corner.
		local even = index / count
		local t = even * even * (3 - 2 * even)
		local u = 1 - t
		local uu, tt = u * u, t * t
		points[index + 1] = {
			x = uu * u * x0 + 3 * uu * t * x1 + 3 * u * tt * x2 + tt * t * x3,
			y = uu * u * y0 + 3 * uu * t * y1 + 3 * u * tt * y2 + tt * t * y3,
		}
	end
	return points
end

--- Distance from a point to a line segment, both in canvas units.
function M.PointToSegment(px, py, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	local lengthSquared = dx * dx + dy * dy
	local t = 0
	if lengthSquared > 0 then
		t = ((px - ax) * dx + (py - ay) * dy) / lengthSquared
		t = math.max(0, math.min(1, t))
	end
	local cx, cy = ax + t * dx, ay + t * dy
	return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
end

--- The node under a point in CANVAS coordinates, or nil.
---
--- Against the layout rather than against the elements: the layout is what the drop acts on,
--- and asking RmlUi what is under the pointer would answer with whatever the live connector
--- happens to be covering.
---
--- `pad` widens every box by that many canvas pixels, and then the NEAREST box wins, because
--- two padded boxes can overlap where two real ones never do. A connector's drop uses it: the
--- port dot sits half OUTSIDE its node's box, so letting go exactly on the dot missed the node
--- and opened the create palette instead of connecting.
---@param layout table key -> { x, y } in canvas space
---@param heights table|nil key -> measured height
---@param pad number|nil canvas pixels of tolerance around each box
function M.NodeAt(layout, heights, cx, cy, pad)
	if not (cx and cy and layout) then
		return nil
	end
	pad = pad or 0
	local best, bestDistance
	for key, position in pairs(layout) do
		local x0, y0 = position.x, position.y
		local x1, y1 = x0 + GRAPH.nodeWidth, y0 + M.HeightOf(heights, key)
		local dx = math.max(x0 - cx, 0, cx - x1)
		local dy = math.max(y0 - cy, 0, cy - y1)
		if dx <= pad and dy <= pad then
			local distance = dx * dx + dy * dy
			if distance == 0 then
				return key
			end
			if not bestDistance or distance < bestDistance then
				best, bestDistance = key, distance
			end
		end
	end
	return best
end

--- The connector nearest a canvas point, within a grab radius, or nil.
---
--- Nearest rather than first: connectors cross, and on a crossing the one whose curve is
--- actually under the pointer is the one meant. The radius is given in SCREEN pixels and
--- divided by the zoom, so a wire is equally easy to hit at every zoom level.
---@return table|nil edge, number|nil index
---@param edges table the edge list the renderer drew
---@param points table index -> the polyline it drew for that edge, `{ n = segments, ... }`
---@param zoom number the view's zoom, so the radius is in SCREEN pixels
---@return table|nil edge, number|nil index
function M.EdgeAt(edges, points, zoom, cx, cy, screenRadius)
	if not (cx and points) then
		return nil
	end
	local radius = (screenRadius or M.EDGE.hitPx) / math.max(0.0001, zoom or 1)
	local best, bestIndex, bestDistance = nil, nil, radius
	for index, line in pairs(points) do
		local edge = (edges or {})[index]
		if edge and line.n then
			for segment = 1, line.n do
				local a, b = line[segment], line[segment + 1]
				if a and b then
					local distance = M.PointToSegment(cx, cy, a.x, a.y, b.x, b.y)
					if distance < bestDistance then
						best, bestIndex, bestDistance = edge, index, distance
					end
				end
			end
		end
	end
	return best, bestIndex
end

--- The bounding box of a set of node keys, in canvas units, or nil if none of them exist.
function M.BoundsOf(layout, heights, keys)
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local found = false
	for _, key in ipairs(keys or {}) do
		local position = layout and layout[key]
		if position then
			found = true
			minX = math.min(minX, position.x)
			minY = math.min(minY, position.y)
			maxX = math.max(maxX, position.x + GRAPH.nodeWidth)
			maxY = math.max(maxY, position.y + M.HeightOf(heights, key))
		end
	end
	if not found then
		return nil
	end
	return minX, minY, maxX, maxY
end

--- Which nodes sit inside a frame right now. Fully contained, not merely touching: a node
--- half in a frame is not part of that group and moving the frame should leave it alone.
function M.CommentMembers(layout, heights, frame)
	local members = {}
	for key, position in pairs(layout or {}) do
		if
			position.x >= frame.x
			and position.y >= frame.y
			and position.x + GRAPH.nodeWidth <= frame.x + frame.w
			and position.y + M.HeightOf(heights, key) <= frame.y + frame.h
		then
			members[#members + 1] = { key = key, dx = position.x - frame.x, dy = position.y - frame.y }
		end
	end
	return members
end

--- Lay nodes out in BANDS of columns, left to right, one band per kind in the order given.
--- Each band wraps into further columns once `rowsPerColumn` is full, and its rows are as far
--- apart as its TALLEST node needs. The adapter decides the bands (which kinds, in what
--- order, which reserve a column even when empty).
---@param bands table array of { kind = string, records = table, reserve = boolean|nil }
---@param measure fun(kind: string, entry: table): number|nil a node's height, measured fresh
---@return table key -> { x, y }
function M.LayoutBands(bands, measure)
	local layout = {}
	local rowsPerColumn = math.max(6, GRAPH.rowsPerColumn)

	-- Measured by the caller rather than read from a height cache the renderer fills: this
	-- runs BEFORE that cache exists.
	local function gapFor(list, kind)
		local tallest = GRAPH.nodeHeight
		for _, entry in ipairs(list) do
			tallest = math.max(tallest, measure and measure(kind, entry) or GRAPH.nodeHeight)
		end
		return GRAPH.rowGap + math.max(0, tallest - GRAPH.nodeHeight)
	end

	local bandX = GRAPH.padding
	for _, band in ipairs(bands or {}) do
		local list = band.records or {}
		local rowGap = gapFor(list, band.kind)
		local columns = 0
		for index, entry in ipairs(list) do
			local row = (index - 1) % rowsPerColumn
			local column = math.floor((index - 1) / rowsPerColumn)
			columns = math.max(columns, column + 1)
			layout[M.Key(band.kind, entry.id)] = {
				x = bandX + column * GRAPH.columnGap,
				y = GRAPH.padding + row * rowGap,
			}
		end
		-- An empty band takes no room unless it RESERVES a column, so the bands after it
		-- still read left to right from where they should start.
		bandX = bandX + (band.reserve and math.max(columns, 1) or columns) * GRAPH.columnGap
	end
	return layout
end

--- Moves the layout, and the grouping frames with it, so the top-left node sits at the
--- canvas padding. Returns the shift, or nil when nothing moved; the caller pans its view
--- the other way so nothing jumps on screen.
---@return number|nil dx, number|nil dy
function M.NormaliseLayout(layout, comments)
	if not layout or not next(layout) then
		return nil
	end
	local minX, minY = math.huge, math.huge
	for _, position in pairs(layout) do
		minX = math.min(minX, position.x)
		minY = math.min(minY, position.y)
	end
	local dx = GRAPH.padding - minX
	local dy = GRAPH.padding - minY
	if dx == 0 and dy == 0 then
		return nil
	end
	for _, position in pairs(layout) do
		position.x = position.x + dx
		position.y = position.y + dy
	end
	-- The frames move with the nodes. They are positions in the same space, and leaving them
	-- behind would slide every comment off the group it names the first time somebody dragged
	-- a node past the left edge.
	if type(comments) == "table" then
		for _, frame in ipairs(comments) do
			frame.x = (tonumber(frame.x) or 0) + dx
			frame.y = (tonumber(frame.y) or 0) + dy
		end
	end
	return dx, dy
end

return M
