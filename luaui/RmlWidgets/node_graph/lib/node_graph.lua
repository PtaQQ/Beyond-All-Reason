-- NODE GRAPH: a node editor any widget can host. This file is the library's public entry.
--
-- Nodes in coloured kinds, wires between named ports, a create palette, multi-select, groupings,
-- FIND, a minimap, an animated zoom and keyboard shortcuts. The HOST (your widget) supplies an
-- ADAPTER, which says what the nodes and wires mean (adapters/toy_ceg.lua is the worked
-- example), and forwards four call-ins:
--
--     local NodeGraph = VFS.Include("luaui/RmlWidgets/node_graph/lib/node_graph.lua")
--     local graph
--     function widget:Initialize()
--         graph = NodeGraph.create({
--             widget = widget,
--             context = RmlUi.CreateContext("my_graph"),   -- see "one graph per context" below
--             adapter = function(Core) return VFS.Include(".../my_adapter.lua")({ Core = Core, doc = myDoc }) end,
--             edited = function() --[[ the graph changed the document: dirty, undo ]] end,
--         })
--         graph.setOpen(true)
--     end
--     function widget:Update() graph.update() end
--     function widget:MouseWheel(up, value) return graph.mouseWheel(up) end
--     function widget:KeyPress(key, mods, isRepeat) return graph.keyPress(key, isRepeat) end
--     function widget:Shutdown() graph.shutdown() end
--
-- THE PUBLIC SURFACE is `NodeGraph.create`, the object it returns, and the adapter contract
-- (core.lua, `ADAPTER_CONTRACT`, documented field by field above it). Everything under ctl/ is
-- private and may change in any release. Guide: doc/NodeGraph.md; changes:
-- doc/NodeGraph-changelog.md.
--
-- ONE GRAPH PER RmlUi CONTEXT: node_graph.rml binds the fixed model `node_graph_model` (Recoil
-- can only load a document from a file, so the name cannot vary). Give each graph a context.
--
-- Options:
--   widget, context, adapter      required; `adapter(Core)` returns the adapter table
--   edited()                      optional: the graph changed the document (default: nothing)
--   analyse()                     optional: wires changed, recompute your marks
--   undo(), redo()                optional: Ctrl+Z / Ctrl+Y on the canvas (default: says so)
--   closed()                      optional: the window's close button was pressed
--   forms                         optional: the node editors' form callbacks (doc/NodeGraph.md, 7)
--   notice(text)                  optional: show the adapter's whole-graph warning (nil clears)
--   label                         optional: the prefix for its echo lines (default "[graph]")
--   movable, resizable            optional: default true; the title bar drags, the edge grips size
--   minWidth, minHeight           optional: the smallest the window resizes to (620, 260)

local DIR = "luaui/RmlWidgets/node_graph/"

local NodeGraph = {}

--- The library's version (semver). Bumped by every change to node_graph/, with a line in
--- doc/NodeGraph-changelog.md.
NodeGraph.VERSION = "1.1.0"
--- The adapter contract's version. Only a removed or changed adapter field bumps it; a new
--- field is optional with a default, so an older adapter keeps working.
NodeGraph.CONTRACT = 1

--- The graph's own view state. The controllers read and write it as `S`.
function NodeGraph.graphState()
	return {
		graph = { showCycles = true, minimap = false },
		layout = nil,
		expanded = {},
		nodeH = {},
		graphSel = {},
		graphSelEdge = nil,
		graphSelComment = nil,
		graphView = { zoom = 1, panX = 0, panY = 0, contentW = 0, contentH = 0, graphW = 0, graphH = 0 },
		graphEdgesByNode = {},
		graphDebug = false,
		helpOpen = false,
		helpBuilt = false,
		findKinds = {},
		graphFind = "",
		searchAt = 0,
		lastKeyTick = -1,
		-- The host's own, which the graph reads through `Graph.host`.
		tick = 0,
		elementCache = {},
		inputCommits = {},
		focusedInput = nil,
		focusedInputId = nil,
		focusAfterRender = nil,
		renderPending = false,
		open = false,
	}
end

---@param opts table see the header
---@return table|nil host { Graph, S, document, VERSION, setOpen, place, update, mouseWheel, keyPress, shutdown }, or nil when it could not start (the reason is echoed)
function NodeGraph.create(opts)
	assert(opts and opts.widget and opts.context and opts.adapter, "node_graph: needs widget, context and adapter")
	local S = NodeGraph.graphState()
	local Graph = {}
	Graph.lib = VFS.Include(DIR .. "lib/core.lua")
	local GRAPH = Graph.lib.GRAPH
	local prefix = opts.label or "[graph]"
	local document

	local function echo(...)
		Spring.Echo(prefix, ...)
	end

	local function el(id)
		if not document or id == nil then
			return nil
		end
		local cached = S.elementCache[id]
		if cached then
			return cached
		end
		local found = document:GetElementById(id)
		if found then
			S.elementCache[id] = found
		end
		return found
	end

	local function escapeRml(text)
		return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
	end

	local function onClick(id, handler)
		local element = el(id)
		if not element then
			return false
		end
		element:AddEventListener("click", function(event)
			local ok, err = pcall(handler, event)
			if not ok then
				echo("handler error on " .. id .. ": " .. tostring(err))
			end
			if event and event.StopPropagation then
				event:StopPropagation()
			end
		end, false)
		return true
	end

	local function deepCopy(value)
		if type(value) ~= "table" then
			return value
		end
		local copy = {}
		for key, inner in pairs(value) do
			copy[key] = deepCopy(inner)
		end
		return copy
	end

	--- Ask for a render on the next update. `opts.graph == "selection"`: only the node selection
	--- changed (a host's own list or timeline picked a node), so the canvas is relit in place
	--- (Graph.relightSelection) instead of rebuilt, when nothing else changed since it was drawn.
	local function render(opts)
		if opts and opts.graph == "selection" then
			S.selPending = true
		else
			S.renderPending = true
		end
	end

	-- Enter commits a field and lets go of it. `RmlUi.key_identifier` is a FUNCTION in this
	-- build (call it for the enum); older builds expose a table.
	local returnKeyId
	local function isReturnEvent(event)
		if returnKeyId == nil then
			local ok = pcall(function()
				returnKeyId = RmlUi.key_identifier().RETURN
			end)
			if not ok or returnKeyId == nil then
				pcall(function()
					returnKeyId = RmlUi.key_identifier.RETURN
				end)
			end
			returnKeyId = returnKeyId or false
		end
		local parameters = event and event.parameters
		return (parameters and returnKeyId and parameters.key_identifier == returnKeyId) == true
	end

	--- Every text field: SDL text input while it has the caret (or no keystroke reaches RmlUi),
	--- the graph's keys stand down while it does, and Enter commits through `S.inputCommits`.
	local function wireTextInput(element)
		if not element then
			return
		end
		element:AddEventListener("keydown", function(event)
			if not isReturnEvent(event) then
				return
			end
			local entry = element.id and S.inputCommits[element.id]
			if entry then
				entry.commit()
			end
			element:Blur()
		end, false)
		element:AddEventListener("focus", function()
			Spring.SDLStartTextInput()
			S.focusedInput = element
			S.focusedInputId = element.id
		end, false)
		element:AddEventListener("blur", function()
			Spring.SDLStopTextInput()
			S.focusedInput = nil
			S.focusedInputId = nil
		end, false)
	end

	-- What the controllers ask of their host.
	Graph.host = {
		echo = echo,
		render = render,
		edited = function()
			if opts.edited then
				opts.edited()
			end
		end,
		analyse = function()
			if opts.analyse then
				opts.analyse()
			end
		end,
		undo = function()
			if opts.undo then
				opts.undo()
			else
				echo("this graph has no undo")
			end
			return true
		end,
		redo = function()
			if opts.redo then
				opts.redo()
			else
				echo("this graph has no redo")
			end
			return true
		end,
		showing = function()
			return S.open and document ~= nil
		end,
		hasDocument = function()
			return true
		end,
		typing = function()
			return S.focusedInputId
		end,
		frame = function()
			return S.tick
		end,
		formFocus = function()
			return nil
		end,
		notice = function(text)
			if opts.notice then
				opts.notice(text)
			end
		end,
	}

	-- The controllers: the model and the node helpers first,
	-- because the others call into them.
	local Bind = {}
	VFS.Include("luaui/RmlWidgets/node_graph/lib/ctl/model.lua")({ Graph = Graph, S = S, echo = echo, el = el })
	VFS.Include("luaui/RmlWidgets/node_graph/lib/ctl/nodes.lua")({
		Graph = Graph,
		Bind = Bind,
		GRAPH = GRAPH,
		S = S,
		echo = echo,
		el = el,
		nodeKey = Graph.lib.Key,
		render = render,
	})
	Graph.adapter = opts.adapter(Graph.lib)
	local missing = Graph.lib.MissingFields(Graph.adapter)
	if #missing > 0 then
		echo("the adapter lacks: " .. table.concat(missing, ", ") .. " (core.lua, ADAPTER_CONTRACT)")
		return nil
	end
	if Graph.adapter.contract ~= NodeGraph.CONTRACT then
		echo(
			string.format(
				"the adapter was written for contract %s, this is %d: read doc/NodeGraph-changelog.md",
				tostring(Graph.adapter.contract),
				NodeGraph.CONTRACT
			)
		)
	end
	VFS.Include("luaui/RmlWidgets/node_graph/lib/ctl/edit.lua")({
		Graph = Graph,
		Bind = Bind,
		GRAPH = GRAPH,
		S = S,
		deepCopy = deepCopy,
		echo = echo,
		el = el,
		nodeKey = Graph.lib.Key,
		render = render,
	})
	VFS.Include("luaui/RmlWidgets/node_graph/lib/ctl/link.lua")({
		Graph = Graph,
		GRAPH = GRAPH,
		S = S,
		echo = echo,
		el = el,
		escapeRml = escapeRml,
		nodeKey = Graph.lib.Key,
		onClick = onClick,
		setText = Graph.setText,
		render = render,
	})
	VFS.Include("luaui/RmlWidgets/node_graph/lib/ctl/view.lua")({
		Graph = Graph,
		Bind = Bind,
		GRAPH = GRAPH,
		S = S,
		echo = echo,
		el = el,
		setChipText = Graph.setChipText,
		render = render,
	})
	VFS.Include("luaui/RmlWidgets/node_graph/lib/ctl/canvas.lua")({
		Graph = Graph,
		Bind = Bind,
		GRAPH = GRAPH,
		S = S,
		echo = echo,
		el = el,
		escapeRml = escapeRml,
		nodeKey = Graph.lib.Key,
		onClick = onClick,
		setText = Graph.setText,
		render = render,
	})
	VFS.Include("luaui/RmlWidgets/node_graph/lib/ctl/wire.lua")({
		Graph = Graph,
		Bind = Bind,
		S = S,
		echo = echo,
		el = el,
		wireTextInput = wireTextInput,
		render = render,
	})

	local context = opts.context
	local opened, model = pcall(function()
		return context:OpenDataModel(Graph.MODEL_NAME, Graph.modelFields(opts.forms or {}), opts.widget)
	end)
	Graph.model = opened and model or nil
	if not Graph.model then
		echo("could not open " .. Graph.MODEL_NAME .. ": another graph is open in this context")
		return nil
	end
	document = context:LoadDocument(Graph.RML_PATH, opts.widget)
	if not document then
		context:RemoveDataModel(Graph.MODEL_NAME)
		echo("failed to load " .. Graph.RML_PATH)
		return nil
	end
	document:ReloadStyleSheet()
	document:Show()
	S.graphWindow = document:GetElementById("ng-graph-window")
	Graph.attach()
	Graph.attachDocument(document)
	local Window = VFS.Include(DIR .. "lib/ctl/window.lua")({
		document = document,
		root = S.graphWindow,
		viewport = document:GetElementById("ng-graph-viewport"),
		movable = opts.movable,
		resizable = opts.resizable,
		minWidth = opts.minWidth,
		minHeight = opts.minHeight,
		-- Styles only while a grip is held; the canvas is re-measured and rebuilt on the drop.
		onResize = function()
			Graph.clampPan()
			Graph.applyGraphView()
		end,
		onDone = function()
			Graph.sizeCanvas()
			render()
		end,
	})

	local host = { Graph = Graph, S = S, document = document, VERSION = NodeGraph.VERSION }

	--- Show or hide the graph window.
	function host.setOpen(open)
		S.open = open and true or false
		S.elementCache = {}
		Graph.syncFlags()
		render()
	end
	--- Put the window at a screen position, in pixels. The canvas is re-measured on the next
	--- render, because its size follows the viewport.
	function host.place(left, top)
		if S.graphWindow then
			S.graphWindow.style.left = math.floor(left) .. "px"
			S.graphWindow.style.top = math.floor(top) .. "px"
		end
		render()
	end

	Graph.onClick("ng-btn-graph-close", function()
		host.setOpen(false)
		if opts.closed then
			opts.closed()
		end
	end)

	--- widget:Update: the polled gestures, then the deferred render and a pending caret.
	function host.update()
		S.tick = S.tick + 1
		Window.tick()
		Graph.update()
		if not (S.renderPending or S.selPending) then
			return
		end
		local full = S.renderPending
		S.renderPending = false
		S.selPending = false
		S.elementCache = {}
		-- A relight is only a relight while nothing else the selection clears has changed since
		-- the canvas was drawn: a picked wire or a selected grouping going away needs the rebuild.
		if
			not full
			and S.open
			and S.drawnSel
			and S.graphSelEdge == S.drawnSelEdge
			and S.graphSelComment == S.drawnSelComment
		then
			Graph.relightSelection(S.drawnSel)
		else
			Graph.draw(S.open)
		end
		S.drawnSel = Graph.selectionSet()
		S.drawnSelEdge = S.graphSelEdge
		S.drawnSelComment = S.graphSelComment
		if S.focusAfterRender then
			local wanted = S.focusAfterRender
			S.focusAfterRender = nil
			local element = el(wanted)
			if element then
				pcall(function()
					element:Focus()
				end)
				Graph.onFocused(wanted, element)
			end
		end
	end

	--- widget:MouseWheel. true when the graph claims the wheel.
	function host.mouseWheel(up)
		local mx, my = Spring.GetMouseState()
		local _, vsy, viewPosX = Spring.GetViewGeometry()
		return Graph.mouseWheel(up, mx + (viewPosX or 0), vsy - my)
	end

	--- widget:KeyPress. The graph's keys first; then Enter / Escape for its text fields.
	function host.keyPress(key, isRepeat)
		if Graph.keyPress(key) then
			return true
		end
		local entry = S.focusedInputId and S.inputCommits[S.focusedInputId]
		if not entry then
			return false
		end
		if (key == 13 or key == 1073741912) and not isRepeat then
			entry.commit()
			entry.element:Blur()
			return true
		end
		if key == 27 then
			entry.revert()
			entry.element:Blur()
			return true
		end
		return false
	end

	--- Ask for a render: `host.render()` rebuilds on the next update, `host.render({ graph =
	--- "selection" })` only relights the selection (after the host changed it from outside).
	host.render = render

	--- widget:DrawScreen: the wires are drawn on the GPU (ctl/wires.lua), in a draw call-in.
	function host.draw()
		if Graph.wires then
			Graph.wires.draw()
		end
	end

	--- widget:Shutdown.
	function host.shutdown()
		if Graph.wires then
			Graph.wires.shutdown()
		end
		if document then
			document:Close()
			document = nil
		end
		context:RemoveDataModel(Graph.MODEL_NAME)
		Graph.model = nil
	end

	render()
	return host
end

return NodeGraph
