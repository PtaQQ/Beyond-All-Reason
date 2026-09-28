# Node Graph changelog

One line per change to `luaui/RmlWidgets/node_graph/`. **contract** marks a change adapter authors have to act on. Guide: `doc/NodeGraph.md`.

## 1.0.0 (contract 1)

First release as a library, taken from the Mission Editor's node graph.

- `NodeGraph.create{...}` hosts a complete graph in any widget: canvas, palette, FIND, groupings, minimap, animated zoom, KEYS card.
- The window moves (title bar) and resizes (right and bottom edges) by itself; `movable`, `resizable`, `minWidth`, `minHeight`.
- **contract** The adapter contract is documented in `lib/core.lua`; `create` refuses an adapter that lacks a required field and names it.
- **contract** Optional adapter fields: `contract` (version check), `markToggle` (a toolbar chip for `marks().cycle`), `copy`/`paste`, `retypable`/`retype`; `marks()` may also return `fade`, `dim` and `chips`.
- Node kinds are coloured in `kinds.rcss`, linked between the base sheet and the state rules.
- Class and id prefix `ng-`; data model `node_graph_model` (one graph per RmlUi context).
- Checks: `spec/node_graph/` and the Node Graph Probe widget.
