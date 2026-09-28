-- THE GRAPH'S OWN DATA MODEL (P1 stage H5, 2026-09-27). node_graph.rml binds `node_graph_model`,
-- not the host's: its flags, its kind chips, its labels, its bound functions and its `tap`
-- registry all live here, so any widget that loads the graph document opens this model and
-- the markup works unchanged.
--
-- ONE graph per RmlUi context at a time: Recoil can only load a document from a file
-- (Context:LoadDocument), so the model name in the markup is fixed. A second host either uses
-- its own context or waits for the first to close its graph.
--
-- The host:
--     Graph.model = context:OpenDataModel(Graph.MODEL_NAME, Graph.modelFields(forms), widget)
-- before loading node_graph.rml, and `context:RemoveDataModel(Graph.MODEL_NAME)` when it shuts.
-- `forms` supplies the node editors' `formFocus/formCommit/formKey/formToggle/formSelect/formPick`
-- (me_form_view.lua's, for the mission); a host without editable nodes passes {}.

---@param deps table
return function(deps)
	local Graph = deps.Graph
	local S = deps.S
	local echo = deps.echo
	local el = deps.el
	for _, name in ipairs({ "Graph", "S", "echo", "el" }) do
		assert(deps[name] ~= nil, "ctl/model: missing dependency " .. name)
	end

	Graph.MODEL_NAME = "node_graph_model"
	Graph.RML_PATH = "luaui/RmlWidgets/node_graph/node_graph.rml"

	--- The functions the markup calls, by name. The model's own entries only forward here,
	--- because Recoil will not let a function be added or replaced after OpenDataModel: the
	--- controllers that define these are built after the model opens.
	Graph.bound = Graph.bound or {}

	--------------------------------------------------------------------------------
	-- tap('<id>'): the graph's static controls
	--------------------------------------------------------------------------------

	Graph.actions = {}

	--- A bound control's handler, run the way the host's are: the event stops here, and a
	--- throwing handler says so instead of killing the click.
	function Graph.run(event, name)
		if event and event.StopPropagation then
			event:StopPropagation()
		end
		local action = Graph.actions[name]
		if not action then
			echo("no graph action named " .. tostring(name))
			return
		end
		local ok, err = pcall(action, event)
		if not ok then
			echo("handler error on " .. tostring(name) .. ": " .. tostring(err))
		end
	end

	--- Register a control's click under its element id, for the markup's `tap('<id>')`. Says so
	--- if the element is missing or carries no binding, the one way this goes silently dead.
	function Graph.onClick(id, handler)
		local element = el(id)
		if not element then
			echo("WARNING: no element for bound graph control " .. tostring(id))
		elseif not element:HasAttribute("data-event-click") then
			echo("WARNING: " .. tostring(id) .. " has no data-event-click in the RML")
		end
		Graph.actions[id] = handler
	end

	--------------------------------------------------------------------------------
	-- Labels: data-rml="labels.<id>"
	--------------------------------------------------------------------------------

	local function modelKey(id)
		return (tostring(id):gsub("[^%w]", "_"))
	end

	--- The labels node_graph.rml declares, with their initial content, read from the file so the
	--- model has every key the markup asks for before the document loads.
	function Graph.harvestLabels()
		local labels = {}
		local text = VFS.LoadFile(Graph.RML_PATH) or ""
		for tag, inner in text:gmatch('(<[^>]-data%-rml="labels%.[%w_]+"[^>]*>)(.-)</') do
			local key = tag:match('data%-rml="labels%.([%w_]+)"')
			labels[key] = inner:find("span", 1, true) and (inner .. "</span>") or inner
		end
		return labels
	end

	--- Write a label: through the model when the markup binds it, straight into the element
	--- when it does not (the canvas's generated markup).
	function Graph.label(id, rml)
		local key = modelKey(id)
		rml = tostring(rml)
		if Graph.model and S.graphLabels and S.graphLabels[key] ~= nil then
			if S.graphLabels[key] ~= rml then
				S.graphLabels[key] = rml
				Graph.model.labels[key] = rml
			end
			return
		end
		local element = el(id)
		if element then
			element.inner_rml = rml
		end
	end

	function Graph.setText(id, text)
		Graph.label(id, text)
	end

	--- A chip's text lives in a label span: RmlUi renders nothing for text placed directly
	--- inside a flex container.
	function Graph.setChipText(id, text)
		Graph.label(id, '<span class="tf-overlay-chip-label">' .. tostring(text) .. "</span>")
	end

	--------------------------------------------------------------------------------
	-- The model
	--------------------------------------------------------------------------------

	local function forward(name)
		return function(...)
			local fn = Graph.bound[name]
			if fn then
				return fn(...)
			end
		end
	end

	--- Everything node_graph.rml binds, typed and non-nil, before the document loads.
	---@param forms table the node editors' callbacks (formFocus ...), looked up when called
	function Graph.modelFields(forms)
		forms = forms or {}
		local labels = Graph.harvestLabels()
		S.graphLabels = {}
		for key, value in pairs(labels) do
			S.graphLabels[key] = value
		end
		local fields = {
			showing = false,
			helpOpen = false,
			minimap = false,
			showCycles = false,
			-- The adapter's optional mark chip (`markToggle`); hidden when it has none.
			hasMarkToggle = false,
			markLabel = "",
			markTitle = "",
			findActive = false,
			paletteFiltered = false,
			-- Fixed length from the start (Gap 11), blanks hidden.
			graphKinds = (function()
				local rows = {}
				for index = 1, 8 do
					rows[index] = {
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
				return rows
			end)(),
			labels = labels,
			tap = function(event, name)
				Graph.run(event, name)
			end,
		}
		for _, name in ipairs({
			"graphFindKind",
			"graphFindClear",
			"graphPaletteKind",
			"graphScrollPage",
			"graphScrollGrab",
			"edgeTabGrab",
			"edgeTabClick",
			"graphExpand",
		}) do
			fields[name] = forward(name)
		end
		for _, name in ipairs({
			"formFocus",
			"formCommit",
			"formKey",
			"formToggle",
			"formSelect",
			"formPick",
			"formRemove",
		}) do
			fields[name] = function(...)
				local fn = forms[name]
				if fn then
					return fn(...)
				end
			end
		end
		return fields
	end

	--- Push the graph's state into its model: whether it is showing, its toggles, FIND, the
	--- palette's filter and the kind chips.
	function Graph.syncFlags()
		local m = Graph.model
		if not m then
			return
		end
		m.showing = Graph.host.showing() == true
		m.helpOpen = S.helpOpen == true
		m.minimap = S.graph.minimap == true
		m.showCycles = S.graph.showCycles == true
		local toggle = Graph.adapter and Graph.adapter.markToggle
		if m.hasMarkToggle ~= (toggle ~= nil) then
			m.hasMarkToggle = toggle ~= nil
		end
		if toggle and m.markLabel ~= (toggle.label or "MARKS") then
			m.markLabel = toggle.label or "MARKS"
			m.markTitle = toggle.title or ""
		end
		m.findActive = Graph.findActive and Graph.findActive() or false
		m.paletteFiltered = S.palette ~= nil and (S.palette.filter or "") ~= ""
		Graph.syncKindChips()
	end
end
