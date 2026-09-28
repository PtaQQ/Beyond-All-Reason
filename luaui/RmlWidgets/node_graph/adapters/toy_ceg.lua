-- THE WORKED EXAMPLE ADAPTER: a CEG-ish graph, emitter -> spawner -> particle, over its own
-- small document. Every field of the contract (core.lua, above `ADAPTER_CONTRACT`) answered
-- as simply as it can be; copy it to start an adapter of your own. Its kinds' colours are the
-- template block in kinds.rcss. Loaded by luaui/Widgets/dbg_node_graph_demo.lua and by
-- spec/node_graph/contract_spec.lua.
--
--     local adapter = VFS.Include(".../adapters/toy_ceg.lua")({ Core = Core, doc = doc })
--
-- The document: { emitters = { { id, rate, spawners = { id } } },
--                 spawners = { { id, count, particles = { id } } },
--                 particles = { { id, texture } } }

---@param deps table { Core = the graph core, doc = the document it edits }
return function(deps)
	local Core = deps.Core
	local doc = deps.doc
	assert(Core and doc, "toy_ceg adapter: needs Core and doc")

	-- The contract version this adapter was written for (node_graph.lua `CONTRACT`).
	local Adapter = { contract = 1 }

	--- Which list a kind lives in, and which list on it holds its outgoing wires.
	local LIST = { emitter = "emitters", spawner = "spawners", particle = "particles" }
	local WIRES = { emitter = "spawners", spawner = "particles" }
	local WANTS = { emitter = "spawner", spawner = "particle" }

	Adapter.kinds = {
		{ kind = "emitter", tint = { 0xf7, 0x7a, 0x9d } },
		{ kind = "spawner", tint = { 0x8f, 0xd4, 0x62 } },
		{ kind = "particle", tint = { 0xe6, 0xe9, 0xf0 } },
	}

	function Adapter.records(kind)
		doc[LIST[kind]] = doc[LIST[kind]] or {}
		return LIST[kind] and doc[LIST[kind]] or {}
	end

	function Adapter.find(kind, id)
		for _, record in ipairs(LIST[kind] and Adapter.records(kind) or {}) do
			if record.id == id then
				return record
			end
		end
		return nil
	end

	function Adapter.layout(measure)
		local bands = {}
		for _, entry in ipairs(Adapter.kinds) do
			bands[#bands + 1] = { kind = entry.kind, records = Adapter.records(entry.kind), reserve = true }
		end
		return Core.LayoutBands(bands, measure)
	end

	function Adapter.outPorts(kind)
		return WANTS[kind] and { { wants = WANTS[kind] } } or {}
	end

	function Adapter.edges()
		local edges = {}
		for kind, field in pairs(WIRES) do
			for _, record in ipairs(Adapter.records(kind)) do
				for _, targetId in ipairs(record[field] or {}) do
					if Adapter.find(WANTS[kind], targetId) then
						edges[#edges + 1] =
							{ from = Core.Key(kind, record.id), to = Core.Key(WANTS[kind], targetId), kind = kind }
					end
				end
			end
		end
		return edges
	end

	local function wired(source, targetId, field)
		for index, id in ipairs(source[field] or {}) do
			if id == targetId then
				return index
			end
		end
		return nil
	end

	function Adapter.canLink(sourceKey, targetKey)
		local fromKind, fromId = Core.SplitKey(sourceKey or "")
		local toKind, toId = Core.SplitKey(targetKey or "")
		local source = fromKind and Adapter.find(fromKind, fromId)
		if not (source and toKind and Adapter.find(toKind, toId)) then
			return false, "no such node"
		end
		if WANTS[fromKind] ~= toKind then
			return false,
				string.format("a %s feeds a %s, not a %s", fromKind, tostring(WANTS[fromKind] or "nothing"), toKind)
		end
		if wired(source, toId, WIRES[fromKind]) then
			return false, "already wired"
		end
		return true, string.format("%s will feed %s", fromId, toId)
	end

	function Adapter.canLinkNew(pending, kind)
		if not pending then
			return true
		end
		local fixedKind = Core.SplitKey(pending.fixedKey or "")
		if pending.fixedIsSource then
			return WANTS[fixedKind] == kind
		end
		return WANTS[kind] == fixedKind
	end

	function Adapter.link(sourceKey, targetKey)
		local ok, message = Adapter.canLink(sourceKey, targetKey)
		if not ok then
			return false, message
		end
		local fromKind, fromId = Core.SplitKey(sourceKey)
		local _, toId = Core.SplitKey(targetKey)
		local source = Adapter.find(fromKind, fromId)
		local field = WIRES[fromKind]
		source[field] = source[field] or {}
		source[field][#source[field] + 1] = toId
		return true, string.format("%s now feeds %s", fromId, toId)
	end

	function Adapter.unlink(sourceKey, targetKey)
		local fromKind, fromId = Core.SplitKey(sourceKey or "")
		local _, toId = Core.SplitKey(targetKey or "")
		local source = fromKind and Adapter.find(fromKind, fromId)
		local index = source and wired(source, toId, WIRES[fromKind])
		if not index then
			return false
		end
		table.remove(source[WIRES[fromKind]], index)
		return true
	end

	function Adapter.describeEdge(edge)
		local _, fromId = Core.SplitKey(edge and edge.from or "")
		local _, toId = Core.SplitKey(edge and edge.to or "")
		return string.format("%s feeds %s", tostring(fromId), tostring(toId))
	end

	function Adapter.edgeStrength()
		return 0xb4
	end

	function Adapter.editable()
		return false
	end

	function Adapter.rows(kind, record)
		if kind == "emitter" then
			return { { label = "rate", value = tostring(record.rate or 1) } }
		elseif kind == "spawner" then
			return { { label = "count", value = tostring(record.count or 1) } }
		end
		return { { label = "texture", value = tostring(record.texture or "none") } }
	end

	function Adapter.summary(_, _, rows)
		return rows
	end

	function Adapter.subtitle(kind)
		return kind:upper(), nil
	end

	function Adapter.badge()
		return nil
	end

	function Adapter.form()
		return nil
	end

	function Adapter.palette(pending)
		local options = {}
		for _, entry in ipairs(Adapter.kinds) do
			if Adapter.canLinkNew(pending, entry.kind) then
				options[#options + 1] = { kind = entry.kind, type = "NEW " .. entry.kind:upper(), new = true }
			end
		end
		return options
	end

	local function freshId(kind)
		local n = #Adapter.records(kind) + 1
		while Adapter.find(kind, kind .. n) do
			n = n + 1
		end
		return kind .. n
	end

	function Adapter.create(option)
		local id = freshId(option.kind)
		local list = Adapter.records(option.kind)
		list[#list + 1] = { id = id }
		return Core.Key(option.kind, id), string.format("added %s '%s'", option.kind, id)
	end

	function Adapter.inspect() end

	function Adapter.syncInspector() end

	function Adapter.haystack(kind, record)
		return (kind .. " " .. tostring(record.id) .. " " .. tostring(record.texture or "")):lower()
	end

	--- Copies, with only the wires between copied nodes carried.
	function Adapter.duplicate(keys)
		local renamed, copies = {}, {}
		for _, key in ipairs(keys) do
			local kind, id = Core.SplitKey(key)
			local source = kind and Adapter.find(kind, id)
			if source then
				local copy = {}
				for field, value in pairs(source) do
					copy[field] = type(value) == "table" and {} or value
				end
				copy.id = freshId(kind)
				renamed[key] = copy.id
				local list = Adapter.records(kind)
				list[#list + 1] = copy
				copies[#copies + 1] = { kind = kind, source = source, copy = copy, fromKey = key }
			end
		end
		for _, entry in ipairs(copies) do
			local field = WIRES[entry.kind]
			for _, targetId in ipairs(field and entry.source[field] or {}) do
				local newId = renamed[Core.Key(WANTS[entry.kind], targetId)]
				if newId then
					entry.copy[field][#entry.copy[field] + 1] = newId
				end
			end
		end
		local out = {}
		for _, entry in ipairs(copies) do
			out[#out + 1] = { fromKey = entry.fromKey, key = Core.Key(entry.kind, entry.copy.id) }
		end
		return out
	end

	function Adapter.remove(kind, id)
		local list = Adapter.records(kind)
		for index, record in ipairs(list) do
			if record.id == id then
				table.remove(list, index)
				-- And every wire into it.
				for sourceKind, field in pairs(WIRES) do
					if WANTS[sourceKind] == kind then
						for _, source in ipairs(Adapter.records(sourceKind)) do
							local at = wired(source, id, field)
							if at then
								table.remove(source[field], at)
							end
						end
					end
				end
				return true
			end
		end
		return false, "no such " .. kind
	end

	function Adapter.rename(kind, id, newId)
		local record = Adapter.find(kind, id)
		newId = newId:match("^%s*(.-)%s*$")
		if not record or newId == "" or Adapter.find(kind, newId) then
			return nil
		end
		record.id = newId
		for sourceKind, field in pairs(WIRES) do
			if WANTS[sourceKind] == kind then
				for _, source in ipairs(Adapter.records(sourceKind)) do
					local at = wired(source, id, field)
					if at then
						source[field][at] = newId
					end
				end
			end
		end
		return newId
	end

	function Adapter.connect()
		return nil, "a CEG graph is wired by hand"
	end

	function Adapter.marks()
		return { cycle = {}, warn = {}, loops = 0 }
	end

	function Adapter.notice()
		return nil
	end

	--- Its own document: groupings and positions travel with it, never into the mission's.
	function Adapter.store()
		return doc
	end

	return Adapter
end
