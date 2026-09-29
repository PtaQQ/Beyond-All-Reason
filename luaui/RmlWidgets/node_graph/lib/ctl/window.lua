-- THE GRAPH WINDOW MOVES AND RESIZES: the title bar drags it, a grip on any edge or corner sizes
-- it. Self-contained, so a host needs no other widget for it.
--
-- Built the way the Terraformer's `attachDraggable` / `attachResizable` are, and for the same
-- reason: RmlUi's drag events do not carry a reliable button and stop arriving the moment the
-- pointer leaves the element, which for a window is most of the time. So the handle and the
-- grips only report `mousedown`; from then on the mouse is read once a frame (`Window.tick`,
-- called from the host's update) until the button is let go.
--
-- WHEN THE BUTTON IS LET GO is read from the pressed element's `:active`, not from the mouse.
-- Spring.GetMouseState cannot say: the engine never records a press RmlUi consumed, so its
-- left button reads false for the whole gesture. And the document's `mouseup` alone misses a
-- release over the map, over another window or outside the game window, which left the window
-- stuck to the pointer. RmlUi clears `:active` on the whole press chain on any release
-- (Context::ResetActiveChain). The press handler sets it itself, because it stops the press
-- propagating and RmlUi then skips every default action, the one that sets `:active` included.
--
-- The HEIGHT goes to the viewport, not the window. The window is a stack (header, toolbar,
-- viewport, footer): forcing a height onto it leaves its children adding up to more than it
-- has and pushes the footer out of the bottom. The width goes on the window. Pulling a west or
-- north edge moves the window as well, so the opposite edge stays where it is.
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

	-- One gesture at a time: "move", or the edges a grip pulls ("e", "s", "se", "nw", ...).
	local g = { mode = nil, pressed = nil, grabX = 0, grabY = 0, x = 0, y = 0, w = 0, h = 0 }

	local GRIPS = {
		["ng-graph-grip-e"] = "e",
		["ng-graph-grip-s"] = "s",
		["ng-graph-grip-se"] = "se",
		["ng-graph-grip-w"] = "w",
		["ng-graph-grip-n"] = "n",
		["ng-graph-grip-nw"] = "nw",
		["ng-graph-grip-ne"] = "ne",
		["ng-graph-grip-sw"] = "sw",
	}

	local function mouseTopDown()
		local mx, my = Spring.GetMouseState()
		local _, vsy = Spring.GetViewGeometry()
		return mx, vsy - my
	end

	--- Is the button that started the gesture still held? nil when it cannot be read.
	local function stillHeld(element)
		if not element then
			return nil
		end
		local ok, active = pcall(function()
			return element:IsPseudoClassSet("active")
		end)
		if not ok then
			return nil
		end
		return active == true
	end

	local function finish()
		local was = g.mode
		g.mode = nil
		g.pressed = nil
		if was and was ~= "move" and deps.onDone then
			deps.onDone()
		end
	end

	local function begin(mode, event, element)
		local p = event and event.parameters
		if not p or (p.button and p.button ~= 0) then
			return
		end
		g.mode = mode
		g.pressed = element
		pcall(function()
			element:SetPseudoClass("active", true)
		end)
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
				begin("move", event, handle)
			end, false)
		end
	end
	if deps.resizable ~= false then
		for id, edges in pairs(GRIPS) do
			local grip = document:GetElementById(id)
			if grip then
				grip:AddEventListener("mousedown", function(event)
					begin(edges, event, grip)
				end, false)
			end
		end
	end

	document:AddEventListener("mouseup", finish, false)

	--- Every frame from the host's update. Writes styles only; the canvas is rebuilt on the
	--- drop (`onDone`), because rebuilding it under a live gesture is a known crash.
	function Window.tick()
		if not g.mode then
			return
		end
		if stillHeld(g.pressed) == false then
			finish()
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
		local mode = g.mode
		local w, h, x, y = g.w, g.h, g.x, g.y
		if mode:find("e", 1, true) then
			w = g.w + dx
		elseif mode:find("w", 1, true) then
			w = g.w - dx
			x = g.x + dx
		end
		if mode:find("s", 1, true) then
			h = g.h + dy
		elseif mode:find("n", 1, true) then
			h = g.h - dy
			y = g.y + dy
		end
		-- Clamp at the minimum by giving back exactly what was refused, or a window pulled past
		-- its own minimum from the left would keep sliding while it stopped shrinking.
		if w < minWidth then
			if mode:find("w", 1, true) then
				x = x - (minWidth - w)
			end
			w = minWidth
		end
		if h < minHeight then
			if mode:find("n", 1, true) then
				y = y - (minHeight - h)
			end
			h = minHeight
		end
		w, h = math.floor(w), math.floor(h)
		if mode:find("[ew]") then
			root.style.width = w .. "px"
		end
		if mode:find("[ns]") then
			viewport.style.height = h .. "px"
			-- A minimum in the stylesheet would otherwise fight this silently.
			viewport.style["min-height"] = math.min(h, minHeight) .. "px"
		end
		if x ~= g.x then
			root.style.left = math.floor(x) .. "px"
		end
		if y ~= g.y then
			root.style.top = math.floor(y) .. "px"
		end
		if deps.onResize then
			deps.onResize(w, h)
		end
	end

	return Window
end
