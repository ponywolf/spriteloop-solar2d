-----------------------------------------------------------------------------------------
--
-- main.lua
-- SpriteLoop (.spla) Importer & Interactive Viewer for Solar2D
--
-----------------------------------------------------------------------------------------

display.setStatusBar(display.HiddenStatusBar)

local spriteloop = require("com.ponywolf.spriteloop")

-- Screen dimensions and safe areas
local cx = display.contentCenterX
local cy = display.contentCenterY
local screenW = display.actualContentWidth
local screenH = display.actualContentHeight
local minX = display.screenOriginX
local maxX = display.screenOriginX + screenW
local minY = display.screenOriginY
local maxY = display.screenOriginY + screenH

-- Background gradient / styling
local bg = display.newRect(cx, cy, screenW + 100, screenH + 100)
bg:setFillColor(0.12, 0.13, 0.17)

-- Stage floor / pedestal shadow
local shadow = display.newCircle(cx, cy + 180, 160)
shadow.yScale = 0.25
shadow:setFillColor(0, 0, 0, 0.35)

-- Main character container group
local stageGroup = display.newGroup()

-- UI layer
local uiGroup = display.newGroup()

-- Available sample models
local models = {
	{ name = "Robot Idle", path = "spla/robot_idle", scale = 0.75 },
	{ name = "Ranger (Skins & Variants)", path = "spla/ranger_idle", scale = 0.85 },
	{ name = "Windmill", path = "spla/windmill", scale = 1.0 },
	{ name = "Robot (Multi-Skin)", path = "spla/robot_idle_skins", scale = 0.75 },
	{ name = "Robot (Z-Ordering)", path = "spla/robot_idle_z", scale = 0.75 },
	{ name = "Robot (Multi-Anim)", path = "spla/robot", scale = 0.75 },
	{ name = "Tint Demo", path = "spla/tint_idle", scale = 0.85 },
}

local currentModelIndex = 1
local currentCharacter = nil
local currentSkinIndex = 1
local currentAnimIndex = 1
local currentVariantIndex = 0
local currentTintIndex = 1

local tintPresets = {
	{ name = "Original", r = 1.0, g = 1.0, b = 1.0 },
	{ name = "Ruby Red", r = 1.0, g = 0.4, b = 0.4 },
	{ name = "Emerald Green", r = 0.4, g = 1.0, b = 0.5 },
	{ name = "Cyber Cyan", r = 0.4, g = 0.8, b = 1.0 },
	{ name = "Gold Amber", r = 1.0, g = 0.85, b = 0.3 },
}

local speeds = { 0.25, 0.5, 1.0, 2.0 }
local speedIndex = 3

-- UI Text Elements
local titleText = display.newText({
	parent = uiGroup,
	text = "SpriteLoop for Solar2D",
	x = minX + 20,
	y = minY + 30,
	font = native.systemFontBold,
	fontSize = 22,
	align = "left",
})
titleText.anchorX = 0
titleText:setFillColor(0.95, 0.95, 0.98)

local modelText = display.newText({
	parent = uiGroup,
	text = "Model: " .. models[1].name,
	x = minX + 20,
	y = minY + 60,
	font = native.systemFont,
	fontSize = 16,
	align = "left",
})
modelText.anchorX = 0
modelText:setFillColor(0.65, 0.75, 0.95)

local statusText = display.newText({
	parent = uiGroup,
	text = "Status: Loading...",
	x = minX + 20,
	y = minY + 85,
	font = native.systemFont,
	fontSize = 14,
	align = "left",
})
statusText.anchorX = 0
statusText:setFillColor(0.8, 0.8, 0.8)

local eventLogText = display.newText({
	parent = uiGroup,
	text = "Event Log: Listening...",
	x = minX + 20,
	y = maxY - 30,
	font = native.systemFont,
	fontSize = 13,
	align = "left",
})
eventLogText.anchorX = 0
eventLogText:setFillColor(0.4, 0.9, 0.5)

-- Attachment item to demonstrate bone tracking (rendered in front of character)
local attachmentBadge = display.newGroup()
stageGroup:insert(attachmentBadge)

local badgeGlow = display.newCircle(attachmentBadge, 0, 0, 18)
badgeGlow:setFillColor(1, 0.85, 0.2, 0.35)

local badgeCore = display.newCircle(attachmentBadge, 0, 0, 9)
badgeCore:setFillColor(1, 0.85, 0.1)
badgeCore.strokeWidth = 2
badgeCore:setStrokeColor(1, 1, 1)

local badgeDot = display.newCircle(attachmentBadge, 0, 0, 3)
badgeDot:setFillColor(1, 0.2, 0.2)

attachmentBadge.isVisible = false

-- Helper function to create interactive UI buttons
local function createButton(parent, label, x, y, width, height, onClick)
	local btn = display.newGroup()
	parent:insert(btn)
	btn.x = x
	btn.y = y

	local r = display.newRoundedRect(btn, 0, 0, width, height, 6)
	r:setFillColor(0.22, 0.25, 0.32)
	r.strokeWidth = 1
	r:setStrokeColor(0.4, 0.45, 0.55)

	local txt = display.newText({
		parent = btn,
		text = label,
		x = 0,
		y = 0,
		font = native.systemFontBold,
		fontSize = 13,
		align = "center",
	})
	txt:setFillColor(0.9, 0.92, 0.96)

	function btn:setLabel(newLabel)
		txt.text = newLabel
	end

	function btn:touch(event)
		if event.phase == "began" then
			display.getCurrentStage():setFocus(self)
			self._isFocus = true
			r:setFillColor(0.35, 0.4, 0.52)
		elseif self._isFocus then
			if event.phase == "moved" then
				local bounds = self.contentBounds
				local inside = (event.x >= bounds.xMin and event.x <= bounds.xMax and
				                event.y >= bounds.yMin and event.y <= bounds.yMax)
				if not inside then
					r:setFillColor(0.22, 0.25, 0.32)
				else
					r:setFillColor(0.35, 0.4, 0.52)
				end
			elseif event.phase == "ended" or event.phase == "cancelled" then
				display.getCurrentStage():setFocus(nil)
				self._isFocus = false
				r:setFillColor(0.22, 0.25, 0.32)
				local bounds = self.contentBounds
				local inside = (event.x >= bounds.xMin and event.x <= bounds.xMax and
				                event.y >= bounds.yMin and event.y <= bounds.yMax)
				if inside and onClick then
					onClick(self)
				end
			end
		end
		return true
	end

	btn:addEventListener("touch", btn)
	return btn
end

-- Function to load and display a model
local playPauseBtn, skinBtn, animBtn, variantBtn, tintBtn, speedBtn

local function loadCharacterModel(index)
	currentModelIndex = index
	local modelDef = models[index]

	if currentCharacter then
		display.remove(currentCharacter)
		currentCharacter = nil
	end

	currentSkinIndex = 1
	currentAnimIndex = 1
	currentVariantIndex = 0
	currentTintIndex = 1

	modelText.text = string.format("Model (%d/%d): %s", currentModelIndex, #models, modelDef.name)
	statusText.text = "Loading package..."

	local ok, char = pcall(function()
		return spriteloop.new(modelDef.path, {
			x = cx,
			y = cy + 40,
			autoplay = true,
			playbackRate = speeds[speedIndex],
		})
	end)

	if not ok or not char then
		statusText.text = "Error: " .. tostring(char)
		statusText:setFillColor(1, 0.3, 0.3)
		return
	end

	currentCharacter = char
	stageGroup:insert(currentCharacter)
	currentCharacter:scale(modelDef.scale, modelDef.scale)

	-- Listen for SpriteLoop timeline & playback events
	currentCharacter:addEventListener("spriteloop", function(event)
		if event.phase == "event" then
			eventLogText.text = string.format("Event: '%s' [Data: %s] Frame: %d",
				event.eventName or event.name or "", tostring(event.eventData or ""), event.frame or 0)
			eventLogText:setFillColor(0.3, 1.0, 0.6)
		elseif event.phase == "loop" then
			eventLogText.text = string.format("Loop: %s (Frame: %d)", event.animation, event.frame or 0)
			eventLogText:setFillColor(0.6, 0.8, 1.0)
		elseif event.phase == "complete" then
			eventLogText.text = string.format("Complete: %s", event.animation)
			eventLogText:setFillColor(1.0, 0.8, 0.3)
		end
	end)

	-- Update button labels based on package capabilities
	local info = currentCharacter:getInfo()
	local skinCount = #info.skins
	local animCount = #info.animations
	local variantCount = #info.variants

	if skinBtn then
		skinBtn:setLabel(skinCount > 0 and ("Skin: " .. (info.skins[1] and info.skins[1].name or "Default")) or "No Skins")
	end
	if animBtn then
		animBtn:setLabel(animCount > 0 and ("Anim: " .. (info.animations[1] and info.animations[1].name or "Idle")) or "Anim: 1")
	end
	if variantBtn then
		variantBtn:setLabel(variantCount > 0 and ("Variant: (0/" .. variantCount .. ")") or "No Variants")
	end
	if tintBtn then
		tintBtn:setLabel("Tint: Original")
	end
	if playPauseBtn then
		playPauseBtn:setLabel("Pause")
	end

	statusText:setFillColor(0.8, 0.8, 0.8)
end

-- Create UI Control Layout
local btnW = 100
local btnH = 34
local padX = 10
local padY = 8

-- Row 1: Model Navigation & Playback Controls (Right Top)
local rightColX = maxX - btnW * 0.5 - 20
local topRowY = minY + 40

createButton(uiGroup, "Prev Model", rightColX - btnW - padX, topRowY, btnW, btnH, function()
	local idx = currentModelIndex - 1
	if idx < 1 then idx = #models end
	loadCharacterModel(idx)
end)

createButton(uiGroup, "Next Model", rightColX, topRowY, btnW, btnH, function()
	local idx = currentModelIndex + 1
	if idx > #models then idx = 1 end
	loadCharacterModel(idx)
end)

-- Row 2: Playback Actions
playPauseBtn = createButton(uiGroup, "Pause", rightColX - btnW - padX, topRowY + (btnH + padY), btnW, btnH, function(btn)
	if not currentCharacter then return end
	if currentCharacter._isPlaying then
		currentCharacter:pause()
		btn:setLabel("Play")
	else
		currentCharacter:resume()
		btn:setLabel("Pause")
	end
end)

createButton(uiGroup, "Step Frame", rightColX, topRowY + (btnH + padY), btnW, btnH, function()
	if not currentCharacter then return end
	currentCharacter:pause()
	if playPauseBtn then playPauseBtn:setLabel("Play") end
	local info = currentCharacter:getInfo()
	local nextFrame = (info.currentFrame + 1)
	currentCharacter:setFrame(nextFrame)
end)

-- Row 3: Speed & Animation
speedBtn = createButton(uiGroup, "Speed: 1.0x", rightColX - btnW - padX, topRowY + (btnH + padY) * 2, btnW, btnH, function(btn)
	if not currentCharacter then return end
	speedIndex = (speedIndex % #speeds) + 1
	local spd = speeds[speedIndex]
	currentCharacter:setPlaybackRate(spd)
	btn:setLabel(string.format("Speed: %.1fx", spd))
end)

animBtn = createButton(uiGroup, "Anim", rightColX, topRowY + (btnH + padY) * 2, btnW, btnH, function(btn)
	if not currentCharacter then return end
	local info = currentCharacter:getInfo()
	if #info.animations == 0 then return end
	currentAnimIndex = (currentAnimIndex % #info.animations) + 1
	local a = info.animations[currentAnimIndex]
	currentCharacter:play(a.name, { loop = a.loop })
	btn:setLabel("Anim: " .. a.name)
	if playPauseBtn then playPauseBtn:setLabel("Pause") end
end)

-- Row 4: Skins & Variants
skinBtn = createButton(uiGroup, "Skin", rightColX - btnW - padX, topRowY + (btnH + padY) * 3, btnW, btnH, function(btn)
	if not currentCharacter then return end
	local info = currentCharacter:getInfo()
	if #info.skins == 0 then return end
	currentSkinIndex = (currentSkinIndex % #info.skins) + 1
	local s = info.skins[currentSkinIndex]
	currentCharacter:setSkin(s.name)
	btn:setLabel("Skin: " .. s.name)
end)

variantBtn = createButton(uiGroup, "Variant", rightColX, topRowY + (btnH + padY) * 3, btnW, btnH, function(btn)
	if not currentCharacter then return end
	local info = currentCharacter:getInfo()
	if #info.variants == 0 then return end
	currentVariantIndex = currentVariantIndex + 1
	if currentVariantIndex > #info.variants then
		currentVariantIndex = 0
		currentCharacter:clearVariants()
		btn:setLabel("Variant: Default")
	else
		local v = info.variants[currentVariantIndex]
		currentCharacter:setVariant(v.part, v.name)
		btn:setLabel("Var: " .. string.sub(v.name, 1, 9))
	end
end)

-- Row 5: Tint & Bone Attachment Toggle
tintBtn = createButton(uiGroup, "Tint: Original", rightColX - btnW - padX, topRowY + (btnH + padY) * 4, btnW, btnH, function(btn)
	if not currentCharacter then return end
	currentTintIndex = (currentTintIndex % #tintPresets) + 1
	local t = tintPresets[currentTintIndex]
	currentCharacter:setTint(t.r, t.g, t.b)
	btn:setLabel("Tint: " .. t.name)
end)

local isAttachmentActive = false
local attachBtn = createButton(uiGroup, "Track Bone: Off", rightColX, topRowY + (btnH + padY) * 4, btnW, btnH, function(btn)
	isAttachmentActive = not isAttachmentActive
	attachmentBadge.isVisible = isAttachmentActive
	btn:setLabel(isAttachmentActive and "Track Bone: On" or "Track Bone: Off")
end)

-- Row 6: Sub-frame Interpolation Toggle
local isInterpolating = true
local interpBtn = createButton(uiGroup, "Smooth: On", rightColX - btnW - padX, topRowY + (btnH + padY) * 5, btnW, btnH, function(btn)
	if not currentCharacter then return end
	isInterpolating = not isInterpolating
	currentCharacter:setInterpolated(isInterpolating)
	btn:setLabel(isInterpolating and "Smooth: On" or "Smooth: Off")
end)

-- Drag character interactively on screen
local isDragging = false
local dragOffsetX, dragOffsetY = 0, 0

local function onStageTouch(event)
	if not currentCharacter then return end
	if event.phase == "began" then
		isDragging = true
		dragOffsetX = currentCharacter.x - event.x
		dragOffsetY = currentCharacter.y - event.y
		shadow.x = currentCharacter.x
	elseif isDragging then
		if event.phase == "moved" then
			currentCharacter.x = event.x + dragOffsetX
			currentCharacter.y = event.y + dragOffsetY
			shadow.x = currentCharacter.x
		elseif event.phase == "ended" or event.phase == "cancelled" then
			isDragging = false
		end
	end
	return true
end
bg:addEventListener("touch", onStageTouch)

-- Update status text and bone attachment tracking on each frame
Runtime:addEventListener("enterFrame", function()
	if currentCharacter and currentCharacter.getInfo then
		local info = currentCharacter:getInfo()
		local animName = info.currentAnimation or "None"
		statusText.text = string.format("Anim: %s | Frame: %d | Playing: %s",
			animName, info.currentFrame or 0, tostring(info.isPlaying))

		-- Demonstrate attachment tracking to a prominent bone
		if isAttachmentActive and #info.parts > 0 then
			local targetPart = nil
			for _, p in ipairs(info.parts) do
				local pNameLower = string.lower(p.name)
				if p.kind == "empty" or string.find(pNameLower, "head") or string.find(pNameLower, "hand") or string.find(pNameLower, "eye") then
					targetPart = p
					break
				end
			end
			targetPart = targetPart or info.parts[1]

			local transform = currentCharacter:getPartTransform(targetPart.name, { origin = "pivot" })
			if transform then
				local scale = models[currentModelIndex].scale or 1.0
				attachmentBadge.x = currentCharacter.x + transform.x * scale
				attachmentBadge.y = currentCharacter.y + transform.y * scale
				attachmentBadge.rotation = transform.rotation
				attachmentBadge:toFront()
			end
		end
	end
end)

-- Keyboard shortcuts support
Runtime:addEventListener("key", function(event)
	if event.phase == "down" then
		if event.keyName == "space" then
			if playPauseBtn then playPauseBtn:touch({ phase = "began" }); playPauseBtn:touch({ phase = "ended" }) end
		elseif event.keyName == "right" then
			if currentCharacter then
				currentCharacter:pause()
				local info = currentCharacter:getInfo()
				currentCharacter:setFrame(info.currentFrame + 1)
			end
		elseif event.keyName == "left" then
			if currentCharacter then
				currentCharacter:pause()
				local info = currentCharacter:getInfo()
				currentCharacter:setFrame(math.max(0, info.currentFrame - 1))
			end
		elseif event.keyName == "n" then
			local idx = currentModelIndex + 1
			if idx > #models then idx = 1 end
			loadCharacterModel(idx)
		elseif event.keyName == "s" then
			if skinBtn then skinBtn:touch({ phase = "began" }); skinBtn:touch({ phase = "ended" }) end
		elseif event.keyName == "v" then
			if variantBtn then variantBtn:touch({ phase = "began" }); variantBtn:touch({ phase = "ended" }) end
		elseif event.keyName == "t" then
			if tintBtn then tintBtn:touch({ phase = "began" }); tintBtn:touch({ phase = "ended" }) end
		end
	end
end)

-- Initial Load
loadCharacterModel(1)