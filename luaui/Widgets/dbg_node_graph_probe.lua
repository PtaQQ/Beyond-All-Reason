-- The node graph library's live check: enables the Node Graph Demo, checks what it drew, cuts a
-- wire through a real hit test, takes a screenshot, and prints a verdict. Run it after changing
-- anything under luaui/RmlWidgets/node_graph/ (doc/NodeGraph.md, section 11): enable it by hand
-- (F11) and read the "[node graph probe]" lines. With the modoption `node_graph_probe=1` it
-- quits the game when it is done, for scripted runs.

function widget:GetInfo()
	return {
		name = "Node Graph Probe",
		desc = "Live check of the node graph library on its demo widget",
		author = "PtaQ",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = false,
		-- It enables and disables the demo widget.
		handler = true,
	}
end

local passed, failed = 0, 0
local probeSparks -- the sparks node element, kept across a selection-only render
local fromModoption = false

local function check(ok, what)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
	end
	Spring.Echo(string.format("[node graph probe] %s %s", ok and "ok  " or "FAIL", what))
end

local function demo()
	return WG.NodeGraphDemo
end

local steps = {
	{
		wait = 30,
		run = function()
			widgetHandler:EnableWidget("Node Graph Demo")
		end,
	},
	{
		wait = 30,
		run = function()
			local d = demo()
			check(d ~= nil, "the demo widget built a graph")
			if not d then
				return
			end
			local host = d.host
			check(host.VERSION ~= nil, "the host reports the library version " .. tostring(host.VERSION))
			check(host.document:GetElementById("ng-gnode-emitter-muzzle") ~= nil, "its document draws the toy's nodes")
			check(#(host.S.graphEdgeList or {}) == 7, "with the toy's seven wires: " .. #(host.S.graphEdgeList or {}))
			local window = host.document:GetElementById("ng-graph-window")
			check(window ~= nil and not window:IsClassSet("hidden"), "its window is showing, through its own model")
			local chips = {}
			for _, kind in ipairs({ "emitter", "spawner", "particle" }) do
				local chip = host.document:GetElementById("ng-find-" .. kind)
				chips[#chips + 1] = chip and tostring(chip.inner_rml) or "-"
			end
			check(
				table.concat(chips, ",") == "EMI,SPA,PAR",
				"its FIND chips are the toy's: " .. table.concat(chips, ",")
			)
			local marks = host.document:GetElementById("ng-chip-graph-showcycles")
			check(marks ~= nil and marks:IsClassSet("hidden"), "an adapter with no markToggle shows no mark chip")
			local status = host.document:GetElementById("ng-graph-status")
			local text = status and tostring(status.inner_rml) or ""
			check(
				text:find("nodes") ~= nil and text:find("cycle") == nil,
				"the status line counts without loops: " .. text
			)
			for _, id in ipairs({
				"ng-graph-handle",
				"ng-graph-grip-e",
				"ng-graph-grip-s",
				"ng-graph-grip-se",
				"ng-graph-grip-w",
				"ng-graph-grip-n",
				"ng-graph-grip-nw",
				"ng-graph-grip-ne",
				"ng-graph-grip-sw",
			}) do
				check(host.document:GetElementById(id) ~= nil, "the window has its " .. id)
			end
			-- Select one node, so the screenshot shows a kind's look under the selected state
			-- (kinds.rcss is linked between the base and node_graph_after.rcss).
			-- setSelection leaves the render to its caller, like every Graph.* edit.
			host.Graph.setSelection({ "spawner:sparks" })
			host.Graph.host.render()
		end,
	},
	{
		wait = 10,
		run = function()
			local d = demo()
			if not d then
				return
			end
			local node = d.host.document:GetElementById("ng-gnode-spawner-sparks")
			check(node ~= nil and node:IsClassSet("ng-node-selected"), "a selected node carries ng-node-selected")
			-- The wires are one GPU texture (lib/ctl/wires.lua), not bar elements.
			local Graph = d.host.Graph
			check(d.host.document:GetElementById("ng-graph-wires") ~= nil, "the wires have their texture element")
			check(
				Graph.wires ~= nil and Graph.wires.count() == 7,
				"the wire layer holds the seven wires: " .. tostring(Graph.wires and Graph.wires.count())
			)
			check(d.host.document:GetElementById("ng-edge-1-1") == nil, "and no wire is drawn as bar elements any more")
			-- A selection changed from outside relights the canvas instead of rebuilding it.
			probeSparks = node
			Graph.setSelection({ "particle:flare" })
			d.host.render({ graph = "selection" })
			Spring.SendCommands("screenshot png")
			Spring.Echo("[node graph probe] screenshot: the demo graph, spawner:sparks selected")
		end,
	},
	{
		wait = 5,
		run = function()
			local d = demo()
			if not d then
				return
			end
			local flare = d.host.document:GetElementById("ng-gnode-particle-flare")
			local sparks = d.host.document:GetElementById("ng-gnode-spawner-sparks")
			check(flare ~= nil and flare:IsClassSet("ng-node-selected"), "a selection-only render lights the new node")
			check(sparks ~= nil and not sparks:IsClassSet("ng-node-selected"), "  and unlights the old one")
			check(
				probeSparks ~= nil and sparks ~= nil and probeSparks.id == sparks.id and probeSparks.parent_node ~= nil,
				"  without rebuilding the canvas (the old node element is still in the document)"
			)
		end,
	},
	{
		wait = 10,
		run = function()
			local d = demo()
			if not d then
				return
			end
			-- A real hit test on the flash -> flare wire.
			local host = d.host
			local S, Graph = host.S, host.Graph
			local hit = false
			for index, edge in ipairs(S.graphEdgeList or {}) do
				if edge.from == "spawner:flash" and edge.to == "particle:flare" then
					local viewport = host.document:GetElementById("ng-graph-viewport")
					local cx, cy = Graph.edgeMiddle(index)
					if viewport and cx then
						hit = true
						Graph.clickCanvasAt(
							viewport.absolute_left + S.graphView.panX + cx * S.graphView.zoom,
							viewport.absolute_top + S.graphView.panY + cy * S.graphView.zoom
						)
					end
				end
			end
			check(hit, "found the flash -> flare wire to click")
		end,
	},
	{
		wait = 10,
		run = function()
			local d = demo()
			if d then
				check(
					#d.doc.spawners[1].particles == 0,
					"clicking the middle of its wire cut it in the demo's document"
				)
			end
			widgetHandler:DisableWidget("Node Graph Demo")
		end,
	},
	{
		wait = 10,
		run = function()
			check(WG.NodeGraphDemo == nil, "disabling the demo takes its graph down")
			Spring.Echo(string.format("[node graph probe] verdict: %d passed, %d failed", passed, failed))
			if fromModoption then
				Spring.SendCommands("quitforce")
			end
		end,
	},
}

local step, countdown = 1, nil

function widget:Initialize()
	fromModoption = (Spring.GetModOptions() or {}).node_graph_probe == "1"
end

function widget:Update()
	local current = steps[step]
	if not current then
		return
	end
	countdown = countdown or current.wait
	countdown = countdown - 1
	if countdown > 0 then
		return
	end
	countdown = nil
	step = step + 1
	local ok, err = pcall(current.run)
	if not ok then
		check(false, "step " .. (step - 1) .. " raised: " .. tostring(err))
	end
end
