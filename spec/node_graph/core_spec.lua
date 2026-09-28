require("spec_helper")

-- The node graph's pure core (luaui/RmlWidgets/node_graph/lib/core.lua): keys, geometry, hit tests,
-- layout. Keys in these specs name made-up kinds; the core does not care what a kind means.
local Graph = VFS.Include("luaui/RmlWidgets/node_graph/lib/core.lua")

describe("node_graph.core", function()
	describe("keys", function()
		it("round-trips a kind and an id, keeping colons inside the id", function()
			assert.are.equal("emitter:muzzle", Graph.Key("emitter", "muzzle"))
			local kind, id = Graph.SplitKey("spawner:a:b")
			assert.are.equal("spawner", kind)
			assert.are.equal("a:b", id)
		end)
	end)

	describe("geometry", function()
		local G = Graph.GRAPH

		it("keeps nodeHeight equal to a shut node's measured height, as the constants promise", function()
			assert.are.equal(G.nodeHeight, Graph.MeasureNode(0, 1, false))
			assert.are.equal(G.nodeHeight, Graph.MeasureNode(5, 1, false))
		end)

		it("grows an open node by its rows and a many-port node by its ports", function()
			assert.are.equal(G.nodeHeight + 2 * G.paramRowPx, Graph.MeasureNode(3, 1, true))
			-- Editor rows are their own height; the expand bar is there either way.
			assert.are.equal(G.nodeHeight - G.paramRowPx + 3 * G.editRowPx, Graph.MeasureNode(3, 1, true, G.editRowPx))
			assert.is_true(G.nodeHeight % 2 == 0 and G.editRowPx % 2 == 0, "anchors sit at half a height")
			assert.is_true(Graph.MeasureNode(0, 6, false) >= G.padY * 2 + 6 * G.portPitchPx)
		end)

		it("answers the collapsed height for a node nobody has measured", function()
			assert.are.equal(G.nodeHeight, Graph.HeightOf(nil, "trigger:x"))
			assert.are.equal(120, Graph.HeightOf({ ["trigger:x"] = 120 }, "trigger:x"))
		end)

		it("spreads several ports evenly and puts a lone one mid-height", function()
			assert.are.equal(50, Graph.PortOffset(1, 1, 100))
			local first, last = Graph.PortOffset(1, 6, 200), Graph.PortOffset(6, 6, 200)
			assert.is_true(first > G.padY and last < 200 - G.padY and first < last)
			local ports =
				{ { name = "a" }, { name = "b" }, { name = "c" }, { name = "d" }, { name = "e" }, { name = "last" } }
			assert.are.equal(Graph.PortOffset(6, 6, 200), Graph.PortY(200, ports, "out", "last"))
			assert.are.equal(100, Graph.PortY(200, ports, "in", "last"))
		end)

		it("anchors connectors on the node's right and left edges", function()
			local x, y = Graph.OutAnchor({ x = 10, y = 20 }, 80)
			assert.are.equal(10 + G.nodeWidth, x)
			assert.are.equal(60, y)
			assert.are.same({ 10, 60 }, { Graph.InAnchor({ x = 10, y = 20 }, 80) })
		end)

		it("draws a curve that starts and ends exactly on its anchors", function()
			local points = Graph.CurveBetween(0, 0, 300, 120)
			assert.are.equal(0, points[1].x)
			assert.are.equal(0, points[1].y)
			assert.is_true(math.abs(points[points.n + 1].x - 300) < 1e-9)
			assert.is_true(math.abs(points[points.n + 1].y - 120) < 1e-9)
			assert.is_true(points.n >= Graph.EDGE.minSegments and points.n <= Graph.EDGE.maxSegments)
			assert.is_nil(Graph.CurveBetween(5, 5, 5.5, 5))
		end)

		it("measures distance to a segment, clamped to its ends", function()
			assert.are.equal(3, Graph.PointToSegment(5, 3, 0, 0, 10, 0))
			assert.are.equal(5, Graph.PointToSegment(13, 4, 0, 0, 10, 0))
		end)

		it("finds the node under a point using measured heights", function()
			local layout = { ["trigger:a"] = { x = 0, y = 0 }, ["trigger:b"] = { x = 500, y = 0 } }
			local heights = { ["trigger:a"] = 200 }
			assert.are.equal("trigger:a", Graph.NodeAt(layout, heights, 10, 150))
			assert.is_nil(Graph.NodeAt(layout, {}, 10, 150))
			assert.are.equal("trigger:b", Graph.NodeAt(layout, heights, 510, 10))
		end)

		it("with a pad, lands a drop on the port dot just outside a node's box", function()
			local layout = { ["action:a"] = { x = 100, y = 0 } }
			-- The input dot is centred on the left edge: half of it is at x < 100.
			assert.is_nil(Graph.NodeAt(layout, {}, 95, 20))
			assert.are.equal("action:a", Graph.NodeAt(layout, {}, 95, 20, 8))
			assert.is_nil(Graph.NodeAt(layout, {}, 80, 20, 8))
		end)

		it("with a pad, the nearest box wins where two padded boxes overlap", function()
			local w = Graph.GRAPH.nodeWidth
			local layout = { ["trigger:a"] = { x = 0, y = 0 }, ["trigger:b"] = { x = w + 20, y = 0 } }
			-- 4 px right of a, 16 px left of b: both are within a 30 px pad.
			assert.are.equal("trigger:a", Graph.NodeAt(layout, {}, w + 4, 10, 30))
			assert.are.equal("trigger:b", Graph.NodeAt(layout, {}, w + 16, 10, 30))
		end)

		it("picks the nearest edge within a SCREEN radius, whatever the zoom", function()
			local edges = { { from = "a", to = "b" }, { from = "c", to = "d" } }
			local points = {
				{ n = 1, { x = 0, y = 0 }, { x = 100, y = 0 } },
				{ n = 1, { x = 0, y = 20 }, { x = 100, y = 20 } },
			}
			local edge, index = Graph.EdgeAt(edges, points, 1, 50, 4)
			assert.are.equal(1, index)
			assert.are.equal("a", edge.from)
			assert.is_nil(Graph.EdgeAt(edges, points, 1, 50, 10, 9))
			-- At half zoom a 9px screen radius covers 18 canvas units.
			assert.are.equal(1, select(2, Graph.EdgeAt(edges, points, 0.5, 50, 9, 9)))
		end)

		it("bounds a set of nodes, and answers nil for none", function()
			local layout = { ["trigger:a"] = { x = 10, y = 20 }, ["trigger:b"] = { x = 400, y = 300 } }
			assert.are.same(
				{ 10, 20, 400 + G.nodeWidth, 300 + G.nodeHeight },
				{ Graph.BoundsOf(layout, nil, { "trigger:a", "trigger:b" }) }
			)
			assert.is_nil(Graph.BoundsOf(layout, nil, { "trigger:gone" }))
		end)

		it("counts a node as inside a grouping only when it is wholly inside", function()
			local layout = { ["trigger:in"] = { x = 50, y = 50 }, ["trigger:half"] = { x = 50, y = 500 } }
			local frame = { x = 0, y = 0, w = 600, h = 520 }
			local members = Graph.CommentMembers(layout, nil, frame)
			assert.are.equal(1, #members)
			assert.are.equal("trigger:in", members[1].key)
			assert.are.equal(50, members[1].dx)
		end)

		local function bands(firstEmpty)
			return {
				{ kind = "emitter", records = firstEmpty and {} or { { id = "e1" } } },
				{ kind = "spawner", records = { { id = "s1" }, { id = "s2" } } },
				{ kind = "particle", records = { { id = "p1" } } },
			}
		end

		it("lays bands out left to right in the order given", function()
			local layout = Graph.LayoutBands(bands(), nil)
			assert.is_true(layout["emitter:e1"].x < layout["spawner:s1"].x)
			assert.is_true(layout["spawner:s1"].x < layout["particle:p1"].x)
			assert.are.equal(layout["spawner:s1"].x, layout["spawner:s2"].x)
		end)

		it("reserves no room for an empty band unless it asks", function()
			local layout = Graph.LayoutBands(bands(true), nil)
			assert.are.equal(G.padding, layout["spawner:s1"].x)
			local reserved = bands(true)
			reserved[1].reserve = true
			assert.are.equal(G.padding + G.columnGap, Graph.LayoutBands(reserved, nil)["spawner:s1"].x)
		end)

		it("spaces a band by its tallest node so tall nodes never overlap", function()
			local layout = Graph.LayoutBands(bands(), function(kind)
				return kind == "spawner" and 300 or G.nodeHeight
			end)
			assert.is_true(layout["spawner:s2"].y - layout["spawner:s1"].y >= 300)
		end)

		it("normalises the layout to the padding and carries the groupings with it", function()
			local layout = { ["trigger:a"] = { x = 100, y = 60 } }
			local comments = { { x = 90, y = 50 } }
			local dx, dy = Graph.NormaliseLayout(layout, comments)
			assert.are.equal(G.padding - 100, dx)
			assert.are.equal(G.padding - 60, dy)
			assert.are.equal(G.padding, layout["trigger:a"].x)
			assert.are.equal(90 + dx, comments[1].x)
			assert.is_nil(Graph.NormaliseLayout(layout, comments))
			assert.is_nil(Graph.NormaliseLayout({}, nil))
		end)
	end)

end)
