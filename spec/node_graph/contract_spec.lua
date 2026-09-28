require("spec_helper")

-- THE ADAPTER CONTRACT. The graph reads a graph's meaning only through an adapter; these hold
-- every adapter in the tree to the contract in core.lua, so a field the controllers call can
-- never go missing and a change to the contract fails here before it breaks a tool.
--
-- YOUR ADAPTER: add it to ADAPTERS below with a function that builds it on a small document.

local CORE = "luaui/RmlWidgets/node_graph/lib/core.lua"
local Core = VFS.Include(CORE)
local NodeGraph = VFS.Include("luaui/RmlWidgets/node_graph/lib/node_graph.lua")
local TOY = "luaui/RmlWidgets/node_graph/adapters/toy_ceg.lua"

local function toyDoc()
	return {
		emitters = { { id = "sparks", rate = 4, spawners = { "burst" } } },
		spawners = { { id = "burst", count = 12, particles = { "glow" } } },
		particles = { { id = "glow", texture = "flare" }, { id = "smoke", texture = "puff" } },
	}
end

--- Every adapter in the tree: name -> a function building it.
local ADAPTERS = {
	toy_ceg = function()
		return VFS.Include(TOY)({ Core = Core, doc = toyDoc() })
	end,
}

--- The required fields as core.lua's header lists them ("--   name" lines, three spaces in,
--- up to the OPTIONAL heading), so the list the spec checks is the list a reader sees.
local function documentedFields()
	local handle = io.open(CORE, "rb")
	assert(handle, "cannot read " .. CORE)
	local text = handle:read("*a"):gsub("\r\n", "\n")
	handle:close()
	local required = text:match("THE ADAPTER CONTRACT(.-)\n%-%- OPTIONAL")
	assert(required, "core.lua has no contract header")
	local fields = {}
	for name in required:gmatch("\n%-%-   ([%a]+)[%(%s]") do
		fields[#fields + 1] = name
	end
	return fields
end

describe("node_graph contract", function()
	it("is documented field by field, exactly, in core.lua", function()
		assert.are.equal(table.concat(Core.ADAPTER_CONTRACT, ","), table.concat(documentedFields(), ","))
	end)

	it("names what an adapter lacks", function()
		assert.are.same({}, Core.MissingFields(ADAPTERS.toy_ceg()))
		local partial = ADAPTERS.toy_ceg()
		partial.store, partial.kinds = nil, nil
		assert.are.same({ "kinds", "store" }, Core.MissingFields(partial))
	end)

	for name, build in pairs(ADAPTERS) do
		it(name .. " supplies every field and declares the current contract", function()
			local adapter = build()
			for _, field in ipairs(Core.ADAPTER_CONTRACT) do
				assert.is_not_nil(adapter[field], name .. " is missing " .. field)
			end
			assert.are.equal(NodeGraph.CONTRACT, adapter.contract)
		end)

		it(name .. " lists kinds with plain names and a tint", function()
			for _, entry in ipairs(build().kinds) do
				assert.is_truthy(entry.kind:match("^%a+$"), "kind names become class names: " .. tostring(entry.kind))
				assert.are.equal(3, #entry.tint)
			end
		end)
	end
end)

describe("node_graph adapters/toy_ceg", function()

	it("reads its own nodes and wires, and lays them out in bands", function()
		local toy = VFS.Include(TOY)({ Core = Core, doc = toyDoc() })
		assert.are.equal(2, #toy.records("particle"))
		assert.are.equal(2, #toy.edges())
		local layout = toy.layout(nil)
		assert.is_true(layout["emitter:sparks"].x < layout["spawner:burst"].x)
		assert.is_true(layout["spawner:burst"].x < layout["particle:glow"].x)
	end)

	it("wires only down the chain, once", function()
		local doc = toyDoc()
		local toy = VFS.Include(TOY)({ Core = Core, doc = doc })
		assert.is_false((toy.canLink("emitter:sparks", "particle:glow")))
		assert.is_false((toy.canLink("spawner:burst", "particle:glow")), "already wired")
		assert.is_true((toy.link("spawner:burst", "particle:smoke")))
		assert.are.equal(3, #toy.edges())
		assert.is_true(toy.unlink("spawner:burst", "particle:smoke"))
		assert.are.equal(2, #toy.edges())
	end)

	it("offers only what can take the wire in flight", function()
		local toy = VFS.Include(TOY)({ Core = Core, doc = toyDoc() })
		local options = toy.palette({ fixedKey = "emitter:sparks", fixedIsSource = true })
		assert.are.equal(1, #options)
		assert.are.equal("spawner", options[1].kind)
	end)

	it("creates, duplicates with inner wires, renames and removes", function()
		local doc = toyDoc()
		local toy = VFS.Include(TOY)({ Core = Core, doc = doc })
		local key = toy.create({ kind = "particle" })
		assert.are.equal("particle:particle3", key)
		local copies = toy.duplicate({ "spawner:burst", "particle:glow" })
		assert.are.equal(2, #copies)
		local copy = toy.find("spawner", (copies[1].key:gsub("^spawner:", "")))
		assert.are.equal(1, #copy.particles, "the wire between the two copies is carried")
		assert.are.equal("shine", toy.rename("particle", "glow", " shine "), "the id it now has, trimmed")
		assert.are.equal("shine", doc.spawners[1].particles[1])
		assert.is_nil(toy.rename("particle", "shine", "particle3"), "a taken id is refused")
		assert.is_true(toy.remove("particle", "shine"))
		assert.are.equal(0, #doc.spawners[1].particles)
	end)
end)
