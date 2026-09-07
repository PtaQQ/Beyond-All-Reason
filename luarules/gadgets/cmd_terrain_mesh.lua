function gadget:GetInfo()
	return {
		name = "Terrain Mesh",
		desc = "Features tagged customParams.terrainmesh own the ground under them: the heightmap follows the mesh's upper surface and turns near-indestructible",
		author = "PtaQ",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = -1,
		enabled = true,
	}
end

if not gadgetHandler:IsSyncedCode() then
	-- Unsynced half. The ground drawer only re-tessellates on request, so a
	-- synced stamp leaves the old, coarser triangulation lying across the new
	-- cliff: its slope then spans more than the heightmap's one cell and pokes
	-- out of the mesh's walls. The terraform brush forces the refresh after its
	-- own edits; this does the same for a few draw frames after every stamp,
	-- shadow mesh included.
	local TESS_DIRTY_FRAMES = 12
	local tessDirtyFrames = 0
	local spForceTesselationUpdate = Spring.ForceTesselationUpdate

	local function onTerrainMeshChanged()
		tessDirtyFrames = TESS_DIRTY_FRAMES
		return true -- consumed; no other gadget needs the broadcast
	end

	function gadget:Initialize()
		gadgetHandler:AddSyncAction("TerrainMeshChanged", onTerrainMeshChanged)
	end

	function gadget:Shutdown()
		gadgetHandler:RemoveSyncAction("TerrainMeshChanged")
	end

	function gadget:DrawWorld()
		if tessDirtyFrames > 0 then
			spForceTesselationUpdate(true, true)
			tessDirtyFrames = tessDirtyFrames - 1
		end
	end

	return
end

-- A terrain mesh is an ordinary feature (placed, moved, tilted, lifted and
-- removed with every Feature Placer control) whose model is treated as a piece
-- of the map: once it lands, every heightmap vertex the mesh covers is set to
-- the height of the mesh's upper surface, so units path and drive over the
-- model exactly, and the typemap cells under it switch to a terrain type with
-- an enormous hardness, so explosions leave the ground alone. Removing the
-- feature gives the ground back. The mesh geometry is read straight from the
-- s3o, so a rampart, wall or ramp built in any 3D package works as long as
-- its def carries the tag; nothing here knows the block shape.
--
-- Why the feature must be pinned: CFeature::UpdatePosition lifts any feature
-- the ground rises over ("adjusting vertical speed won't help if the ground
-- moved and buried us"), unmasked, and CFeatureHandler::TerrainChanged puts
-- every feature in a changed area back in the update queue. Raising the ground
-- to a block's own top would therefore pop the block onto that top the next
-- frame, and the re-stamp would chase it up forever. A MoveCtrl with
-- enabled = true and zero vectors takes the raw-movement branch instead,
-- which never consults the ground.

local SQ = Game.squareSize
local MAPX, MAPZ = Game.mapSizeX, Game.mapSizeZ
local VX_MAX, VZ_MAX = MAPX / SQ, MAPZ / SQ -- highest heightmap vertex index per axis

-- rawHardness = map.hardness * terrainType.hardness and crater depth divides by
-- the 3x3-weighted sum of it (BasicMapDamage.cpp), so 1000 leaves a big bomb's
-- crater under a tenth of an elmo and the reconcile below takes even that back.
local HARD_HARDNESS = 1000
local HARD_TT_NAME = "terrainmesh"

local HEIGHT_EPSILON = 0.05 -- reconcile tolerance, elmos
local RECONCILE_BUDGET = 1500 -- height samples per frame
local TRANSFORM_CHECK_PERIOD = 10 -- frames

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local huge = math.huge

local spGetGroundHeight = Spring.GetGroundHeight
local spSetHeightMap = Spring.SetHeightMap
local spSetHeightMapFunc = Spring.SetHeightMapFunc
local spGetFeaturePosition = Spring.GetFeaturePosition
local spGetFeatureDirection = Spring.GetFeatureDirection
local spGetFeatureDefID = Spring.GetFeatureDefID
local spValidFeatureID = Spring.ValidFeatureID
local spSetFeatureMoveCtrl = Spring.SetFeatureMoveCtrl
local spSetMapSquareTerrainType = Spring.SetMapSquareTerrainType
local spGetTerrainTypeData = Spring.GetTerrainTypeData
-- The engine reads eight arguments (hardness is the sixth); the library def
-- only declares the four speed multipliers.
---@type fun(typeIndex: integer, tankSpeed: number, kbotSpeed: number, hoverSpeed: number, shipSpeed: number, hardness: number, receiveTracks: boolean, name: string): boolean?
local spSetTerrainTypeData = Spring.SetTerrainTypeData
local spEcho = Spring.Echo
local spSendToUnsynced = SendToUnsynced

-- Scratch tables indexed with computed keys in hot loops: the analyzer's index
-- typing has no stable answer for those, so it is handed `any`.
---@return any
local function scratch()
	return {}
end

----------------------------------------------------------------
-- Defs
----------------------------------------------------------------
-- defID -> { inset = elmos, sink = elmos }. The inset is how far past a vertex
-- the mesh must also cover before that vertex is raised: with the default half
-- cell, the terrain slope up to the top surface lands INSIDE the mesh's side
-- walls instead of poking out of them. The sink (default 0) lowers the stamped
-- ground below the mesh surface; the depth tie between the plateau and the top
-- face is resolved on the render side instead (cus_gl4 draws the terrainmesh
-- bin with a polygon offset), so units stand exactly on the model.
---@type table
local meshDefs = {} -- defID -> { inset = elmos, name = defName }
for defID, def in pairs(FeatureDefs) do
	local cp = def.customParams
	if cp and cp.terrainmesh and cp.terrainmesh ~= "0" and cp.terrainmesh ~= "false" then
		local inset = tonumber(cp.terrainmesh_inset) or SQ / 2
		-- the coverage grid is SQ / inset samples per heightmap cell, so keep it integral
		if inset >= SQ then
			inset = SQ
		elseif inset >= SQ / 2 then
			inset = SQ / 2
		elseif inset >= SQ / 4 then
			inset = SQ / 4
		else
			inset = SQ / 8
		end
		local sink = tonumber(cp.terrainmesh_sink) or 0
		meshDefs[defID] = { inset = inset, sink = sink, name = def.name }
	end
end

----------------------------------------------------------------
-- s3o reader
----------------------------------------------------------------
-- Spring's Lua is 5.1: no string.unpack, so the binary is decoded by hand.
local byte = string.byte

local function readI32(s, o)
	local b1, b2, b3, b4 = byte(s, o, o + 3)
	local v = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	if v >= 2147483648 then
		v = v - 4294967296
	end
	return v
end

local function readF32(s, o)
	local b1, b2, b3, b4 = byte(s, o, o + 3)
	local sign = (b4 >= 128) and -1 or 1
	local exp = (b4 % 128) * 2 + floor(b3 / 128)
	local mant = (b3 % 128) * 65536 + b2 * 256 + b1
	if exp == 0 then
		if mant == 0 then
			return 0
		end
		return sign * mant * 2 ^ -149
	elseif exp == 255 then
		return (mant == 0) and (sign * huge) or (0 / 0)
	end
	return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

-- Header (byte offsets): magic 0..11, version 12, radius 16, height 20,
-- mid 24/28/32, rootPiece 36, collisionData 40, texture1 44, texture2 48.
-- Piece: name 0, numChildren 4, children 8, numVertices 12, vertices 16,
-- vertexType 20, primitiveType 24, vertexTableSize 28, vertexTable 32,
-- collisionData 36, offset 40/44/48. Vertex: pos, normal, uv = 32 bytes.
local VERTEX_SIZE = 32

-- Returns { vx = {}, vy = {}, vz = {} (model space, piece offsets applied),
-- tris = { i1, i2, i3, ... } (1-based) } or nil, err.
local function parseS3O(data)
	if not data or #data < 52 or data:sub(1, 11) ~= "Spring unit" then
		return nil, "not an s3o"
	end
	if readI32(data, 13) ~= 0 then
		return nil, "unsupported s3o version"
	end
	---@type table<integer, number>
	local vx = {}
	---@type table<integer, number>
	local vy = {}
	---@type table<integer, number>
	local vz = {}
	---@type table<integer, integer>
	local tris = {}
	local mesh = { vx = vx, vy = vy, vz = vz, tris = tris }
	---@type table<integer, boolean>
	local seen = {}

	local function walk(pieceOfs, px, py, pz)
		if seen[pieceOfs] or pieceOfs < 0 or pieceOfs + 52 > #data then
			return
		end
		seen[pieceOfs] = true
		local o = pieceOfs + 1
		local numChildren = readI32(data, o + 4)
		local childrenOfs = readI32(data, o + 8)
		local numVerts = readI32(data, o + 12)
		local vertsOfs = readI32(data, o + 16)
		local primType = readI32(data, o + 24)
		local tableSize = readI32(data, o + 28)
		local tableOfs = readI32(data, o + 32)
		local ox = px + readF32(data, o + 40)
		local oy = py + readF32(data, o + 44)
		local oz = pz + readF32(data, o + 48)

		local base = #vx
		for i = 0, numVerts - 1 do
			local vo = vertsOfs + i * VERTEX_SIZE + 1
			vx[base + i + 1] = ox + readF32(data, vo)
			vy[base + i + 1] = oy + readF32(data, vo + 4)
			vz[base + i + 1] = oz + readF32(data, vo + 8)
		end

		---@type table<integer, integer>
		local idx = {}
		for i = 0, tableSize - 1 do
			idx[i + 1] = readI32(data, tableOfs + i * 4 + 1)
		end
		local function emit(a, b, c)
			if a >= 0 and b >= 0 and c >= 0 and a < numVerts and b < numVerts and c < numVerts then
				local n = #tris
				tris[n + 1] = base + a + 1
				tris[n + 2] = base + b + 1
				tris[n + 3] = base + c + 1
			end
		end
		if primType == 0 then
			for i = 1, tableSize - 2, 3 do
				emit(idx[i], idx[i + 1], idx[i + 2])
			end
		elseif primType == 1 then
			-- triangle strips, -1 restarts a strip
			local run = 0
			for i = 1, tableSize do
				if idx[i] < 0 then
					run = 0
				else
					run = run + 1
					if run >= 3 then
						emit(idx[i - 2], idx[i - 1], idx[i])
					end
				end
			end
		elseif primType == 2 then
			for i = 1, tableSize - 3, 4 do
				emit(idx[i], idx[i + 1], idx[i + 2])
				emit(idx[i], idx[i + 2], idx[i + 3])
			end
		end

		for c = 0, numChildren - 1 do
			walk(readI32(data, childrenOfs + c * 4 + 1), ox, oy, oz)
		end
	end

	walk(readI32(data, 37), 0, 0, 0)
	if #tris == 0 then
		return nil, "no triangles"
	end
	return mesh
end

---@type table<integer, (table|false)?>
local meshCache = {} -- defID -> mesh | false (failed)

local function getMesh(defID)
	local cached = meshCache[defID]
	if cached ~= nil then
		return cached or nil
	end
	local def = FeatureDefs[defID]
	local path = tostring(def and def.modelpath or "")
	---@type string?
	local data = nil
	if path ~= "" then
		data = VFS.LoadFile(path, VFS.ZIP) or VFS.LoadFile(path)
	end
	local mesh, err = parseS3O(data)
	if not mesh then
		spEcho(
			"[Terrain Mesh] cannot read model for "
				.. tostring(def and def.name)
				.. " ("
				.. tostring(path)
				.. "): "
				.. tostring(err)
		)
		meshCache[defID] = false
		return nil
	end
	meshCache[defID] = mesh
	return mesh
end

----------------------------------------------------------------
-- Rasteriser: mesh + feature transform -> raised heightmap vertices
----------------------------------------------------------------
-- The engine composes a feature's matrix as (pos, -rightdir, updir, frontdir)
-- and GetFeatureDirection hands back exactly those three columns (front, then
-- the X column, then up), so world = pos + X * vx + Y * vy + Z * vz with no
-- Euler convention to get wrong.
local function rasterize(mesh, px, py, pz, xdx, xdy, xdz, ydx, ydy, ydz, zdx, zdy, zdz, inset)
	local sub = SQ / inset -- coverage samples per heightmap cell
	local n = #mesh.vx
	---@type table<integer, number>
	local wx = {}
	---@type table<integer, number>
	local wy = {}
	---@type table<integer, number>
	local wz = {}
	---@type number
	local minX, maxX, minZ, maxZ = huge, -huge, huge, -huge
	local mvx, mvy, mvz = mesh.vx, mesh.vy, mesh.vz
	for i = 1, n do
		local x, y, z = mvx[i], mvy[i], mvz[i]
		local ox = px + xdx * x + ydx * y + zdx * z
		local oy = py + xdy * x + ydy * y + zdy * z
		local oz = pz + xdz * x + ydz * y + zdz * z
		wx[i], wy[i], wz[i] = ox, oy, oz
		if ox < minX then
			minX = ox
		end
		if ox > maxX then
			maxX = ox
		end
		if oz < minZ then
			minZ = oz
		end
		if oz > maxZ then
			maxZ = oz
		end
	end

	-- coverage grid in fine (inset-spaced) samples, clamped to the map
	local gx1 = floor(max(0, minX / inset - 1))
	local gx2 = floor(min(VX_MAX * sub, maxX / inset + 2))
	local gz1 = floor(max(0, minZ / inset - 1))
	local gz2 = floor(min(VZ_MAX * sub, maxZ / inset + 2))
	if gx2 < gx1 or gz2 < gz1 then
		return nil
	end
	local gw = gx2 - gx1 + 1
	local cover = scratch() -- flat, max height or nil

	local tris = mesh.tris
	for t = 1, #tris - 2, 3 do
		local a, b, c = tris[t], tris[t + 1], tris[t + 2]
		local ax, az, bx, bz, cx, cz = wx[a], wz[a], wx[b], wz[b], wx[c], wz[c]
		local ay, by, cy = wy[a], wy[b], wy[c]
		local det = (bx - ax) * (cz - az) - (cx - ax) * (bz - az)
		if abs(det) > 1e-6 then
			local invDet = 1 / det
			local tx1 = max(gx1, floor(min(ax, bx, cx) / inset))
			local tx2 = min(gx2, floor(max(ax, bx, cx) / inset) + 1)
			local tz1 = max(gz1, floor(min(az, bz, cz) / inset))
			local tz2 = min(gz2, floor(max(az, bz, cz) / inset) + 1)
			for gz = tz1, tz2 do
				local pzw = gz * inset
				local row = (gz - gz1) * gw
				for gx = tx1, tx2 do
					local pxw = gx * inset
					-- barycentric with a tolerance so samples on shared edges count
					local l1 = ((bx - pxw) * (cz - pzw) - (cx - pxw) * (bz - pzw)) * invDet
					local l2 = ((cx - pxw) * (az - pzw) - (ax - pxw) * (cz - pzw)) * invDet
					local l3 = 1 - l1 - l2
					if l1 >= -1e-4 and l2 >= -1e-4 and l3 >= -1e-4 then
						local h = l1 * ay + l2 * by + l3 * cy
						local idx = row + (gx - gx1) + 1
						local old = cover[idx]
						if not old or h > old then
							cover[idx] = h
						end
					end
				end
			end
		end
	end

	-- a heightmap vertex is raised when the mesh covers it AND every fine
	-- sample within +/- inset around it (the whole 3x3 neighbourhood)
	---@type table<integer, integer>
	local xs = {}
	---@type table<integer, integer>
	local zs = {}
	---@type table<integer, number>
	local hs = {}
	local count = 0
	local vx1 = floor((gx1 + sub - 1) / sub)
	local vx2 = floor(gx2 / sub)
	local vz1 = floor((gz1 + sub - 1) / sub)
	local vz2 = floor(gz2 / sub)
	for vz = vz1, vz2 do
		local gz = vz * sub
		for vx = vx1, vx2 do
			local gx = vx * sub
			local center = cover[(gz - gz1) * gw + (gx - gx1) + 1]
			if center then
				local ok = true
				for dz = -1, 1 do
					local z = gz + dz
					if z < gz1 or z > gz2 then
						ok = false
						break
					end
					local row = (z - gz1) * gw
					for dx = -1, 1 do
						local x = gx + dx
						if x < gx1 or x > gx2 or not cover[row + (x - gx1) + 1] then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
				end
				if ok then
					count = count + 1
					xs[count], zs[count], hs[count] = vx, vz, center
				end
			end
		end
	end
	if count == 0 then
		return nil
	end
	return { xs = xs, zs = zs, hs = hs, n = count, x1 = vx1, x2 = vx2, z1 = vz1, z2 = vz2 }
end

----------------------------------------------------------------
-- Heightmap helpers
----------------------------------------------------------------
---@type table<integer, integer>
local pendXs = {}
---@type table<integer, integer>
local pendZs = {}
---@type table<integer, number>
local pendHs = {}
local pendN = 0
local function applyWorker()
	for i = 1, pendN do
		spSetHeightMap(pendXs[i] * SQ, pendZs[i] * SQ, pendHs[i])
	end
end

local function applyHeights(xs, zs, hs, n)
	if n == 0 then
		return
	end
	pendXs, pendZs, pendHs, pendN = xs, zs, hs, n
	spSetHeightMapFunc(applyWorker)
	pendXs, pendZs, pendHs, pendN = {}, {}, {}, 0
	-- the unsynced half re-tessellates the ground drawer for a few frames
	spSendToUnsynced("TerrainMeshChanged")
end

local function readHeights(xs, zs, n)
	---@type table<integer, number>
	local out = {}
	for i = 1, n do
		out[i] = spGetGroundHeight(xs[i] * SQ, zs[i] * SQ)
	end
	return out
end

-- Fill a removed stamp's vertices from the ring around them (Gauss-Seidel
-- relaxation seeded with the ring mean) when the pre-stamp ground is unknown:
-- after a project load the heightmap arrived already stamped, and after a
-- /luarules reload the snapshots are gone. Flat ground comes back exactly flat;
-- slopes come back as a smooth membrane, which is what a removed block should
-- leave behind.
local function relaxFill(stamp)
	local x1, x2 = floor(max(0, stamp.x1 - 1)), floor(min(VX_MAX, stamp.x2 + 1))
	local z1, z2 = floor(max(0, stamp.z1 - 1)), floor(min(VZ_MAX, stamp.z2 + 1))
	local w, hgt = x2 - x1 + 1, z2 - z1 + 1
	local h = scratch()
	local inside = scratch()
	for vz = z1, z2 do
		local row = (vz - z1) * w
		for vx = x1, x2 do
			h[row + (vx - x1) + 1] = spGetGroundHeight(vx * SQ, vz * SQ)
		end
	end
	local xs, zs, n = stamp.xs, stamp.zs, stamp.n
	local cells = scratch()
	for i = 1, n do
		local idx = (zs[i] - z1) * w + (xs[i] - x1) + 1
		inside[idx] = true
		cells[i] = idx
	end
	-- seed: mean of the ring (outside neighbours of inside cells)
	local sum, cnt = 0.0, 0
	local function ring(idx)
		if not inside[idx] then
			sum = sum + h[idx]
			cnt = cnt + 1
		end
	end
	for i = 1, n do
		local idx = cells[i]
		local cx, cz = xs[i], zs[i]
		if cx > x1 then
			ring(idx - 1)
		end
		if cx < x2 then
			ring(idx + 1)
		end
		if cz > z1 then
			ring(idx - w)
		end
		if cz < z2 then
			ring(idx + w)
		end
	end
	local seed = (cnt > 0) and (sum / cnt) or h[cells[1]]
	for i = 1, n do
		h[cells[i]] = seed
	end
	local iters = min(500, 4 * max(w, hgt))
	for _ = 1, iters do
		for i = 1, n do
			local idx = cells[i]
			local cx, cz = xs[i], zs[i]
			local l = (cx > x1) and h[idx - 1] or h[idx]
			local r = (cx < x2) and h[idx + 1] or h[idx]
			local u = (cz > z1) and h[idx - w] or h[idx]
			local d = (cz < z2) and h[idx + w] or h[idx]
			h[idx] = (l + r + u + d) * 0.25
		end
	end
	---@type table<integer, number>
	local out = {}
	for i = 1, n do
		out[i] = h[cells[i]]
	end
	return out
end

----------------------------------------------------------------
-- Hard terrain type + typemap bookkeeping
----------------------------------------------------------------
---@type integer?
local hardTT = nil
---@type table<integer, integer?>
local cellRef = {} -- typemap cell key -> stamps referencing it
---@type table<integer, integer?>
local cellPrev = {} -- typemap cell key -> terrain type before us

local function ensureHardType()
	if hardTT then
		return hardTT
	end
	-- reuse our own type across /luarules reloads, else the highest untouched slot
	local pick = 255
	local found = false
	for tti = 255, 1, -1 do
		local _, name = spGetTerrainTypeData(tti)
		if name == HARD_TT_NAME then
			pick = tti
			break
		end
		if not found and (name == "Default" or name == "") then
			pick = tti
			found = true
		end
	end
	hardTT = pick
	-- args: index, tank, kbot, hover, ship, hardness, receiveTracks, name
	spSetTerrainTypeData(hardTT, 1, 1, 1, 1, HARD_HARDNESS, false, HARD_TT_NAME)
	return hardTT
end

local function cellsOf(stamp)
	---@type table<integer, boolean>
	local seen = {}
	---@type table<integer, integer>
	local cells = {}
	local xs, zs = stamp.xs, stamp.zs
	for i = 1, stamp.n do
		local vx, vz = xs[i], zs[i]
		if vx < VX_MAX and vz < VZ_MAX then
			local tx, tz = floor(vx / 2), floor(vz / 2)
			local key = tx * 65536 + tz
			if not seen[key] then
				seen[key] = true
				cells[#cells + 1] = key
			end
		end
	end
	return cells
end

local function hardenCells(cells)
	local tt = ensureHardType()
	for i = 1, #cells do
		local key = cells[i]
		local ref = cellRef[key]
		if ref then
			cellRef[key] = ref + 1
		else
			local tx, tz = floor(key / 65536), key % 65536
			cellPrev[key] = spSetMapSquareTerrainType(tx * 2 * SQ, tz * 2 * SQ, tt)
			cellRef[key] = 1
		end
	end
end

local function softenCells(cells)
	for i = 1, #cells do
		local key = cells[i]
		local ref = cellRef[key]
		if ref then
			if ref > 1 then
				cellRef[key] = ref - 1
			else
				local tx, tz = floor(key / 65536), key % 65536
				spSetMapSquareTerrainType(tx * 2 * SQ, tz * 2 * SQ, cellPrev[key] or 0)
				cellRef[key] = nil
				cellPrev[key] = nil
			end
		end
	end
end

----------------------------------------------------------------
-- Stamps
----------------------------------------------------------------
-- Ordered list: later stamps sit on top of earlier ones. Each carries the
-- raised vertices, the heights they replaced, the transform it was computed
-- from and whether those replaced heights are real ground (`trusted`) or a
-- heightmap that already carried the stamp (project load, reload).
---@type table<integer, table>
local stamps = {} -- array of stamp
---@type table<integer, table?>
local stampByFid = {} -- featureID -> stamp
---@type table<integer, boolean?>
local pending = {} -- featureID -> trustGround (features waiting for their first stamp)

local function lock(fid)
	-- enabled = true with zero velocity/acceleration: the feature never moves
	-- on its own and the ground may rise over it without it popping up
	spSetFeatureMoveCtrl(fid, true, 0, 0, 0, 0, 0, 0)
end

local function readTransform(fid)
	local px, py, pz = spGetFeaturePosition(fid)
	if not px then
		return nil
	end
	local zdx, zdy, zdz, xdx, xdy, xdz, ydx, ydy, ydz = spGetFeatureDirection(fid)
	if not zdx then
		return nil
	end
	return { px, py, pz, xdx, xdy, xdz, ydx, ydy, ydz, zdx, zdy, zdz }
end

local function sameTransform(a, b)
	for i = 1, 12 do
		if abs(a[i] - b[i]) > 1e-4 then
			return false
		end
	end
	return true
end

local function computeStamp(fid)
	local defID = spGetFeatureDefID(fid)
	local info = defID and meshDefs[defID]
	if not info then
		return nil
	end
	local mesh = getMesh(defID)
	if not mesh then
		return nil
	end
	local t = readTransform(fid)
	if not t then
		return nil
	end
	local r = rasterize(mesh, t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10], t[11], t[12], info.inset)
	if not r then
		return nil
	end
	if info.sink ~= 0 then
		local hs = r.hs
		for i = 1, r.n do
			hs[i] = hs[i] - info.sink
		end
	end
	r.fid = fid
	r.transform = t
	return r
end

-- Apply a computed stamp on top of the current terrain.
local function pushStamp(stamp, trusted)
	stamp.before = readHeights(stamp.xs, stamp.zs, stamp.n)
	stamp.trusted = trusted
	applyHeights(stamp.xs, stamp.zs, stamp.hs, stamp.n)
	stamp.cells = cellsOf(stamp)
	hardenCells(stamp.cells)
	stamps[#stamps + 1] = stamp
	stampByFid[stamp.fid] = stamp
end

-- Take the topmost stamp off again. Unwinding (final = false) always puts
-- back exactly what the stamp replaced; a final removal of an untrusted stamp
-- heals the ground by relaxation instead, since what it replaced was itself.
local function popStamp(final)
	local stamp = stamps[#stamps]
	stamps[#stamps] = nil
	stampByFid[stamp.fid] = nil
	softenCells(stamp.cells)
	local ground = (final and not stamp.trusted) and relaxFill(stamp) or stamp.before
	applyHeights(stamp.xs, stamp.zs, ground, stamp.n)
	return stamp
end

-- Remove one stamp from anywhere in the stack: unwind everything above it,
-- take it out, then put the others back so overlapping meshes keep their order.
local function removeStamp(fid)
	local target = stampByFid[fid]
	if not target then
		return
	end
	---@type table<integer, table>
	local unwound = {}
	while stamps[#stamps] ~= target do
		unwound[#unwound + 1] = popStamp(false)
	end
	popStamp(true)
	for i = #unwound, 1, -1 do
		local s = unwound[i]
		if spValidFeatureID(s.fid) then
			local fresh = computeStamp(s.fid)
			if fresh then
				pushStamp(fresh, s.trusted)
			end
		end
	end
end

local function stampFeature(fid, trustGround)
	pending[fid] = nil
	if not spValidFeatureID(fid) then
		removeStamp(fid)
		return false
	end
	lock(fid)
	removeStamp(fid)
	local stamp = computeStamp(fid)
	if not stamp then
		return false
	end
	pushStamp(stamp, trustGround ~= false)
	return true
end

-- Cheap re-assert of an existing stamp's heights, for craters and brush strokes
-- that touched the ground under a mesh.
local function reapply(stamp)
	applyHeights(stamp.xs, stamp.zs, stamp.hs, stamp.n)
end

-- /luarules tmesh          status
-- /luarules tmesh restamp  recompute every stamp
local function chatTMesh(cmd, line, words, playerID)
	if words[1] == "restamp" then
		if not Spring.IsCheatingEnabled() then
			spEcho("[Terrain Mesh] restamp requires /cheat")
			return true
		end
		---@type table<integer, integer>
		local fids = {}
		for i = 1, #stamps do
			fids[i] = stamps[i].fid
		end
		for i = 1, #fids do
			stampFeature(fids[i], true)
		end
		spEcho("[Terrain Mesh] restamped " .. #fids .. " meshes")
		return true
	end
	local verts = 0
	for i = 1, #stamps do
		verts = verts + stamps[i].n
	end
	spEcho(
		string.format("[Terrain Mesh] %d meshes, %d vertices pinned, terrain type %s", #stamps, verts, tostring(hardTT))
	)
	return true
end

----------------------------------------------------------------
-- Callins
----------------------------------------------------------------
local reconcileStamp, reconcileVert = 1, 1

function gadget:Initialize()
	if not next(meshDefs) then
		gadgetHandler:RemoveGadget(self)
		return
	end
	-- Features already on the map (a /luarules reload, or map-authored ones)
	-- have no snapshot to give back, so their ground heals by relaxation.
	local all = Spring.GetAllFeatures()
	for i = 1, #all do
		local fid = all[i]
		local defID = spGetFeatureDefID(fid)
		if defID and meshDefs[defID] then
			lock(fid)
			pending[fid] = false
		end
	end
	-- registered here, not at file scope: the handler needs the gadget loaded first
	gadgetHandler:AddChatAction("tmesh", chatTMesh, "Terrain mesh status / restamp")
	GG.TerrainMesh = {
		isMeshDef = function(defID)
			return meshDefs[defID] ~= nil
		end,
		isMeshFeature = function(fid)
			local defID = spGetFeatureDefID(fid)
			return defID ~= nil and meshDefs[defID] ~= nil
		end,
		-- Re-stamp now (after the caller moved/rotated/lifted the feature).
		-- trustGround = false when the terrain under it is not the ground the
		-- mesh should give back on removal (project load).
		touch = function(fid, trustGround)
			return stampFeature(fid, trustGround)
		end,
		release = function(fid)
			pending[fid] = nil
			removeStamp(fid)
		end,
		count = function()
			return #stamps
		end,
	}
end

function gadget:Shutdown()
	gadgetHandler:RemoveChatAction("tmesh")
	GG.TerrainMesh = nil
end

function gadget:FeatureCreated(featureID, allyTeamID)
	local defID = spGetFeatureDefID(featureID)
	if defID and meshDefs[defID] then
		-- lock before the first sim update; the Feature Placer applies the
		-- final transform after CreateFeature returns and then calls touch(),
		-- which clears this. Anything else that creates one gets stamped on
		-- the next frame, onto ground that is real at runtime.
		lock(featureID)
		pending[featureID] = true
	end
end

function gadget:FeatureDestroyed(featureID, allyTeamID)
	pending[featureID] = nil
	removeStamp(featureID)
end

function gadget:GameFrame(frame)
	if next(pending) then
		---@type table<integer, table>
		local list = {}
		for fid, trust in pairs(pending) do
			list[#list + 1] = { fid, trust }
		end
		for i = 1, #list do
			stampFeature(list[i][1], list[i][2])
		end
	end

	local n = #stamps
	if n == 0 then
		return
	end

	-- Transform drift (anything but the placer moving a mesh): re-stamp.
	-- Collected first: removeStamp/stampFeature reorder the stamp list.
	if frame % TRANSFORM_CHECK_PERIOD == 0 then
		---@type table<integer, integer>
		local drifted = {}
		---@type table<integer, integer>
		local gone = {}
		for i = 1, n do
			local s = stamps[i]
			if not spValidFeatureID(s.fid) then
				gone[#gone + 1] = s.fid
			else
				local t = readTransform(s.fid)
				if t and not sameTransform(t, s.transform) then
					drifted[#drifted + 1] = s.fid
				end
			end
		end
		for i = 1, #gone do
			removeStamp(gone[i])
		end
		for i = 1, #drifted do
			stampFeature(drifted[i], true)
		end
		n = #stamps
		if n == 0 then
			return
		end
	end

	-- Height reconcile: walk the stamps a budget of vertices per frame and
	-- re-assert any stamp whose ground no longer matches (craters, brush).
	---@type number
	local budget = RECONCILE_BUDGET
	while budget > 0 do
		if reconcileStamp > n then
			reconcileStamp, reconcileVert = 1, 1
		end
		local s = stamps[reconcileStamp]
		local xs, zs, hs = s.xs, s.zs, s.hs
		local i = reconcileVert
		local last = min(s.n, i + budget - 1)
		local mismatch = false
		while i <= last do
			if abs(spGetGroundHeight(xs[i] * SQ, zs[i] * SQ) - hs[i]) > HEIGHT_EPSILON then
				mismatch = true
				break
			end
			i = i + 1
		end
		budget = budget - (i - reconcileVert)
		if mismatch then
			reapply(s)
			budget = budget - s.n
			reconcileStamp, reconcileVert = reconcileStamp + 1, 1
		elseif i > s.n then
			reconcileStamp, reconcileVert = reconcileStamp + 1, 1
		else
			reconcileVert = i
		end
		if reconcileStamp > n and reconcileVert == 1 then
			-- one full pass done this frame; the rest waits for the next
			break
		end
	end
end

-- Test hooks for the offline harness (tools/tf_mesh_harness.lua); nothing in
-- the game reads them. Unconditional: the synced sandbox has no rawget to
-- gate on, and two function references in GG cost nothing.
GG.TerrainMeshTest = { parseS3O = parseS3O, rasterize = rasterize }
