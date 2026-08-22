--[[
    SpriteLoop (.spla) Importer and Animation Runtime for Solar2D
    Part of Ponywolf Tools / com.ponywolf.spriteloop

    Provides complete support for importing and playing SpriteLoop 2D cut-out
    animation packages (.spla archives or pre-extracted folders) in Solar2D.
--]]

local json = require("json")
local hasZip, zip = pcall(require, "plugin.zip")

local M = {}
M._VERSION = "1.0.0"

-- Package metadata cache (keyed by normalized path)
local packageCache = {}

--------------------------------------------------------------------------------
-- Helper Utilities
--------------------------------------------------------------------------------

local function fileExists(path, baseDir)
	if not path then return false end
	local fullPath = path
	if baseDir then
		fullPath = system.pathForFile(path, baseDir)
	end
	if not fullPath then return false end
	local f = io.open(fullPath, "r")
	if f then
		f:close()
		return true
	end
	return false
end

local function readFile(path, baseDir)
	local fullPath = path
	if baseDir then
		fullPath = system.pathForFile(path, baseDir)
	end
	if not fullPath then return nil, "path not resolved" end
	local f, err = io.open(fullPath, "r")
	if not f then return nil, err end
	local content = f:read("*a")
	f:close()
	return content
end

local function normalizeName(str)
	if not str then return "" end
	return string.lower(string.gsub(tostring(str), "[%s_%-]", ""))
end

local function sanitizePath(p)
	if not p then return "" end
	local s = string.gsub(p, "\\", "/")
	-- remove trailing slashes
	s = string.gsub(s, "/+$", "")
	return s
end

local function readU16(str, offset)
	local b1, b2 = string.byte(str, offset, offset + 1)
	return (b1 or 0) + (b2 or 0) * 256
end

local function readU32(str, offset)
	local b1, b2, b3, b4 = string.byte(str, offset, offset + 3)
	return (b1 or 0) + (b2 or 0) * 256 + (b3 or 0) * 65536 + (b4 or 0) * 16777216
end

local function ensureDirectoryTree(destSubdir, baseDir)
	local hasLfs, lfs = pcall(require, "lfs")
	if not hasLfs or not lfs then return end
	local fullBase = system.pathForFile("", baseDir) or ""
	local current = fullBase
	for part in string.gmatch(destSubdir, "[^/\\]+") do
		if part ~= "" and part ~= "." then
			current = current .. "/" .. part
			lfs.mkdir(current)
		end
	end
end

local function extractZipArchive(zipFullPath, outputDirFullPath)
	local f, err = io.open(zipFullPath, "rb")
	if not f then return false, err end
	local content = f:read("*a")
	f:close()

	if not content or #content < 30 then
		return false, "Invalid or empty archive"
	end

	local pos = 1
	local len = #content
	local count = 0
	local hasLfs, lfs = pcall(require, "lfs")

	while pos <= len - 30 do
		local sig = string.sub(content, pos, pos + 3)
		if sig == "PK\3\4" then
			local header = string.sub(content, pos, pos + 29)
			local method = readU16(header, 9)
			local compSize = readU32(header, 19)
			local uncompSize = readU32(header, 23)
			local nameLen = readU16(header, 27)
			local extraLen = readU16(header, 29)

			local nameStart = pos + 30
			local nameEnd = nameStart + nameLen - 1
			local fileName = string.sub(content, nameStart, nameEnd)

			local dataStart = nameEnd + extraLen + 1
			local dataEnd = dataStart + compSize - 1
			local data = string.sub(content, dataStart, dataEnd)

			pos = dataEnd + 1

			if not string.match(fileName, "/$") and #data > 0 then
				local outFilePath = outputDirFullPath .. "/" .. fileName
				local relSub = string.match(fileName, "(.+)/[^/]+$")
				if relSub and hasLfs and lfs then
					local curDir = outputDirFullPath
					for p in string.gmatch(relSub, "[^/]+") do
						curDir = curDir .. "/" .. p
						lfs.mkdir(curDir)
					end
				end
				local outF = io.open(outFilePath, "wb")
				if outF then
					outF:write(data)
					outF:close()
					count = count + 1
				end
			end
		elseif sig == "PK\1\2" or sig == "PK\5\6" then
			break
		else
			pos = pos + 1
		end
	end

	return count > 0, count
end

--------------------------------------------------------------------------------
-- Package Loader & Cache
--------------------------------------------------------------------------------

local function parsePackageManifest(manifestJson, assetBaseDir, assetBasePath)
	local data = json.decode(manifestJson)
	if not data then
		return nil, "Failed to parse manifest JSON"
	end

	local pkg = {
		name = data.name or "untitled",
		canvasWidth = (data.canvas and data.canvas.width) or 512,
		canvasHeight = (data.canvas and data.canvas.height) or 512,
		assetBaseDir = assetBaseDir,
		assetBasePath = assetBasePath,
		parts = {},
		partsById = {},
		partsByName = {},
		partsByIndex = {},
		variants = {},
		variantsById = {},
		variantsByKey = {},
		variantsByName = {},
		variantsByPart = {},
		skins = {},
		skinsById = {},
		skinsByName = {},
		states = {},
		statesById = {},
		statesByKey = {},
		animations = {},
		animationsById = {},
		animationsByName = {},
		defaultSkinId = "default",
	}

	-- 1. Index parts
	if type(data.parts) == "table" then
		for index, p in ipairs(data.parts) do
			local isTransformOnly = (p.transformOnly == true) or (p.kind == "empty") or (not p.asset or p.asset == "")
			local part = {
				index = index,
				id = tostring(p.id or index),
				key = p.key or "",
				name = p.name or tostring(p.id or index),
				kind = p.kind or (isTransformOnly and "empty" or "image"),
				asset = p.asset or "",
				width = tonumber(p.width) or 0,
				height = tonumber(p.height) or 0,
				pivot = {
					x = (p.pivot and tonumber(p.pivot.x)) or ((tonumber(p.width) or 0) * 0.5),
					y = (p.pivot and tonumber(p.pivot.y)) or ((tonumber(p.height) or 0) * 0.5),
				},
				drawOrder = tonumber(p.drawOrder) or (index - 1),
				transformOnly = isTransformOnly,
				visible = (p.visible ~= false),
			}
			table.insert(pkg.parts, part)
			pkg.partsById[part.id] = part
			pkg.partsByName[normalizeName(part.name)] = part
			pkg.partsByIndex[index] = part
		end
	end

	-- 2. Index variants
	if type(data.variants) == "table" then
		for index, v in ipairs(data.variants) do
			local variant = {
				index = index,
				id = tostring(v.id or index),
				part = tostring(v.part or ""),
				key = v.key or "",
				name = v.name or v.key or tostring(v.id or index),
				asset = v.asset or "",
				width = tonumber(v.width) or 0,
				height = tonumber(v.height) or 0,
				offsetX = tonumber(v.offsetX) or 0,
				offsetY = tonumber(v.offsetY) or 0,
				rotation = tonumber(v.rotation) or 0,
				zOffset = tonumber(v.zOffset) or 0,
			}
			table.insert(pkg.variants, variant)
			pkg.variantsById[variant.id] = variant
			if variant.key ~= "" then
				pkg.variantsByKey[variant.key] = variant
				pkg.variantsByKey[variant.part .. ":" .. variant.key] = variant
			end
			pkg.variantsByName[normalizeName(variant.name)] = variant

			pkg.variantsByPart[variant.part] = pkg.variantsByPart[variant.part] or {}
			table.insert(pkg.variantsByPart[variant.part], variant)
		end
	end

	-- 3. Index sprite states
	if type(data.states) == "table" then
		for index, s in ipairs(data.states) do
			local state = {
				index = index,
				id = tostring(s.id or index),
				part = tostring(s.part or ""),
				key = s.key or "",
				name = s.name or s.key or tostring(s.id or index),
			}
			table.insert(pkg.states, state)
			pkg.statesById[state.id] = state
			if state.key ~= "" then
				pkg.statesByKey[state.part .. ":" .. state.key] = state
			end
		end
	end

	-- 4. Index skins
	if type(data.skins) == "table" then
		for index, s in ipairs(data.skins) do
			local skin = {
				index = index,
				id = tostring(s.id or index),
				name = s.name or tostring(s.id or index),
				parts = s.parts or {},
			}
			table.insert(pkg.skins, skin)
			pkg.skinsById[skin.id] = skin
			pkg.skinsById[string.lower(skin.id)] = skin
			pkg.skinsByName[normalizeName(skin.name)] = skin
			if index == 1 then
				pkg.defaultSkinId = skin.id
			end
		end
	end

	-- 5. Index animations
	if type(data.animations) == "table" then
		for index, a in ipairs(data.animations) do
			local anim = {
				index = index,
				id = tostring(a.id or index),
				name = a.name or tostring(a.id or index),
				fps = tonumber(a.fps) or 24,
				loop = (a.loop ~= false),
				frameCount = tonumber(a.frameCount) or (#(a.frames or {})),
				frames = {},
			}

			if type(a.frames) == "table" then
				for fIndex, f in ipairs(a.frames) do
					local frame = {
						index = (tonumber(f.index) or (fIndex - 1)),
						sourceFrame = tonumber(f.sourceFrame) or (fIndex - 1),
						events = f.events or {},
						parts = {},
						partsMap = {},
					}
					if type(f.parts) == "table" then
						for _, fp in ipairs(f.parts) do
							local framePart = {
								part = tostring(fp.part or ""),
								x = tonumber(fp.x) or 0,
								y = tonumber(fp.y) or 0,
								rotation = tonumber(fp.rotation) or 0,
								skewX = tonumber(fp.skewX) or 0,
								skewY = tonumber(fp.skewY) or 0,
								scaleX = tonumber(fp.scaleX) or 1,
								scaleY = tonumber(fp.scaleY) or 1,
								opacity = tonumber(fp.opacity) or 1,
								tint = fp.tint, -- array of [r, g, b]
								zOffset = tonumber(fp.zOffset) or 0,
								state = fp.state and tostring(fp.state) or nil,
								nextState = fp.nextState and tostring(fp.nextState) or nil,
								stateMix = tonumber(fp.stateMix) or 0,
							}
							table.insert(frame.parts, framePart)
							frame.partsMap[framePart.part] = framePart
						end
					end
					table.insert(anim.frames, frame)
				end
			end

			table.insert(pkg.animations, anim)
			pkg.animationsById[anim.id] = anim
			pkg.animationsById[string.lower(anim.id)] = anim
			pkg.animationsByName[normalizeName(anim.name)] = anim
		end
	end

	return pkg
end

--- Loads and parses a SpriteLoop package from an archive or folder.
-- @param path Filepath to .spla archive or pre-extracted folder/manifest.
-- @param options Optional loading options (baseDir, forceReload).
-- @return Parsed package table or nil, err.
function M.loadPackage(path, options)
	options = options or {}
	local baseDir = options.baseDir or system.ResourceDirectory
	local cleanPath = sanitizePath(path)
	local cacheKey = tostring(cleanPath) .. "_" .. tostring(baseDir)

	if not options.forceReload and packageCache[cacheKey] then
		return packageCache[cacheKey]
	end

	local isZip = string.lower(string.sub(cleanPath, -5)) == ".spla"
	local assetBaseDir = baseDir
	local assetBasePath = cleanPath

	local manifestContent = nil

	if isZip then
		local pkgName = string.match(cleanPath, "([^/]+)%.spla$") or "package"
		local destSubdir = "spriteloop/" .. pkgName
		local cachedManifestRel = destSubdir .. "/manifest.json"

		-- Check if already extracted in CachesDirectory
		if fileExists(cachedManifestRel, system.CachesDirectory) and not options.forceReload then
			manifestContent = readFile(cachedManifestRel, system.CachesDirectory)
			assetBaseDir = system.CachesDirectory
			assetBasePath = destSubdir
		else
			local zipFullPath = system.pathForFile(cleanPath, baseDir)

			if zipFullPath then
				-- Ensure directory tree in CachesDirectory
				ensureDirectoryTree(destSubdir, system.CachesDirectory)
				ensureDirectoryTree(destSubdir .. "/assets", system.CachesDirectory)

				local destFullPath = system.pathForFile(destSubdir, system.CachesDirectory)
				if destFullPath then
					local extracted = extractZipArchive(zipFullPath, destFullPath)
					if extracted and fileExists(cachedManifestRel, system.CachesDirectory) then
						manifestContent = readFile(cachedManifestRel, system.CachesDirectory)
						assetBaseDir = system.CachesDirectory
						assetBasePath = destSubdir
					end
				end
			end

			-- Fallback to plugin.zip if native zip extraction was not sufficient
			if not manifestContent and hasZip and zip and zip.uncompress then
				local zipRelPath = cleanPath
				pcall(function()
					zip.uncompress({
						zipFile = zipRelPath,
						zipBaseDir = baseDir,
						dstBaseDir = system.CachesDirectory,
					})
				end)
				if fileExists(cachedManifestRel, system.CachesDirectory) then
					manifestContent = readFile(cachedManifestRel, system.CachesDirectory)
					assetBaseDir = system.CachesDirectory
					assetBasePath = destSubdir
				end
			end
		end

		-- If still not loaded, check if an unzipped folder with the same name exists in ResourceDirectory
		if not manifestContent then
			local folderPath = string.sub(cleanPath, 1, -6) -- remove .spla
			local folderManifest = folderPath .. "/manifest.json"
			if fileExists(folderManifest, baseDir) then
				manifestContent = readFile(folderManifest, baseDir)
				assetBaseDir = baseDir
				assetBasePath = folderPath
			end
		end

		if not manifestContent then
			local err = "Unable to load .spla package '" .. tostring(cleanPath) .. "'."
			return nil, err
		end
	else
		-- Direct folder or manifest path
		local manifestPath = cleanPath
		if string.lower(string.sub(cleanPath, -5)) == ".json" then
			assetBasePath = string.match(cleanPath, "(.+)/[^/]+$") or ""
		else
			manifestPath = cleanPath .. "/manifest.json"
			assetBasePath = cleanPath
		end

		manifestContent = readFile(manifestPath, baseDir)
		if not manifestContent then
			return nil, "Could not find manifest at '" .. tostring(manifestPath) .. "'"
		end
		assetBaseDir = baseDir
	end

	local pkg, err = parsePackageManifest(manifestContent, assetBaseDir, assetBasePath)
	if not pkg then
		return nil, err
	end

	packageCache[cacheKey] = pkg
	return pkg
end

--------------------------------------------------------------------------------
-- Lookup Helpers on Package
--------------------------------------------------------------------------------

local function findPart(pkg, idKeyOrName)
	if not pkg or not idKeyOrName then return nil end
	local idStr = tostring(idKeyOrName)
	local part = pkg.partsById[idStr]
	if part then return part end

	local norm = normalizeName(idStr)
	part = pkg.partsByName[norm]
	if part then return part end

	return nil
end

local function findVariantForPart(pkg, part, variantIdKeyOrName)
	if not pkg or not part or not variantIdKeyOrName then return nil end
	local vStr = tostring(variantIdKeyOrName)

	-- Direct ID lookup
	local v = pkg.variantsById[vStr]
	if v and v.part == part.id then return v end

	-- Key lookup on part
	local vKey = pkg.variantsByKey[part.id .. ":" .. vStr] or pkg.variantsByKey[vStr]
	if vKey and vKey.part == part.id then return vKey end

	-- Name lookup
	local norm = normalizeName(vStr)
	local vName = pkg.variantsByName[norm]
	if vName and vName.part == part.id then return vName end

	-- List iteration fallback
	local list = pkg.variantsByPart[part.id]
	if list then
		for _, item in ipairs(list) do
			if item.id == vStr or item.key == vStr or normalizeName(item.name) == norm then
				return item
			end
		end
	end

	return nil
end

local function findSkin(pkg, skinIdOrName)
	if not pkg or not skinIdOrName then return nil end
	local sStr = tostring(skinIdOrName)
	local skin = pkg.skinsById[sStr] or pkg.skinsById[string.lower(sStr)]
	if skin then return skin end

	local norm = normalizeName(sStr)
	skin = pkg.skinsByName[norm]
	if skin then return skin end

	return nil
end

local function findAnimation(pkg, animIdOrName)
	if not pkg or not animIdOrName then return nil end
	local aStr = tostring(animIdOrName)
	local anim = pkg.animationsById[aStr] or pkg.animationsById[string.lower(aStr)]
	if anim then return anim end

	local norm = normalizeName(aStr)
	anim = pkg.animationsByName[norm]
	if anim then return anim end

	return nil
end

--------------------------------------------------------------------------------
-- SpriteLoop Display Object Instance
--------------------------------------------------------------------------------

local SpriteLoopInstance = {}
local SpriteLoopInstance_mt = { __index = SpriteLoopInstance }

--- Calculates the rotated and scaled positional offset for a part variant.
local function calculatePartOffset(visual, rotation, scaleX, scaleY, skewX, skewY)
	if not visual then return 0, 0 end
	local vx = visual.offsetX or 0
	local vy = visual.offsetY or 0
	if vx == 0 and vy == 0 then
		return 0, 0
	end

	local scX = scaleX or 1
	local scY = scaleY or 1
	local skX = skewX or 0
	local skY = skewY or 0
	local rot = rotation or 0

	local lx = vx * scX
	local ly = vy * scY

	if skX ~= 0 or skY ~= 0 then
		local tanX = math.tan(skX * math.pi / 180.0)
		local tanY = math.tan(skY * math.pi / 180.0)
		local skewedX = lx + tanX * ly
		local skewedY = tanY * lx + ly
		lx = skewedX
		ly = skewedY
	end

	if rot ~= 0 then
		local rad = rot * math.pi / 180.0
		local cosR = math.cos(rad)
		local sinR = math.sin(rad)
		return (lx * cosR - ly * sinR), (lx * sinR + ly * cosR)
	else
		return lx, ly
	end
end

--- Resolves the visual asset, size, anchor, offsets, rotation, and z-offset for a part.
local function resolvePartVisual(self, part, framePart)
	local pkg = self._package
	local partId = part.id
	local skin = self._activeSkin

	local override = nil
	if skin and skin.parts then
		override = skin.parts[partId]
	end

	-- Check part visibility
	local isVisible = part.visible
	if type(override) == "table" and override.visible ~= nil then
		isVisible = (override.visible == true)
	end

	if not isVisible or part.transformOnly then
		return nil, false
	end

	-- Resolve variant: Manual override takes precedence, then frame state, then skin variant
	local variant = self._manualVariants[partId]

	if not variant and framePart and framePart.state and type(override) == "table" and type(override.states) == "table" then
		local stateVariantId = override.states[framePart.state]
		if stateVariantId then
			variant = pkg.variantsById[stateVariantId]
		end
	end

	if not variant and type(override) == "table" and override.variant then
		variant = pkg.variantsById[override.variant]
	end

	local imageSource = variant or part
	if not imageSource.asset or imageSource.asset == "" then
		return nil, false
	end

	local partWidth = part.width
	local partHeight = part.height
	local imageWidth = imageSource.width or partWidth
	local imageHeight = imageSource.height or partHeight

	local pivotX = part.pivot.x + 0.5 * (imageWidth - partWidth)
	local pivotY = part.pivot.y + 0.5 * (imageHeight - partHeight)

	local anchorX = (imageWidth > 0) and (pivotX / imageWidth) or 0.5
	local anchorY = (imageHeight > 0) and (pivotY / imageHeight) or 0.5

	local relAsset = imageSource.asset or ""
	local fullAsset = relAsset
	if self._assetBasePath and self._assetBasePath ~= "" and not string.find(relAsset, "^/") then
		fullAsset = self._assetBasePath .. "/" .. relAsset
	end

	return {
		asset = fullAsset,
		width = imageWidth,
		height = imageHeight,
		anchorX = anchorX,
		anchorY = anchorY,
		offsetX = variant and (variant.offsetX or 0) or 0,
		offsetY = variant and (variant.offsetY or 0) or 0,
		rotation = variant and (variant.rotation or 0) or 0,
		zOffset = (framePart and framePart.zOffset or 0) + (variant and (variant.zOffset or 0) or 0),
		baseDrawOrder = part.drawOrder,
	}, true
end

--- Updates a single part's display object texture and anchor.
local function updatePartDisplayObject(self, part, visual)
	local obj = self._partObjects[part.id]

	if not visual or not visual.asset or visual.asset == "" then
		if obj then
			obj.isVisible = false
		end
		return
	end

	if not obj then
		-- Create new image rect
		obj = display.newImageRect(self, visual.asset, self._assetBaseDir, visual.width, visual.height)
		if obj then
			self._partObjects[part.id] = obj
			self._partObjects[part.name] = obj
			self._partCurrentAssets[part.id] = visual.asset
		end
	else
		-- Check if texture asset or size changed
		if self._partCurrentAssets[part.id] ~= visual.asset then
			obj.fill = { type = "image", filename = visual.asset, baseDir = self._assetBaseDir }
			obj.width = visual.width
			obj.height = visual.height
			self._partCurrentAssets[part.id] = visual.asset
		end
		obj.isVisible = true
	end

	if obj then
		obj.anchorX = visual.anchorX
		obj.anchorY = visual.anchorY
	end
end

--- Renders a specific frame of the current animation.
function SpriteLoopInstance:renderFrame(frameIndex)
	local anim = self._currentAnimation
	if not anim or not anim.frames or #anim.frames == 0 then return end

	local frameCount = #anim.frames
	local fIdx = (frameIndex % frameCount) + 1
	local frame = anim.frames[fIdx]
	if not frame then return end

	local pkg = self._package
	local halfCanvasW = pkg.canvasWidth * 0.5
	local halfCanvasH = pkg.canvasHeight * 0.5

	local orderTable = {}

	for _, part in ipairs(pkg.parts) do
		if not part.transformOnly then
			local framePart = frame.partsMap[part.id]
			local visual, visible = resolvePartVisual(self, part, framePart)

			if visible and framePart then
				updatePartDisplayObject(self, part, visual)
				local obj = self._partObjects[part.id]
				if obj then
					-- Calculate centered position in group
					local localX = framePart.x - halfCanvasW
					local localY = framePart.y - halfCanvasH
					local offX, offY = calculatePartOffset(visual, framePart.rotation, framePart.scaleX, framePart.scaleY, framePart.skewX, framePart.skewY)

					obj.x = localX + offX
					obj.y = localY + offY
					obj.rotation = framePart.rotation + visual.rotation
					obj.xScale = framePart.scaleX
					obj.yScale = framePart.scaleY
					obj.alpha = framePart.opacity

					-- RGB Tint calculation
					local fTint = framePart.tint
					local tr = self._tintR * (fTint and fTint[1] or 1.0)
					local tg = self._tintG * (fTint and fTint[2] or 1.0)
					local tb = self._tintB * (fTint and fTint[3] or 1.0)
					obj:setFillColor(tr, tg, tb)

					-- Skew transformation via Solar2D native path quadrilateral distortion
					local skX = framePart.skewX or 0
					local skY = framePart.skewY or 0
					if obj.path then
						if skX ~= 0 or skY ~= 0 then
							local tanX = math.tan(skX * math.pi / 180.0)
							local tanY = math.tan(skY * math.pi / 180.0)
							local w = obj.width or visual.width or 0
							local h = obj.height or visual.height or 0
							local ax = obj.anchorX or 0.5
							local ay = obj.anchorY or 0.5

							local lxLeft = -ax * w
							local lxRight = (1.0 - ax) * w
							local lyTop = -ay * h
							local lyBottom = (1.0 - ay) * h

							-- Corner 1: Top-Left (x1, y1)
							obj.path.x1 = tanX * lyTop
							obj.path.y1 = tanY * lxLeft

							-- Corner 2: Bottom-Left (x2, y2)
							obj.path.x2 = tanX * lyBottom
							obj.path.y2 = tanY * lxLeft

							-- Corner 3: Bottom-Right (x3, y3)
							obj.path.x3 = tanX * lyBottom
							obj.path.y3 = tanY * lxRight

							-- Corner 4: Top-Right (x4, y4)
							obj.path.x4 = tanX * lyTop
							obj.path.y4 = tanY * lxRight
						else
							if obj.path.x1 ~= 0 or obj.path.y1 ~= 0 or obj.path.x2 ~= 0 or obj.path.y2 ~= 0 or
							   obj.path.x3 ~= 0 or obj.path.y3 ~= 0 or obj.path.x4 ~= 0 or obj.path.y4 ~= 0 then
								obj.path.x1 = 0; obj.path.y1 = 0
								obj.path.x2 = 0; obj.path.y2 = 0
								obj.path.x3 = 0; obj.path.y3 = 0
								obj.path.x4 = 0; obj.path.y4 = 0
							end
						end
					end

					local effectiveZ = visual.baseDrawOrder + visual.zOffset
					table.insert(orderTable, { obj = obj, z = effectiveZ, base = visual.baseDrawOrder })
				end
			else
				local obj = self._partObjects[part.id]
				if obj then
					obj.isVisible = false
				end
			end
		end
	end

	-- Reorder children based on effective z-order
	table.sort(orderTable, function(a, b)
		if a.z == b.z then
			return a.base < b.base
		end
		return a.z < b.z
	end)

	for i, item in ipairs(orderTable) do
		item.obj:toFront()
	end
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function lerpAngle(a, b, t)
	local diff = (b - a) % 360
	if diff > 180 then diff = diff - 360 end
	if diff < -180 then diff = diff + 360 end
	return a + diff * t
end

--- Renders a smoothly interpolated frame between two keyframes.
function SpriteLoopInstance:renderInterpolatedFrame(frameIdxA, frameIdxB, mix)
	local anim = self._currentAnimation
	if not anim or not anim.frames or #anim.frames == 0 then return end

	mix = math.max(0.0, math.min(mix or 0.0, 1.0))
	if mix == 0.0 or frameIdxA == frameIdxB then
		return self:renderFrame(frameIdxA)
	end

	local frameCount = #anim.frames
	local fA = anim.frames[(frameIdxA % frameCount) + 1]
	local fB = anim.frames[(frameIdxB % frameCount) + 1]
	if not fA then return end
	if not fB then return self:renderFrame(frameIdxA) end

	local pkg = self._package
	local halfCanvasW = pkg.canvasWidth * 0.5
	local halfCanvasH = pkg.canvasHeight * 0.5

	local orderTable = {}

	for _, part in ipairs(pkg.parts) do
		if not part.transformOnly then
			local fpA = fA.partsMap[part.id]
			local fpB = fB.partsMap[part.id]

			local visual, visible = resolvePartVisual(self, part, fpA)

			if visible and fpA then
				updatePartDisplayObject(self, part, visual)
				local obj = self._partObjects[part.id]
				if obj then
					local posX, posY, rot, scX, scY, op, skX, skY, fTintR, fTintG, fTintB

					if fpB then
						posX = lerp(fpA.x, fpB.x, mix) - halfCanvasW
						posY = lerp(fpA.y, fpB.y, mix) - halfCanvasH
						rot = lerpAngle(fpA.rotation, fpB.rotation, mix)
						scX = lerp(fpA.scaleX, fpB.scaleX, mix)
						scY = lerp(fpA.scaleY, fpB.scaleY, mix)
						op = lerp(fpA.opacity, fpB.opacity, mix)
						skX = lerp(fpA.skewX or 0, fpB.skewX or 0, mix)
						skY = lerp(fpA.skewY or 0, fpB.skewY or 0, mix)

						local tA = fpA.tint or { 1, 1, 1 }
						local tB = fpB.tint or { 1, 1, 1 }
						fTintR = lerp(tA[1] or 1, tB[1] or 1, mix)
						fTintG = lerp(tA[2] or 1, tB[2] or 1, mix)
						fTintB = lerp(tA[3] or 1, tB[3] or 1, mix)
					else
						posX = fpA.x - halfCanvasW
						posY = fpA.y - halfCanvasH
						rot = fpA.rotation
						scX = fpA.scaleX
						scY = fpA.scaleY
						op = fpA.opacity
						skX = fpA.skewX or 0
						skY = fpA.skewY or 0

						local tA = fpA.tint or { 1, 1, 1 }
						fTintR = tA[1] or 1
						fTintG = tA[2] or 1
						fTintB = tA[3] or 1
					end

					local offX, offY = calculatePartOffset(visual, rot, scX, scY, skX, skY)

					obj.x = posX + offX
					obj.y = posY + offY
					obj.rotation = rot + visual.rotation
					obj.xScale = scX
					obj.yScale = scY
					obj.alpha = op

					-- RGB Tint calculation
					local tr = self._tintR * fTintR
					local tg = self._tintG * fTintG
					local tb = self._tintB * fTintB
					obj:setFillColor(tr, tg, tb)

					-- Skew transformation via Solar2D native path quadrilateral distortion
					if obj.path then
						if skX ~= 0 or skY ~= 0 then
							local tanX = math.tan(skX * math.pi / 180.0)
							local tanY = math.tan(skY * math.pi / 180.0)
							local w = obj.width or visual.width or 0
							local h = obj.height or visual.height or 0
							local ax = obj.anchorX or 0.5
							local ay = obj.anchorY or 0.5

							local lxLeft = -ax * w
							local lxRight = (1.0 - ax) * w
							local lyTop = -ay * h
							local lyBottom = (1.0 - ay) * h

							-- Corner 1: Top-Left (x1, y1)
							obj.path.x1 = tanX * lyTop
							obj.path.y1 = tanY * lxLeft

							-- Corner 2: Bottom-Left (x2, y2)
							obj.path.x2 = tanX * lyBottom
							obj.path.y2 = tanY * lxLeft

							-- Corner 3: Bottom-Right (x3, y3)
							obj.path.x3 = tanX * lyBottom
							obj.path.y3 = tanY * lxRight

							-- Corner 4: Top-Right (x4, y4)
							obj.path.x4 = tanX * lyTop
							obj.path.y4 = tanY * lxRight
						else
							if obj.path.x1 ~= 0 or obj.path.y1 ~= 0 or obj.path.x2 ~= 0 or obj.path.y2 ~= 0 or
							   obj.path.x3 ~= 0 or obj.path.y3 ~= 0 or obj.path.x4 ~= 0 or obj.path.y4 ~= 0 then
								obj.path.x1 = 0; obj.path.y1 = 0
								obj.path.x2 = 0; obj.path.y2 = 0
								obj.path.x3 = 0; obj.path.y3 = 0
								obj.path.x4 = 0; obj.path.y4 = 0
							end
						end
					end

					local effectiveZ = visual.baseDrawOrder + visual.zOffset
					table.insert(orderTable, { obj = obj, z = effectiveZ, base = visual.baseDrawOrder })
				end
			else
				local obj = self._partObjects[part.id]
				if obj then
					obj.isVisible = false
				end
			end
		end
	end

	-- Reorder children based on effective z-order
	table.sort(orderTable, function(a, b)
		if a.z == b.z then
			return a.base < b.base
		end
		return a.z < b.z
	end)

	for i, item in ipairs(orderTable) do
		item.obj:toFront()
	end
end

--- Dispatches an event to Solar2D event listeners and inline callbacks.
local function dispatchSplaEvent(self, phase, eventData)
	local event = {
		name = "spriteloop",
		target = self,
		phase = phase,
		animation = self._currentAnimation and self._currentAnimation.name or "",
		animationId = self._currentAnimation and self._currentAnimation.id or "",
		frame = self._currentFrameIndex,
	}

	if eventData then
		for k, v in pairs(eventData) do
			event[k] = v
		end
	end

	-- Solar2D event listener dispatch
	if self.dispatchEvent then
		self:dispatchEvent(event)
	end

	-- Inline callbacks
	local cb = self._inlineCallbacks
	if cb then
		if phase == "event" and type(cb.onEvent) == "function" then
			cb.onEvent(event)
		elseif phase == "loop" and type(cb.onLoop) == "function" then
			cb.onLoop(event)
		elseif phase == "complete" and type(cb.onComplete) == "function" then
			cb.onComplete(event)
		end
	end
end

--- Checks and dispatches timeline events for entering a frame.
local function checkFrameEvents(self, anim, frameIndex)
	if not anim or not anim.frames then return end
	if self._emitEvents == false then return end

	local fIdx = (frameIndex % #anim.frames) + 1
	local frame = anim.frames[fIdx]
	if frame and frame.events and #frame.events > 0 then
		for _, ev in ipairs(frame.events) do
			dispatchSplaEvent(self, "event", {
				eventName = ev.name,
				eventData = ev.data or "",
				sourceFrame = frame.sourceFrame,
			})
		end
	end
end

--- Advances the animation playback by dt seconds.
function SpriteLoopInstance:update(dt)
	if not self._isPlaying or not self._currentAnimation then return end

	local anim = self._currentAnimation
	local fps = anim.fps or 24
	local frameCount = anim.frameCount or #anim.frames
	if frameCount <= 0 then return end

	local prevRawFrame = math.floor(self._elapsedTime * fps)
	self._elapsedTime = self._elapsedTime + dt * self._playbackRate

	local rawTime = self._elapsedTime * fps
	local rawFrame = math.floor(rawTime)
	local isLoop = (self._loopOverride ~= nil) and self._loopOverride or anim.loop

	local currentFrameIdx = 0
	local nextFrameIdx = 0
	local frameMix = 0

	if isLoop then
		currentFrameIdx = rawFrame % frameCount
		nextFrameIdx = (currentFrameIdx + 1) % frameCount
		frameMix = rawTime - rawFrame

		if rawFrame > prevRawFrame then
			for f = prevRawFrame + 1, rawFrame do
				local checkF = f % frameCount
				if checkF == 0 and f > 0 then
					dispatchSplaEvent(self, "loop")
				end
				checkFrameEvents(self, anim, checkF)
			end
		end
	else
		if rawFrame >= frameCount - 1 then
			currentFrameIdx = frameCount - 1
			nextFrameIdx = frameCount - 1
			frameMix = 0
			self._isPlaying = false
			dispatchSplaEvent(self, "complete")
		else
			currentFrameIdx = rawFrame
			nextFrameIdx = math.min(currentFrameIdx + 1, frameCount - 1)
			frameMix = rawTime - rawFrame

			if rawFrame > prevRawFrame then
				for f = prevRawFrame + 1, rawFrame do
					checkFrameEvents(self, anim, f)
				end
			end
		end
	end

	self._currentFrameIndex = currentFrameIdx

	if self._interpolate ~= false then
		self:renderInterpolatedFrame(currentFrameIdx, nextFrameIdx, frameMix)
	else
		self:renderFrame(currentFrameIdx)
	end
end

--- Starts or switches animation playback.
-- @param animIdOrName Animation identifier or display name.
-- @param options Optional table { loop, playbackRate, emitEvents, onEvent, onLoop, onComplete }
function SpriteLoopInstance:play(animIdOrName, options)
	options = options or {}
	local pkg = self._package

	local targetAnim = nil
	if animIdOrName then
		targetAnim = findAnimation(pkg, animIdOrName)
		if not targetAnim then
			print("SpriteLoop warning: animation '" .. tostring(animIdOrName) .. "' not found in package '" .. pkg.name .. "'")
			return false
		end
	else
		targetAnim = self._currentAnimation or (pkg.animations and pkg.animations[1])
	end

	if not targetAnim then return false end

	self._currentAnimation = targetAnim
	self._isPlaying = true
	self._elapsedTime = 0
	self._currentFrameIndex = 0

	if options.loop ~= nil then
		self._loopOverride = (options.loop == true)
	else
		self._loopOverride = nil
	end

	if options.playbackRate ~= nil then
		self._playbackRate = tonumber(options.playbackRate) or 1.0
	end

	self._emitEvents = (options.emitEvents ~= false)
	self._inlineCallbacks = {
		onEvent = options.onEvent,
		onLoop = options.onLoop,
		onComplete = options.onComplete,
	}

	self:renderFrame(0)
	checkFrameEvents(self, targetAnim, 0)

	return true
end

--- Pauses animation playback.
function SpriteLoopInstance:pause()
	self._isPlaying = false
end

--- Resumes animation playback.
function SpriteLoopInstance:resume()
	if self._currentAnimation then
		self._isPlaying = true
	end
end

--- Stops animation playback and resets to frame 0.
function SpriteLoopInstance:stop()
	self._isPlaying = false
	self._elapsedTime = 0
	self._currentFrameIndex = 0
	self:renderFrame(0)
end

--- Sets current animation to a discrete frame index.
function SpriteLoopInstance:setFrame(frameIndex, options)
	options = options or {}
	local anim = self._currentAnimation
	if not anim or not anim.frames or #anim.frames == 0 then return false end

	local frameCount = #anim.frames
	local targetIndex = math.max(0, math.min(tonumber(frameIndex) or 0, frameCount - 1))
	self._currentFrameIndex = targetIndex
	self._elapsedTime = targetIndex / (anim.fps or 24)

	self:renderFrame(targetIndex)

	if options.emitEvents ~= false then
		checkFrameEvents(self, anim, targetIndex)
	end
	return true
end

--- Sets playback position to absolute time in seconds.
function SpriteLoopInstance:setTime(seconds, options)
	options = options or {}
	local anim = self._currentAnimation
	if not anim or not anim.frames or #anim.frames == 0 then return false end

	local fps = anim.fps or 24
	local frameCount = #anim.frames
	local t = math.max(0, tonumber(seconds) or 0)
	self._elapsedTime = t

	local frameIndex = math.floor(t * fps)
	local isLoop = (self._loopOverride ~= nil) and self._loopOverride or anim.loop
	if isLoop then
		frameIndex = frameIndex % frameCount
	else
		frameIndex = math.min(frameIndex, frameCount - 1)
	end

	self._currentFrameIndex = frameIndex
	self:renderFrame(frameIndex)

	if options.emitEvents ~= false then
		checkFrameEvents(self, anim, frameIndex)
	end
	return true
end

--- Overrides looping behavior for active animation.
function SpriteLoopInstance:setLoop(isLoop)
	self._loopOverride = (isLoop == true)
end

--- Sets playback rate multiplier.
function SpriteLoopInstance:setPlaybackRate(rate)
	self._playbackRate = tonumber(rate) or 1.0
end

--- Switches active skin by id or name.
function SpriteLoopInstance:setSkin(skinIdOrName)
	local pkg = self._package
	local skin = findSkin(pkg, skinIdOrName)
	if not skin then
		print("SpriteLoop warning: skin '" .. tostring(skinIdOrName) .. "' not found in package '" .. pkg.name .. "'")
		return false
	end

	self._activeSkin = skin
	self:renderFrame(self._currentFrameIndex)
	return true
end

--- Overrides an individual part with a specific variant.
function SpriteLoopInstance:setVariant(partIdOrName, variantIdOrName)
	local pkg = self._package
	local part = findPart(pkg, partIdOrName)
	if not part then
		print("SpriteLoop warning: part '" .. tostring(partIdOrName) .. "' not found")
		return false
	end

	if string.lower(tostring(variantIdOrName)) == "default" then
		return self:clearVariant(part.id)
	end

	local variant = findVariantForPart(pkg, part, variantIdOrName)
	if not variant then
		print("SpriteLoop warning: variant '" .. tostring(variantIdOrName) .. "' not found for part '" .. part.name .. "'")
		return false
	end

	self._manualVariants[part.id] = variant
	self:renderFrame(self._currentFrameIndex)
	return true
end

--- Clears manual variant override for one part.
function SpriteLoopInstance:clearVariant(partIdOrName)
	local part = findPart(self._package, partIdOrName)
	if not part then return false end

	self._manualVariants[part.id] = nil
	self:renderFrame(self._currentFrameIndex)
	return true
end

--- Clears all manual part variant overrides.
function SpriteLoopInstance:clearVariants()
	self._manualVariants = {}
	self:renderFrame(self._currentFrameIndex)
end

--- Applies a whole-character RGB tint multiplier.
function SpriteLoopInstance:setTint(r, g, b)
	self._tintR = math.max(0, math.min(tonumber(r) or 1.0, 1.0))
	self._tintG = math.max(0, math.min(tonumber(g) or 1.0, 1.0))
	self._tintB = math.max(0, math.min(tonumber(b) or 1.0, 1.0))
	self:renderFrame(self._currentFrameIndex)
end

--- Resets whole-character tint to white (1, 1, 1).
function SpriteLoopInstance:clearTint()
	self:setTint(1.0, 1.0, 1.0)
end

--- Sets whether sub-frame interpolation is enabled.
function SpriteLoopInstance:setInterpolated(interpolate)
	self._interpolate = (interpolate ~= false)
end

--- Queries the resolved transform of a part in the current frame.
-- @param partIdOrName Part ID, key, or display name.
-- @param options Optional { origin = "pivot" | "center" }
-- @return Transform table { x, y, rotation, scaleX, scaleY, opacity, skewX, skewY } or nil.
function SpriteLoopInstance:getPartTransform(partIdOrName, options)
	options = options or {}
	local pkg = self._package
	local part = findPart(pkg, partIdOrName)
	if not part then return nil end

	local anim = self._currentAnimation
	if not anim or not anim.frames or #anim.frames == 0 then return nil end

	local frameCount = #anim.frames
	local fIdxA = (self._currentFrameIndex % frameCount) + 1
	local frameA = anim.frames[fIdxA]
	if not frameA then return nil end

	local framePartA = frameA.partsMap[part.id]
	if not framePartA then return nil end

	local fps = anim.fps or 24
	local rawTime = self._elapsedTime * fps
	local rawFrame = math.floor(rawTime)
	local frameMix = math.max(0.0, math.min(rawTime - rawFrame, 1.0))
	local fIdxB = ((self._currentFrameIndex + 1) % frameCount) + 1
	local frameB = anim.frames[fIdxB]
	local framePartB = frameB and frameB.partsMap[part.id]

	local halfCanvasW = pkg.canvasWidth * 0.5
	local halfCanvasH = pkg.canvasHeight * 0.5

	local posX, posY, rot, scX, scY, op, skX, skY
	if self._interpolate ~= false and framePartB and frameMix > 0 then
		posX = lerp(framePartA.x, framePartB.x, frameMix) - halfCanvasW
		posY = lerp(framePartA.y, framePartB.y, frameMix) - halfCanvasH
		rot = lerpAngle(framePartA.rotation, framePartB.rotation, frameMix)
		scX = lerp(framePartA.scaleX, framePartB.scaleX, frameMix)
		scY = lerp(framePartA.scaleY, framePartB.scaleY, frameMix)
		op = lerp(framePartA.opacity, framePartB.opacity, frameMix)
		skX = lerp(framePartA.skewX or 0, framePartB.skewX or 0, frameMix)
		skY = lerp(framePartA.skewY or 0, framePartB.skewY or 0, frameMix)
	else
		posX = framePartA.x - halfCanvasW
		posY = framePartA.y - halfCanvasH
		rot = framePartA.rotation
		scX = framePartA.scaleX
		scY = framePartA.scaleY
		op = framePartA.opacity
		skX = framePartA.skewX or 0
		skY = framePartA.skewY or 0
	end

	local visual = resolvePartVisual(self, part, framePartA)
	if visual then
		local offX, offY = calculatePartOffset(visual, rot, scX, scY, skX, skY)
		posX = posX + offX
		posY = posY + offY
		rot = rot + (visual.rotation or 0)
	end

	if options.origin == "center" and not part.transformOnly then
		local localX = (part.width * 0.5 - part.pivot.x) * scX
		local localY = (part.height * 0.5 - part.pivot.y) * scY

		local tanSkX = math.tan(skX * math.pi / 180.0)
		local tanSkY = math.tan(skY * math.pi / 180.0)
		local skewedX = localX + tanSkX * localY
		local skewedY = tanSkY * localX + localY

		local rad = rot * math.pi / 180.0
		local cosR = math.cos(rad)
		local sinR = math.sin(rad)

		posX = posX + (skewedX * cosR - skewedY * sinR)
		posY = posY + (skewedX * sinR + skewedY * cosR)
	end

	return {
		x = posX,
		y = posY,
		rotation = rot,
		scaleX = scX,
		scaleY = scY,
		opacity = op,
		skewX = skX,
		skewY = skY,
	}
end

--- Returns package metadata, skins, animations, and current state information.
function SpriteLoopInstance:getInfo()
	local pkg = self._package
	local skinIndex = self._activeSkin and self._activeSkin.index or -1

	local anims = {}
	for _, a in ipairs(pkg.animations) do
		table.insert(anims, {
			id = a.id,
			name = a.name,
			fps = a.fps,
			loop = a.loop,
			frameCount = a.frameCount,
		})
	end

	local skins = {}
	for _, s in ipairs(pkg.skins) do
		table.insert(skins, {
			id = s.id,
			name = s.name,
		})
	end

	local variants = {}
	for _, v in ipairs(pkg.variants) do
		table.insert(variants, {
			id = v.id,
			part = v.part,
			key = v.key,
			name = v.name,
			rotation = v.rotation,
			zOffset = v.zOffset,
		})
	end

	return {
		name = pkg.name,
		canvasWidth = pkg.canvasWidth,
		canvasHeight = pkg.canvasHeight,
		skinIndex = skinIndex,
		activeSkin = self._activeSkin and self._activeSkin.name or "Default",
		currentAnimation = self._currentAnimation and self._currentAnimation.name or "",
		currentFrame = self._currentFrameIndex,
		isPlaying = self._isPlaying,
		animations = anims,
		skins = skins,
		variants = variants,
		parts = pkg.parts,
	}
end

--------------------------------------------------------------------------------
-- Factory Constructor: spriteloop.new()
--------------------------------------------------------------------------------

--- Creates a new SpriteLoop character display object instance.
-- @param path Filepath to .spla archive or pre-extracted folder.
-- @param options Configuration options (skin, anim, loop, autoplay, playbackRate, baseDir, x, y).
-- @return Solar2D display group instance with attached playback controls.
function M.new(path, options)
	options = options or {}
	local pkg, err = M.loadPackage(path, options)
	if not pkg then
		error("SpriteLoop.new failed to load package: " .. tostring(err))
	end

	-- Create base display group
	local instance = display.newGroup()

	-- Attach metatable and properties
	for k, v in pairs(SpriteLoopInstance) do
		instance[k] = v
	end

	instance._package = pkg
	instance._assetBaseDir = pkg.assetBaseDir
	instance._assetBasePath = pkg.assetBasePath

	instance._currentAnimation = nil
	instance._currentFrameIndex = 0
	instance._elapsedTime = 0
	instance._isPlaying = false
	instance._playbackRate = tonumber(options.playbackRate) or 1.0
	instance._loopOverride = (options.loop ~= nil) and (options.loop == true) or nil
	instance._interpolate = (options.interpolate ~= false)
	instance._emitEvents = true

	instance._tintR = 1.0
	instance._tintG = 1.0
	instance._tintB = 1.0

	instance._manualVariants = {}
	instance._partObjects = {}
	instance._partCurrentAssets = {}

	-- Position
	instance.x = options.x or 0
	instance.y = options.y or 0

	-- Set initial skin
	local initSkin = options.skin or (pkg.skins and pkg.skins[1] and pkg.skins[1].id)
	if initSkin then
		instance:setSkin(initSkin)
	end

	-- Pre-build part display objects
	for _, part in ipairs(pkg.parts) do
		if not part.transformOnly then
			local visual, visible = resolvePartVisual(instance, part, nil)
			if visible and visual then
				updatePartDisplayObject(instance, part, visual)
			end
		end
	end

	-- Initial animation selection & autoplay
	local initAnim = options.anim or (pkg.animations[1] and pkg.animations[1].name)
	local autoplay = (options.autoplay ~= false)

	if initAnim then
		if autoplay then
			instance:play(initAnim, { loop = options.loop })
		else
			local anim = findAnimation(pkg, initAnim)
			if anim then
				instance._currentAnimation = anim
				instance:renderFrame(0)
			end
		end
	end

	-- Runtime enterFrame driver
	local lastTime = system.getTimer()
	local function onEnterFrame(event)
		if not instance or not instance.update then
			Runtime:removeEventListener("enterFrame", onEnterFrame)
			return
		end

		local now = event.time or system.getTimer()
		local dt = (now - lastTime) / 1000.0
		lastTime = now

		-- Clamp delta time to avoid large jumps during app pause
		if dt > 0.1 then dt = 0.1 end
		if dt < 0 then dt = 0 end

		instance:update(dt)
	end

	Runtime:addEventListener("enterFrame", onEnterFrame)

	-- Cleanup on finalize / display removal
	local function onFinalize(event)
		Runtime:removeEventListener("enterFrame", onEnterFrame)
	end
	instance:addEventListener("finalize", onFinalize)

	return instance
end

return M
