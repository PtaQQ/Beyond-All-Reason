-- The node graph hosted by a widget that is not the mission editor: the toy CEG graph
-- (emitter -> spawner -> particle) in its own window, through node_graph.lua. The worked
-- example for anyone building on the graph (a CEG composer); off by default.

function widget:GetInfo()
	return {
		name = "Node Graph Demo",
		desc = "The node graph library on its example adapter (a toy CEG graph)",
		author = "PtaQ",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = false,
	}
end

local DIR = "luaui/RmlWidgets/node_graph/"
local NodeGraph = VFS.Include(DIR .. "lib/node_graph.lua")

-- The document the toy adapter edits. A real host would load and save its own.
local doc = {
	emitters = {
		{ id = "muzzle", rate = 30, spawners = { "flash", "sparks" } },
		{ id = "impact", rate = 1, spawners = { "debris" } },
	},
	spawners = {
		{ id = "flash", count = 1, particles = { "flare" } },
		{ id = "sparks", count = 16, particles = { "spark" } },
		{ id = "debris", count = 8, particles = { "chunk", "spark" } },
	},
	particles = {
		{ id = "flare", texture = "flare1" },
		{ id = "spark", texture = "spark2" },
		{ id = "chunk", texture = "rock" },
		{ id = "puff", texture = "smoke3" },
	},
}

local host

function widget:Initialize()
	-- A context of its own: every graph binds the same fixed model name, so a context holds one
	-- graph at a time (doc/NodeGraph.md, section 6).
	local context = RmlUi.GetContext("node_graph_demo") or RmlUi.CreateContext("node_graph_demo")
	if not context then
		Spring.Echo("[node graph demo] no RmlUi context")
		widgetHandler:RemoveWidget(self)
		return
	end
	host = NodeGraph.create({
		widget = self,
		context = context,
		label = "[node graph demo]",
		adapter = function(Core)
			return VFS.Include(DIR .. "adapters/toy_ceg.lua")({ Core = Core, doc = doc })
		end,
		edited = function()
			Spring.Echo("[node graph demo] the document changed")
		end,
	})
	if not host then
		widgetHandler:RemoveWidget(self)
		return
	end
	host.setOpen(true)
	-- The lower half of the screen.
	local _, viewY = Spring.GetViewGeometry()
	host.place(360, viewY * 0.62)
	WG.NodeGraphDemo = { host = host, doc = doc }
end

function widget:Update()
	if host then
		host.update()
	end
end

function widget:MouseWheel(up, _value)
	return host ~= nil and host.mouseWheel(up)
end

function widget:KeyPress(key, _mods, isRepeat)
	return host ~= nil and host.keyPress(key, isRepeat)
end

function widget:Shutdown()
	if host then
		host.shutdown()
		host = nil
	end
	WG.NodeGraphDemo = nil
end
