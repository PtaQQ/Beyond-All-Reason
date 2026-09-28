-- THE GRAPH'S WIRING (P1 stage H4, 2026-09-27): the toolbar chips, the viewport's, minimap's
-- and canvas's gesture listeners, the four text fields (node rename, grouping title, palette
-- search, FIND), and the per-document keyboard and release listeners. They were inline in
-- gui_mission_editor.lua's attachHandlers; a host calls `Graph.attach()` once its graph
-- document is loaded and `Graph.attachDocument(doc)` for every document keys may land in.
-- The window's own drag handle and resize grips stay with the host: the window is its.

---@param deps table
return function(deps)
	local Graph = deps.Graph
	local Bind = deps.Bind
	local S = deps.S
	local echo = deps.echo
	local el = deps.el
	local wireTextInput = deps.wireTextInput
	local render = deps.render
	for _, name in ipairs({ "Graph", "Bind", "S", "echo", "el", "wireTextInput", "render" }) do
		assert(deps[name] ~= nil, "ctl/wire: missing dependency " .. name)
	end

	--- Every listener and bound handler on the graph's own document.
	function Graph.attach()
		-- render() (the host's deferred redraw), never Graph.render: a render from inside a
		-- handler replaces the canvas holding the element RmlUi is still dispatching to, which is
		-- the crash this panel has already paid for once.
		Graph.onClick("ng-chip-graph-relayout", function()
			S.layout = Graph.autoLayout()
			Graph.resetGraphView()
			Graph.host.edited()
			render()
			echo("graph relaid out in columns")
		end)
		-- + NODE: the create palette DOCKED in the canvas's top-left corner, under the button, so
		-- it reads as dropping from it (PtaQ, 2026-09-26). The new node still lands in the middle
		-- of the view, a third of the way down: that is the point handed over for placing it.
		Graph.onClick("ng-chip-graph-add", function()
			local viewport = el("ng-graph-viewport")
			if viewport and viewport.offset_width > 0 then
				Graph.openPalette(
					viewport.absolute_left + viewport.offset_width / 2,
					viewport.absolute_top + viewport.offset_height / 3,
					nil
				)
				if S.palette then
					S.palette.docked = true
				end
			end
		end)
		Graph.onClick("ng-chip-graph-fit", function()
			local layout = Graph.fitLayout()
			if not layout then
				return
			end
			S.layout = layout
			-- FIT packs the nodes to the viewport at 1:1, so a leftover zoom would undo the
			-- one thing the button is for.
			Graph.resetGraphView()
			Graph.host.edited()
			render()
			echo("graph fitted to the window")
		end)
		-- Pan: drag the canvas itself. RmlUi raises the drag on the innermost draggable, so a
		-- press on a node drags the node and a press on empty canvas pans -- but the node's
		-- events still BUBBLE up to here, so a pan has to stand down while another gesture owns
		-- the pointer.
		-- The pan goes on the VIEWPORT as well as the canvas. The canvas only covers the
		-- content, so before this a press in the empty space around it reached nothing at all
		-- and the graph could not be dragged from there. The viewport always covers everything
		-- that can be seen.
		--
		-- Both fire for a press on the canvas, because the canvas's events bubble up through the
		-- viewport. The second one finds the gesture already running and leaves it alone.
		local canvas = el("ng-graph-canvas")
		local graphViewport = el("ng-graph-viewport")
		if graphViewport then
			-- The left button on empty space draws a rubber band. It used to pan, and pan has
			-- moved to the middle button and to space-drag, because a graph with a multi-selection
			-- needs a way to make one and the left drag is the only gesture anybody looks for.
			graphViewport:AddEventListener("dragstart", function(event)
				-- Every gesture that already owns the press, `S.commentDrag` included: dragging a
				-- comment block starts on its title bar and the event then bubbles to here, so
				-- without it the block moved with a rubber band drawn over the whole canvas.
				if
					S.graphDrag
					or S.portDrag
					or S.graphPan
					or S.graphMarquee
					or S.graphPanMouse
					or S.commentDrag
					or S.commentResize
					or S.minimapDrag
					or S.scrollDrag
				then
					return
				end
				local p = event and event.parameters or {}
				local px, py = Graph.pointerScreen(p.mouse_x, p.mouse_y)
				if Graph.spaceHeld() then
					Graph.beginPan(px, py)
				else
					Graph.beginMarquee(px, py)
				end
			end, false)
			graphViewport:AddEventListener("drag", function(event)
				if S.graphDrag or S.portDrag or S.minimapDrag or S.scrollDrag then
					return
				end
				local p = event and event.parameters or {}
				local px, py = Graph.pointerScreen(p.mouse_x, p.mouse_y)
				if S.graphMarquee then
					Graph.dragMarquee(px, py)
				else
					Graph.panTo(px, py)
				end
			end, false)
			graphViewport:AddEventListener("dragend", function()
				S.graphPan = nil
				Graph.endMarquee()
			end, false)

			-- The two buttons RmlUi's drag events never carry.
			--
			-- MIDDLE pans, which is what every node editor does and what the left button used to do
			-- before the marquee took it. RIGHT opens the create palette with no wire attached,
			-- which makes a free-standing node where the cursor is.
			graphViewport:AddEventListener("mousedown", function(event)
				local q = event and event.parameters or {}
				local px, py = Graph.pointerScreen(q.mouse_x, q.mouse_y)
				if q.button == Graph.RMLUI_BUTTON.middle then
					Graph.beginMousePan(px, py)
					if event.StopPropagation then
						event:StopPropagation()
					end
					return
				end
				if q.button ~= Graph.RMLUI_BUTTON.right then
					return
				end
				if S.palette or S.commentEdit or S.nodeRename then
					Graph.closePalette()
					Graph.closeCommentEdit()
					Graph.closeNodeRename()
					return
				end
				-- Over a node it would mean something else (a context menu, one day), so it is left
				-- alone rather than doing the wrong thing confidently.
				local cx, cy = Graph.canvasPoint(px, py)
				if Graph.nodeAt(cx, cy) then
					return
				end
				Graph.openPalette(px, py, nil)
				if event.StopPropagation then
					event:StopPropagation()
				end
			end, false)
		end

		-- THE MINIMAP. A press jumps, and a drag keeps jumping, so the graph follows the pointer
		-- for as long as the button is down.
		--
		-- `S.minimapDrag` is set on the way in and cleared on the way out, and it is in the
		-- viewport's and the canvas's gesture guards: the map sits INSIDE the viewport, so every
		-- one of these events bubbles to it, and stopping propagation alone has never been what
		-- decides which gesture owns a press in this canvas.
		local minimap = el("ng-graph-minimap")
		if minimap then
			minimap:AddEventListener("mousedown", function(event)
				local p = event and event.parameters or {}
				if p.button ~= nil and p.button ~= Graph.RMLUI_BUTTON.left then
					return
				end
				S.minimapDrag = true
				Graph.jumpMinimap(Graph.pointerScreen(p.mouse_x, p.mouse_y))
				if event and event.StopPropagation then
					event:StopPropagation()
				end
			end, false)
			minimap:AddEventListener("dragstart", function(event)
				S.minimapDrag = true
				if event and event.StopPropagation then
					event:StopPropagation()
				end
			end, false)
			minimap:AddEventListener("drag", function(event)
				local p = event and event.parameters or {}
				Graph.jumpMinimap(Graph.pointerScreen(p.mouse_x, p.mouse_y))
				if event and event.StopPropagation then
					event:StopPropagation()
				end
			end, false)
			minimap:AddEventListener("dragend", function(event)
				S.minimapDrag = nil
				if event and event.StopPropagation then
					event:StopPropagation()
				end
			end, false)
			-- A click on the map must not reach the canvas underneath, whose click handler reads
			-- "landed on nothing" and clears the selection.
			minimap:AddEventListener("click", function(event)
				if event and event.StopPropagation then
					event:StopPropagation()
				end
			end, false)
		end

		if canvas then
			-- The zoom maths below assumes the canvas scales about its own TOP-LEFT corner, so
			-- the code that assumes it is the code that sets it. The stylesheet says the same
			-- thing, but a declaration there can be dropped without anything saying so: written
			-- `transform-origin: 0 0` it was, because a bare zero carries no unit, and the
			-- element quietly used the default origin instead. The arithmetic stayed right and
			-- the picture did not match it.
			--
			-- BRACKETS, not `style.transform_origin`: a hyphenated RCSS property reached through
			-- a Lua field name is not a property RmlUi knows, and it is thrown out with a
			-- warning -- the same trap that made `z-index` never work here.
			canvas.style["transform-origin"] = "left top"
			canvas:AddEventListener("dragstart", function(event)
				if
					S.graphDrag
					or S.portDrag
					or S.graphPan
					or S.graphMarquee
					or S.graphPanMouse
					or S.commentDrag
					or S.commentResize
					or S.minimapDrag
					or S.scrollDrag
				then
					return
				end
				local p = event and event.parameters or {}
				local px, py = Graph.pointerScreen(p.mouse_x, p.mouse_y)
				if Graph.spaceHeld() then
					Graph.beginPan(px, py)
				else
					Graph.beginMarquee(px, py)
				end
			end, false)
			canvas:AddEventListener("drag", function(event)
				if S.graphDrag or S.portDrag or S.minimapDrag or S.scrollDrag then
					return
				end
				local p = event and event.parameters or {}
				local px, py = Graph.pointerScreen(p.mouse_x, p.mouse_y)
				if S.graphMarquee then
					Graph.dragMarquee(px, py)
				else
					Graph.panTo(px, py)
				end
			end, false)
			canvas:AddEventListener("dragend", function()
				S.graphPan = nil
				Graph.endMarquee()
			end, false)

			-- A click that reaches the canvas itself landed on nothing: every node stops the
			-- event. So this is the "clicked empty space" handler, and it clears the selection.
			-- NO `dblclick` here. Opening the palette on a double-click made it flicker: RmlUi
			-- raises `click` as well, and the click handler's job is to dismiss an open overlay, so
			-- the palette appeared and was shut again in the same gesture. Right-click opens
			-- it, a single unambiguous press.

			-- A click that reaches the canvas itself landed on no node: every node stops the
			-- event. So this is where a wire is picked (they cannot take the click themselves,
			-- being `pointer-events: none` two-pixel bars) and where empty space clears.
			canvas:AddEventListener("click", function(event)
				if S.graphMarquee or S.graphPan then
					return
				end
				-- The click RmlUi sends at the end of a drag, in the same frame (see
				-- Graph.endStuckGestures): part of that gesture, not a click of its own.
				if S.gestureEndedAt and S.gestureEndedAt == Graph.host.frame() then
					return
				end
				local p = event and event.parameters or {}
				Graph.clickCanvasAt(Graph.pointerScreen(p.mouse_x, p.mouse_y))
			end, false)
		end

		Graph.onClick("ng-chip-graph-comment", function()
			Graph.addComment()
		end)

		Graph.onClick("ng-chip-graph-help", function()
			Graph.renderHelp()
			Graph.setHelp(not S.helpOpen)
		end)

		Graph.onClick("ng-chip-graph-minimap", function()
			Graph.setMinimap(not S.graph.minimap)
		end)

		Graph.onClick("ng-chip-graph-zoom", function()
			Graph.resetGraphView()
			echo("graph zoom reset to 1:1")
		end)

		Graph.onClick("ng-chip-graph-showcycles", function()
			S.graph.showCycles = not S.graph.showCycles
			Graph.syncFlags()
			render()
		end)

		-- Find a node by name. Selecting it is what the graph is for; the list below follows.
		local nodeRenameInput = el("ng-node-rename-input")
		if nodeRenameInput then
			wireTextInput(nodeRenameInput)
			-- Clicking away renames too, like a folder. `closeNodeRename` clears `S.nodeRename`
			-- BEFORE it blurs, so a cancel never arrives here as a rename.
			nodeRenameInput:AddEventListener("blur", function()
				local pending = S.inputCommits["ng-node-rename-input"]
				if S.nodeRename and pending then
					pending.commit()
				end
			end, false)
			S.inputCommits["ng-node-rename-input"] = {
				element = nodeRenameInput,
				commit = function()
					local key = S.nodeRename
					S.nodeRename = nil
					local kind, id = Graph.splitKey(key or "")
					if kind then
						-- The graph moves the node's layout and selection itself, so every adapter keeps
						-- the node where it was dragged to (the mission's panel rename already did; a no-op then).
						local newId =
							Graph.adapter.rename(kind, id, tostring(nodeRenameInput:GetAttribute("value") or ""))
						if newId and newId ~= id then
							Graph.renameNodeKey(kind, id, newId)
						end
					end
					render()
				end,
				revert = function()
					Graph.closeNodeRename()
				end,
			}
		end

		local commentTitle = el("ng-comment-title")
		if commentTitle then
			wireTextInput(commentTitle)
			-- Clicking away renames, like a folder; `closeCommentEdit` clears the state first, so a
			-- cancel never arrives here.
			commentTitle:AddEventListener("blur", function()
				local pending = S.inputCommits["ng-comment-title"]
				if S.commentEdit and pending then
					pending.commit()
				end
			end, false)
			S.inputCommits["ng-comment-title"] = {
				element = commentTitle,
				commit = function()
					local frame = S.commentEdit and Graph.commentById(S.commentEdit)
					if frame then
						local typed = tostring(commentTitle:GetAttribute("value") or "")
						-- An empty title would leave a coloured rectangle with nothing to say, so
						-- it keeps the one it had rather than becoming nameless.
						if typed ~= "" then
							frame.title = typed
							Graph.host.edited()
						end
					end
					S.commentEdit = nil
					render()
				end,
				revert = function()
					Graph.closeCommentEdit()
				end,
			}
		end

		-- ALL is markup; the kinds' chips are bound (`graphKinds`, `Graph.bound.graphPaletteKind`).
		Graph.onClick("ng-palette-kind-all", function()
			Graph.setPaletteKind("all")
		end)

		local paletteSearch = el("ng-palette-search")
		if paletteSearch then
			wireTextInput(paletteSearch)
			paletteSearch:AddEventListener("change", function()
				if S.palette then
					S.palette.filter = tostring(paletteSearch:GetAttribute("value") or "")
					render()
				end
			end, false)
			-- Enter takes the top hit, and Escape cancels. Registered the same way every other
			-- committing field is, so both the RmlUi keydown path and `widget:KeyPress` reach it:
			-- one of those two is the one that actually fires, and which one has changed twice.
			S.inputCommits["ng-palette-search"] = {
				element = paletteSearch,
				commit = function()
					local matches = S.palette and S.palette.matches
					if matches and matches[1] then
						Graph.paletteAccept(matches[1])
					end
				end,
				revert = function()
					Graph.closePalette()
				end,
			}
			-- The x inside the palette's field: empty it and keep typing.
			Graph.onClick("ng-palette-clear", function()
				if S.palette then
					S.palette.filter = ""
				end
				pcall(function()
					paletteSearch:SetAttribute("value", "")
				end)
				S.focusAfterRender = "ng-palette-search"
				render()
			end)
		end

		wireTextInput(el("ng-graph-search"))
		local graphSearch = el("ng-graph-search")
		if graphSearch then
			graphSearch:AddEventListener("change", function()
				S.graphFind = tostring(graphSearch:GetAttribute("value") or "")
				-- Back to the start of the list. Without this, editing the text and pressing Enter
				-- would land on the second match of the NEW search.
				S.searchAt = 0
				Graph.syncFlags()
				S.elementCache = {}
				render()
			end, false)
			-- Enter walks the matches rather than merely letting go of the box, which is all it
			-- did before. Registered as a commit so both the RmlUi keydown path and
			-- `widget:KeyPress` reach it.
			S.inputCommits["ng-graph-search"] = {
				element = graphSearch,
				commit = Graph.findNext,
				revert = function()
					-- Escape clears the search and the kind chips, the same as the x.
					Graph.bound.graphFindClear()
				end,
			}
		end
	end

	--- The graph's listeners on one document: its keyboard, and the release that ends every
	--- canvas gesture.
	function Graph.attachDocument(document)
		-- **The canvas's keyboard.** `widget:KeyPress` does not get these: Recoil's
		-- `CGameInputReceiver::KeyPressed` returns the moment RmlUi reports the key handled,
		-- before LuaUI is reached, and with a document up RmlUi takes almost everything. Escape
		-- is the one that still arrives there, which is why Escape worked and Delete did not.
		document:AddEventListener("keydown", function(event)
			Graph.onRmlKey(event)
		end, false)

		-- The end of a middle-button pan. On the document rather than the viewport: a pan that
		-- wandered off the canvas still has to be able to stop, and there is nothing to be
		-- gained by making the release land in the same place the press did.
		-- **Every gesture ends here.** A gesture on the canvas is started by an RmlUi
		-- `dragstart` and ended by its `dragend`, and a `dragend` does not arrive if the release
		-- lands somewhere RmlUi does not deliver it. One missed release and the canvas believes
		-- a drag is still running for the rest of the session: harmless until auto-pan arrived,
		-- and then the view slides away whenever the pointer goes near an edge and never stops.
		--
		-- The document's mouseup always arrives, which is exactly why `attachDraggable` has
		-- stopped on it since the beginning. This is the same discipline for the canvas.
		document:AddEventListener("mouseup", function()
			Graph.endMousePan()
			Graph.endStuckGestures()
		end, false)
	end

	--------------------------------------------------------------------------------
	-- The host's call-ins (P1 stage H6): a host forwards these and the graph does the rest.
	--------------------------------------------------------------------------------

	--- Every frame: the gestures that are polled rather than evented (middle-button pan, the
	--- scrollbars, the edge tabs, auto-pan at the edges, wire hover) and the zoom glide.
	function Graph.update()
		Graph.pollMousePan()
		Graph.pollScrollDrag()
		Graph.pollEdgeDrag()
		Graph.pollAutoPan()
		Graph.pollEdgeHover()
		Graph.pollViewAnim()
		Graph.pollGhost()
	end

	--- The host's deferred render: the canvas when the window is open (never under a live
	--- drag, whose elements a rebuild would kill), then the overlays that follow it.
	function Graph.draw(open)
		if open and not (S.graphDrag or S.portDrag or S.commentDrag or S.commentResize) then
			Graph.render()
		end
		Graph.syncKindChips()
		Graph.renderPalette()
		Graph.renderCommentEdit()
		Graph.renderNodeRename()
	end

	--- A field the host just gave the caret. The rename and grouping-title fields arrive with
	--- their whole text selected, so typing replaces the name (PtaQ, 2026-09-26).
	function Graph.onFocused(id, element)
		if id == "ng-node-rename-input" or id == "ng-comment-title" then
			Graph.selectAllIn(element)
		end
	end

	--- The wheel, with the pointer in RmlUi screen pixels. true when the graph claims it.
	function Graph.mouseWheel(up, pointerX, pointerY)
		if not (Graph.host.showing() and Graph.inGraphViewport(pointerX, pointerY)) then
			return false
		end
		-- Over the graph the wheel is OURS, whether or not it changed anything. Returning what
		-- zoomGraph returned handed the wheel back to the game the moment the zoom hit either
		-- end of its range, so the map started zooming under a pointer that was still inside the
		-- editor. What decides the claim is where the pointer is, not whether we did something
		-- with it.
		--
		-- The Windows convention: the wheel scrolls, Shift+wheel scrolls sideways, Ctrl+wheel
		-- zooms about the pointer. `S.wheelMods` is the harness's stand-in for held keys.
		local _, ctrl, _, shift = Spring.GetModKeyState()
		local held = S.wheelMods
		if held then
			ctrl, shift = held.ctrl == true, held.shift == true
		end
		if ctrl then
			Graph.zoomGraph(up and 1 or -1, pointerX, pointerY)
		else
			local step = (up and 1 or -1) * Graph.lib.GRAPH.scrollStepPx
			if shift then
				Graph.scrollBy(step, 0)
			else
				Graph.scrollBy(0, step)
			end
		end
		return true
	end

	--- A key the host received. Only while the graph shows, no text field has the caret, and
	--- the pointer is over the viewport. true when the graph claims it.
	function Graph.keyPress(key)
		if Graph.host.typing() or not Graph.host.showing() then
			return false
		end
		local pointerX, pointerY = Graph.pointerScreen()
		local over = Graph.inGraphViewport(pointerX, pointerY)
		if S.keyDebug then
			-- The number AND whether the pointer gate let it through. A shortcut that does
			-- nothing is one of those two, and guessing which cost this pass an evening.
			echo(string.format("graph key %s, pointer over the canvas: %s", tostring(key), tostring(over)))
		end
		if not over then
			return false
		end
		local alt, ctrl, _, shift = Spring.GetModKeyState()
		local action = Graph.actionForKey(key)
		if action and Graph.keyAlreadyHandled(action) then
			-- RmlUi already dealt with this press. Claimed, so it goes no further, but not
			-- acted on twice.
			return true
		end
		local ok, consumed = pcall(Graph.handleKey, key, ctrl, shift, alt)
		if not ok then
			echo("graph key handler error: " .. tostring(consumed))
			return false
		end
		return consumed == true
	end
end
