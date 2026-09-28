# Node Graph: a node editor for your widget

A reusable node-graph editor for BAR widgets. You describe your graph in one table (an **adapter**); the library draws it and handles the editing. It was built for the Mission Editor and made generic so other tools can use it. The CEG composer is the first one lined up.

| | |
|---|---|
| Version | `1.0.0`, adapter contract `1` (`luaui/RmlWidgets/node_graph/lib/node_graph.lua`) |
| Worked example | `luaui/Widgets/dbg_node_graph_demo.lua` + `adapters/toy_ceg.lua` (emitter -> spawner -> particle) |
| Checks | `spec/node_graph/` (busted), `luaui/Widgets/dbg_node_graph_probe.lua` (live) |
| Changes | `doc/NodeGraph-changelog.md` |
| Maintainer | PtaQ. Tag him on PRs that touch `luaui/RmlWidgets/node_graph/` |
| Limit | One graph per RmlUi context (section 6) |

## 1. What you get

Nodes in coloured kinds, wires between named ports, a create palette (right-click or + NODE), rubber-band and multi-select, drag, align and distribute, groupings, FIND with kind chips, a minimap, an animated zoom that shows only names when zoomed out, keyboard shortcuts (the KEYS card), undo/redo hooks, and a window that moves and resizes. You supply what the nodes mean.

## 2. Files

All under `luaui/RmlWidgets/node_graph/`.

| File | What it is | Public? |
|---|---|---|
| `lib/node_graph.lua` | **Start here.** `NodeGraph.create{...}`, `VERSION`, `CONTRACT` | yes |
| `lib/core.lua` | Pure geometry and layout (`LayoutBands`), and the **adapter contract**, documented field by field | the contract, `Key`, `SplitKey`, `LayoutBands`, `MissingFields` |
| `adapters/toy_ceg.lua` | The example adapter, about 300 lines. Copy it | example |
| `kinds.rcss` | The look of every node kind. **Your kinds go here** (section 5) | yes, add to it |
| `node_graph.rml`, `node_graph.rcss`, `node_graph_after.rcss` | The window's markup and style | no |
| `lib/ctl/*.lua` | The controllers: model, nodes, canvas, edit, link, view, wire, window | no |

"Not public" means those files can change in any release without notice. Build only on the public parts.

The Lua lives in `lib/` on purpose: BAR's widget loader tries every `.lua` file directly inside a `RmlWidgets/<folder>/` as a widget.

## 3. Host the graph in your widget

```lua
local NodeGraph = VFS.Include("luaui/RmlWidgets/node_graph/lib/node_graph.lua")
local graph

function widget:Initialize()
	graph = NodeGraph.create({
		widget = self,
		context = RmlUi.GetContext("my_graph") or RmlUi.CreateContext("my_graph"), -- section 6
		adapter = function(Core)
			return VFS.Include("luaui/Widgets/my_tool/my_adapter.lua")({ Core = Core, doc = myDocument })
		end,
		edited = function() --[[ mark dirty, take an undo step ]] end,
	})
	if not graph then
		return widgetHandler:RemoveWidget(self) -- the reason is in the log
	end
	graph.setOpen(true)
	graph.place(360, 600)
end
function widget:Update() graph.update() end
function widget:MouseWheel(up) return graph.mouseWheel(up) end
function widget:KeyPress(key, _, isRepeat) return graph.keyPress(key, isRepeat) end
function widget:Shutdown() graph.shutdown() end
```

`NodeGraph.create` options:

| Option | Required | Meaning |
|---|---|---|
| `widget`, `context`, `adapter` | yes | `adapter(Core)` returns your adapter table |
| `edited()` | | The graph changed your document (a wire, a move, a delete). Mark it dirty, take an undo step |
| `analyse()` | | Wires changed; recompute anything you derive from them |
| `undo()`, `redo()` | | Ctrl+Z / Ctrl+Y on the canvas |
| `closed()` | | The window's close button was pressed (the window is already hidden) |
| `forms` | | Node editor callbacks, if your nodes have editors (section 7) |
| `notice(text)` | | Show the adapter's whole-graph warning; `nil` clears it |
| `label` | | Prefix for its log lines (default `[graph]`) |
| `movable`, `resizable` | | Default true: the title bar drags the window, the right and bottom edges size it |
| `minWidth`, `minHeight` | | Smallest size when resizing (620, 260) |

`create` returns nil and logs the reason when it cannot start: the adapter lacks a contract field, or the context already holds a graph.

The returned object: `setOpen(bool)`, `place(left, top)`, `update()`, `mouseWheel(up)`, `keyPress(key, isRepeat)`, `shutdown()`, `VERSION`. `Graph`, `S` and `document` are also on it for tests; treat them as private.

## 4. Describe your graph: the adapter

The adapter is the only way the graph learns what anything means. Every controller reads your nodes and wires through it, so a new kind of graph needs no change to the library.

**The contract** is the comment above `ADAPTER_CONTRACT` in `lib/core.lua`: every required field, its arguments and what it returns, then the optional ones. `spec/node_graph/contract_spec.lua` fails if that comment and the list drift apart. `NodeGraph.create` refuses an adapter that lacks a required field, and names the missing fields.

| Group | Fields | The toy's answer (a good first version) |
|---|---|---|
| Kinds and records | `kinds`, `records`, `find`, `layout`, `store` | Lists in its document; `Core.LayoutBands` for layout; `store()` returns its document |
| Ports and wires | `outPorts`, `edges`, `canLink`, `canLinkNew`, `link`, `unlink`, `describeEdge`, `edgeStrength` | One out-port per kind that feeds the next; wires are id lists on the source |
| What a node shows | `rows`, `summary`, `subtitle`, `badge`, `editable`, `form` | A type line and one value; no badge; no forms |
| Creating and changing | `palette`, `create`, `duplicate`, `remove`, `rename`, `connect` | NEW <KIND> per kind; `connect` refuses ("wired by hand") |
| Around the canvas | `inspect`, `syncInspector`, `haystack`, `marks`, `notice` | No inspector; no marks; no notice |
| Optional | `contract`, `markToggle`, `copy`/`paste`, `retypable`/`retype` | `contract = 1` only |

Rules that are easy to miss:

- **Keys** are `"<kind>:<id>"` (`Core.Key`). Ids must be unique within a kind and should be plain identifiers, because they become element ids (`ng-gnode-<kind>-<id>`).
- **Kind names** are plain words and shared by every graph in the game (they become CSS classes). Pick names another tool is unlikely to use.
- **`rename` returns the new id** (or nil if refused); the graph then moves the node's position and selection itself.
- **`store()`** is where the graph keeps its own data for your graph: groupings in `store.comments`, positions in `store.layout`. Return your document and they save with it.
- **`kinds[i].label` / `short`** name the palette and FIND chips (defaults: the kind in capitals, and its first three letters).
- **`contract = 1`**: declare the version you wrote against. A mismatch is logged, not refused.
- **`markToggle = { label = "CYCLES", title = "..." }`** adds a toolbar chip that shows `marks().cycle`. Without it the chip is hidden and nothing is drawn as a cycle.

## 5. Colours: `kinds.rcss`

Every node carries the class `.ng-node-<kind>`. To colour your kinds, copy the toy's block in `kinds.rcss` (nine rules per kind: border, hover, title, title bar, port dot, expand stub, minimap dot, palette row, FIND chip) under a heading for your tool, and rename the kind. Keep `kinds[i].tint` equal to the border colour; the wires are graded in it. A kind with no rules is grey.

Why a separate file: `node_graph.rml` links `node_graph.rcss`, then `kinds.rcss`, then `node_graph_after.rcss`. The selected, found, dim, cycle and hover rules have the same specificity as a kind's rules and win by coming later. Inline colours would beat them all, which is why kinds are not coloured from Lua.

## 6. One graph per RmlUi context

`node_graph.rml` binds a fixed data-model name, `node_graph_model`. Recoil loads RML only from files, so the name cannot vary per graph, and a context can hold one graph at a time. Give each graph its own context, as the demo does. Two consequences:

- `.github/RmlUi-instructions.md` prefers the shared context; this is a known deviation, forced by the fixed name.
- A widget-created context draws under the "shared" one, so shared panels can cover your graph window.

If this becomes a real problem, the fix is in the library (for example a few pre-made RML files with different model names), not in your tool.

## 7. Node editors (optional)

A node opens (the stub on its bottom edge) when `editable(kind)` is true. If `form(host, kind, id)` returns a bound form host, the open node edits every parameter in place. The canvas draws the controls itself (`ng-node-input`, `ng-node-select`, ...); your `forms` callbacks (`formFocus`, `formCommit`, `formKey`, `formToggle`, `formSelect`, `formPick`, `formRemove`) receive the edits. Without forms, an open node shows `rows` read-only. The Mission Editor is the only user of forms so far; expect this part of the API to move.

## 8. How this code follows `.github/RmlUi-instructions.md`, and where it does not

| Instructions | In the graph |
|---|---|
| The model is king | Toolbar chips, flags, labels, kind chips and window visibility are bound (`data-class-*`, `data-event-*`, `data-for`, `data-rml`) |
| Register before load | The whole model is built before the document loads. Model functions forward to `Graph.bound.*`, because Recoil will not add or replace a model function after `OpenDataModel` |
| Lifecycle | Model opened once, then the document, `ReloadStyleSheet()`, then wiring; shutdown closes the document and removes the model. Renders are deferred to `update()`, never run inside an event |
| Performance | Model values are assigned only when they change |
| Shared context | Deviation, section 6 |
| **The escape hatch** | The canvas. Nodes and wires are generated markup, rebuilt on render: hundreds of positioned boxes whose geometry is computed in Lua. Inside it, sizes are **px, not dp** (the layout must match the drawn boxes exactly), zoom is **built into every size** rather than applied with a transform, and a zoom glide scales the last canvas with one transform and then rebuilds once, crossfading a ghost copy over the snap |

## 9. Traps

| Trap | What to do |
|---|---|
| Any `.lua` directly in `RmlWidgets/<folder>/` is loaded as a widget | Keep library Lua in a subfolder (`lib/`, `adapters/`) |
| A data-model array does not read back as a Lua table | Keep a plain copy, or check the DOM in tests |
| Bound classes apply on the next update | In tests, act in one step and assert in the next |
| Rebuilding the element a click is being dispatched to crashes the engine | Only raise a render flag in handlers; render in `update()` |
| `Graph.*` edits do not render by themselves | Call `graph.Graph.host.render()` after driving the graph from a test |
| `RmlUi.key_identifier` is a function here | `RmlUi.key_identifier().RETURN`; resolve it once |
| Enter in a focused field never reaches `widget:KeyPress` | Handled in the field's RmlUi `keydown` (the library does this) |
| RmlUi's `dblclick` is unreliable on the canvas | Double-clicks are timed (`Graph.isDoubleClick`) |
| A synthetic `Click()` pair on an unselected node lands the second click on a dead element | In tests, select first, wait past 0.4 s, then double-click |
| RmlUi wraps text only at spaces | The overview measures ids and fits them on one line |
| `data-if` hides, it does not remove | Guard callbacks by what the row really is |
| Never write `event` in a data expression | The event arrives as the callback's first argument anyway |
| Text and box edges wobble during the zoom glide | RmlUi's generated textures are nearest-filtered in Recoil; an engine fix exists locally and is not filed |

## 10. Changing the library

Everything that uses the graph lives in this repo, so a change to the library is tested against every tool that uses it, in the same PR.

1. Keep the public surface stable: `NodeGraph.create` options, the object it returns, the adapter contract, the `ng-` class names that `kinds.rcss` rules use.
2. **A new adapter field is optional**, with a default in the library, so existing adapters keep working. Document it under OPTIONAL in `lib/core.lua`.
3. Removing or changing the meaning of a required field is a **breaking change**: bump `CONTRACT`, update every adapter in the tree in the same PR, and say what adapter authors must do in the changelog.
4. Bump `VERSION` (semver) and add a line to `doc/NodeGraph-changelog.md`, tagged `contract` when adapter authors have to act.
5. Add your adapter to `ADAPTERS` in `spec/node_graph/contract_spec.lua`, so a library change that breaks it fails CI.
6. Run the checks below.

## 11. Testing

- **Specs**: `spec/node_graph/core_spec.lua` (geometry, layout) and `contract_spec.lua` (the contract comment matches the list; every adapter in `ADAPTERS` supplies every field and declares the current contract; the toy's behaviour). They run in CI with the other busted specs.
- **Live**: enable **Node Graph Probe** (F11) in any game. It enables the demo, checks the nodes, wires, chips, window grips and selection, cuts a wire through a real hit test, takes a screenshot, and prints `[node graph probe] verdict: N passed, M failed`. With the modoption `node_graph_probe=1` it also quits, for scripted runs.
- After a live run, the log should have no `Could not add data-` or `Error in data expression` lines. A refused binding is logged only as a warning.
- Not covered by the probe: dragging and resizing the window (they read the real mouse). Try them by hand in the demo.
