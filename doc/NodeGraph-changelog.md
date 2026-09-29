# Node Graph changelog

One line per change to `luaui/RmlWidgets/node_graph/`. **contract** marks a change adapter authors have to act on. Guide: `doc/NodeGraph.md`.

## 1.1.0 (contract 1)

Ported from the Mission Editor's UX pass (2026-09-29). No adapter changes; one host change.

- **host** Wires are drawn on the GPU into one texture under the nodes (`lib/ctl/wires.lua`), instead of a chain of rotated elements per wire. Call `graph.draw()` from `widget:DrawScreen`. On the editor's 113-node graph this took the canvas from 4178 to 1490 elements and the idle frame from 21 to 10 ms.
- `graph.render({ graph = "selection" })` relights a selection changed from outside the graph instead of rebuilding the canvas.
- The window resizes from every edge and corner; west and north edges move it so the opposite edge stays put. Corners show the diagonal resize cursor for their angle.
- A window drag or resize ends when the button is let go anywhere: over the map, another window, or outside the game window. It used to stay stuck to the pointer.
- FIT frames the graph without moving any node. RELAYOUT is the one button that moves nodes.
- Ports on a hovered node are shown in the node kind's colour, dimmed until hovered, instead of near-black. A new kind in `kinds.rcss` now has eleven rules: the last two are its port colours.

## 1.0.0 (contract 1)

First release as a library, taken from the Mission Editor's node graph.

- `NodeGraph.create{...}` hosts a complete graph in any widget: canvas, palette, FIND, groupings, minimap, animated zoom, KEYS card.
- The window moves (title bar) and resizes (right and bottom edges) by itself; `movable`, `resizable`, `minWidth`, `minHeight`.
- **contract** The adapter contract is documented in `lib/core.lua`; `create` refuses an adapter that lacks a required field and names it.
- **contract** Optional adapter fields: `contract` (version check), `markToggle` (a toolbar chip for `marks().cycle`), `copy`/`paste`, `retypable`/`retype`; `marks()` may also return `fade`, `dim` and `chips`.
- Node kinds are coloured in `kinds.rcss`, linked between the base sheet and the state rules.
- Class and id prefix `ng-`; data model `node_graph_model` (one graph per RmlUi context).
- Checks: `spec/node_graph/` and the Node Graph Probe widget.
