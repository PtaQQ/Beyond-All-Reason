-- THE GRAPH WINDOW MOVES AND RESIZES: the title bar drags it, the grips on its right and bottom
-- edges size it. Self-contained, so a host needs no other widget for it.
--
-- Built the way the Terraformer's `attachDraggable` / `attachResizable` are, and for the same
-- reason: RmlUi's drag events do not carry a reliable button and stop arriving the moment the
-- pointer leaves the element, which for a window is most of the time. So the handle and the
-- grips only report `mousedown`; from then on the mouse is read once a frame (`Window.tick`,
-- called from the host's update) until the document sees a `mouseup`.
--
-- The HEIGHT goes to the viewport, not the window. The window is a stack (header, toolbar,
-- viewport, footer): forcing a height onto it leaves its children adding up to more than it
-- has and pushes the footer out of the bottom. The width goes on the window.
--
--     local Window = VFS.Include(".../ctl/window.lua")({ document = document, root = windowEl,
--         viewport = viewportEl, minWidth = 620, minHeight = 260, onResize = f, onDone = g })

---@param deps table { document, root, viewport, minWidth?, minHeight?, movable?, resizable?, onResize?, onDone? }
---@return table { tick }
return function(deps)
	local document, root, viewport = deps.document, deps.root, deps.viewport
	local minWidth = deps.minWidth or 620
	local minHeight = deps.minHeight or 260
	local Window = {}

	-- One gesture at a time: "move", or the edges a grip pulls ("e", "s", "se").
	local g = { mode = nil, grabX = 0, grabY = 0, x = 0, y = 0, w = 0, h = 0 }

	local function mouseTopDown()
		local mx, my = Spring.GetMouseState()
		local _, vsy = Spring.GetViewGeometry()
		return mx, vsy - my
	end

	local function begin(mode, event)
		local p = event and event.parameters
		if not p or (p.button and p.button ~= 0) then
			return
		end
		g.mode = mode
		g.grabX, g.grabY = mouseTopDown()
		g.x, g.y = root.offset_left, root.offset_top
		g.w, g.h = root.offset_width, viewport.offset_height
		-- A grip sits inside the window: without this the press also reaches the handle.
		event:StopPropagation()
	end

	if deps.movable ~= false then
		local handle = document:GetElementById("ng-graph-handle")
		if handle then
			handle:AddEventListener("mousedown", function(event)
				begin("move", event)
			end, false)
		end
	end
	if deps.resizable ~= false then
		for id, edges in pairs({ ["ng-graph-grip-e"] = "e", ["ng-graph-grip-s"] = "s", ["ng-graph-grip-se"] = "se" }) do
			local grip = document:GetElementById(id)
			if grip then
				grip:AddEventListener("mousedown", function(event)
					begin(edges, event)
				end, false)
			end
		end
	end

	document:AddEventListener("mouseup", function()
		local was = g.mode
		g.mode = nil
		if was and was ~= "move" and deps.onDone then
			deps.onDone()
		end
	end, false)

	--- Every frame from the host's update. Writes styles only; the canvas is rebuilt on the
	--- drop (`onDone`), because rebuilding it under a live gesture is a known crash.
	function Window.tick()
		if not g.mode then
			return
		end
		local _, _, _, _, _, offscreen = Spring.GetMouseState()
		if offscreen then
			return
		end
		local mx, my = mouseTopDown()
		local dx, dy = mx - g.grabX, my - g.grabY
		if g.mode == "move" then
			-- Clamped to the window, not the world view: in a dual-screen layout the window
			-- spans both monitors and dragging a panel across is the point.
			local vsx, vsy = Spring.GetViewGeometry()
			local winX = Spring.GetWindowGeometry()
			local maxX = ((winX and winX > vsx) and winX or vsx) - root.offset_width
			local maxY = vsy - root.offset_height
			root.style.left = math.floor(math.max(0, math.min(maxX, g.x + dx))) .. "px"
			root.style.top = math.floor(math.max(0, math.min(maxY, g.y + dy))) .. "px"
			return
		end
		local w, h = g.w, g.h
		if g.mode:find("e", 1, true) then
			w = math.max(minWidth, math.floor(g.w + dx))
			root.style.width = w .. "px"
		end
		if g.mode:find("s", 1, true) then
			h = math.max(minHeight, math.floor(g.h + dy))
			viewport.style.height = h .. "px"
			-- A minimum in the stylesheet would otherwise fight this silently.
			viewport.style["min-height"] = math.min(h, minHeight) .. "px"
		end
		if deps.onResize then
			deps.onResize(w, h)
		end
	end

	return Window
end
