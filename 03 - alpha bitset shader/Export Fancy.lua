-- number of color shades per color in palette
local paletteBlockSize = 6
-- the distance between two dark values, must be < 255 / paletteBlockSize
local darkBandSize = 40
-- offset from the dark band root for each layer of color replacement
local replacementColorOffset = 2

local sprite = app.activeSprite
if not sprite then
    app.alert { title = "Export", text = "Cannot export in home screen.", buttons = { "&Close" } }
end

-- stores color-to-index mapping
-- you can lookup palette index by calling paletteMap[color]
local paletteMap = {}
local palette = sprite.palettes[1]
for colorIndex = 0, #palette - 1 do
    local color = palette:getColor(colorIndex).rgbaPixel
    paletteMap[color] = colorIndex
end

-- stores frame-to-tag mapping
-- you can lookup tag by calling tagMap[frameIndex]
local tagMap = {}
for tagIndex, tag in ipairs(sprite.tags) do
    for frameIndex = tag.fromFrame.frameNumber, tag.toFrame.frameNumber do
        tagMap[frameIndex] = tag
    end
end

-- returns a color int at the given global location, but within the cel
-- returns color 0 in case it's outside of cel bounds
function celPixel(cel, x, y, layerAlpha)
    if x < cel.position.x or y < cel.position.y or x >= cel.position.x + cel.image.width or y >= cel.position.y + cel.image.height then
        return 0
    end
    local pixel = cel.image:getPixel(x - cel.position.x, y - cel.position.y)
    if cel.opacity == 255 and layerAlpha == 255 then
        return pixel
    else
        local sourceColor = Color(pixel)
        local totalAlpha = math.floor((layerAlpha / 255.0) * (sourceColor.alpha / 255.0) * (cel.opacity / 255.0) * 255.0)
        local totalColor = Color(sourceColor.red, sourceColor.green, sourceColor.blue, totalAlpha)
        return totalColor.rgbaPixel
    end
end

-- returns the location of a pixel in cel that has a color
function searchCelForPixel(cel)
    local source = cel.image
    for x = 0, source.width - 1 do
        for y = 0, source.height - 1 do
            local pixel = source:getPixel(x, y)
            if app.pixelColor.rgbaA(pixel) > 0 then
                return { x = x + cel.position.x, y = y + cel.position.y }
            end
        end
    end
    return nil
end

-- draws the given cel at the given output image
-- does some magic with color replacements, it's going to be in deepity #2
function drawMain(sourceCel, output, layerAlpha, colorLayers, frameIndex)
    for x = 0, output.width - 1 do
        for y = 0, output.height - 1 do
            local sourcePixel = celPixel(sourceCel, x, y, layerAlpha)
            local sourceAlpha = app.pixelColor.rgbaA(sourcePixel)
            if sourceAlpha > 0 then

                -- find the index of the color change layer that overlaps with current pixel
                local colorIndex = -1
                for colorIndexCurrent, colorLayer in ipairs(colorLayers) do
                    local colorCel = colorLayer:cel(frameIndex)
                    if colorCel ~= nil then
                        local colorPixel = celPixel(colorCel, x, y, layerAlpha)
                        if app.pixelColor.rgbaA(colorPixel) > 0 then
                            colorIndex = colorIndexCurrent - 1
                        end
                    end
                end

                local pixel = sourcePixel
                if colorIndex >= 0 then
                    local paletteIndex = paletteMap[pixel]
                    if paletteIndex == nil then
                        app.alert("missing palette index for frame [" .. frameIndex .. "] at [" .. x .. "," .. y .. "]")
                    end
                    local darkIndex = paletteIndex % paletteBlockSize
                    local colorValue = darkBandSize * darkIndex + replacementColorOffset * colorIndex
                    local replacementColor = Color { r = colorValue, g = colorValue, b = colorValue, a = sourceAlpha }
                    pixel = replacementColor.rgbaPixel
                end

                output:drawPixel(x, y, pixel)
            end
        end
    end
end

-- draws the alpha layer in the image
-- this magic will be covered in deepity #3
function drawAlpha(sourceCel, output)
    for x = 0, output.width - 1 do
        for y = 0, output.height - 1 do
            local sourcePixel = celPixel(sourceCel, x, y, 255)
            if app.pixelColor.rgbaA(sourcePixel) > 0 then
                local paletteIndex = paletteMap[sourcePixel]
                local red = paletteIndex * 4
                local alphaColor = Color { r = red, g = 0, b = 0, a = 255 }
                output:drawPixel(x, y, alphaColor)
            end
        end
    end
end

-- lua thing, lets you type "for x in values(list)" instead of "for _, x in ipairs(list)"
function values(t)
    local i = 0
    return function()
        i = i + 1;
        return t[i]
    end
end

-- returns true if given string starts with the other string
function stringStarts(string, start)
    return string.sub(string, 1, string.len(start)) == start
end

local path, title = sprite.filename:match("^(.+[/\\])(.-).([^.]*)$")
local frameCount = #sprite.frames

-- counters will display message after the export, I use it to debug
local exportedGroupCount = 0
local exportedCelCount = 0
local exportedImageGrid = 0

-- find all root groups - these will be exported ad separate images
local rootGroups = {}
for _, rootGroup in ipairs(sprite.layers) do
    if rootGroup.isVisible and rootGroup.isGroup and not stringStarts(rootGroup.name, "-") then
        table.insert(rootGroups, rootGroup)
    end
end

for rootGroup in values(rootGroups) do
    -- count the number of non empty frames in the group
    -- this will be needed to calculate image dimensions
    local rootFrameCount = 0
    for frameIndex, frame in ipairs(sprite.frames) do
        local hasFrame = false
        for layer in values(rootGroup.layers) do
            local cel = layer:cel(frameIndex)
            if cel ~= nil and layer.isVisible and not stringStarts(layer.name, "-") then
                hasFrame = true
            end
        end
        if hasFrame then
            rootFrameCount = rootFrameCount + 1
        end
    end

    -- skip groups that are completely empty
    if rootFrameCount > 0 then
        exportedGroupCount = exportedGroupCount + 1
        -- calculate how many cells horizontally and vertically with the group have
        local gridSize = math.ceil(math.sqrt(rootFrameCount))
        if gridSize > exportedImageGrid then
            exportedImageGrid = gridSize
        end

        -- start writing sprite data to the file
        local imageOutputPath = path .. title .. "-" .. rootGroup.name .. ".png"
        local dataOutputPath = path .. title .. "-" .. rootGroup.name .. ".txt"
        local alphaOutputPath = path .. title .. "-" .. rootGroup.name .. "-alpha.png"
        local groupFile = io.open(dataOutputPath, "w")
        groupFile:write("spriteWidth=" .. sprite.width .. "\n")
        groupFile:write("spriteHeight=" .. sprite.height .. "\n")
        groupFile:write("\n")
        groupFile:write("frameCount=" .. #sprite.frames .. "\n")
        groupFile:write("frameDurations=")
        for frameIndex, frame in ipairs(sprite.frames) do
            groupFile:write(math.floor(frame.duration * 1000))
            if frameIndex ~= frameCount then
                groupFile:write(",")
            end
        end
        groupFile:write("\n\n")
        groupFile:write("cellsPerSide=" .. gridSize .. "\n")
        groupFile:write("cellsTotalAmount=" .. rootFrameCount .. "\n")
        groupFile:write("\n")
        groupFile:write("tagCount=" .. #sprite.tags .. "\n")
        for tagIndex, tag in ipairs(sprite.tags) do
            groupFile:write("tag." .. (tagIndex - 1) .. ".name=" .. tag.name .. "\n")
            groupFile:write("tag." .. (tagIndex - 1) .. ".range=" .. (tag.fromFrame.frameNumber - 1) .. ":" .. (tag.toFrame.frameNumber - 1) .. "\n")
        end

        -- prepare color replacement layers and alpha
        local colorLayers = {}
        local alphaPresent = false
        local alphaLayer
        for layer in values(rootGroup.layers) do
            for index = 0, 4 do
                if layer.name == "-color" .. index then
                    table.insert(colorLayers, layer)
                end
            end
            if (layer.name == "-alpha") then
                alphaPresent = true
                alphaLayer = layer
            end
        end

        -- generate the output image for the group
        local groupImage = Image(sprite.width * gridSize, sprite.height * gridSize)
        local alphaImage = Image(sprite.width * gridSize, sprite.height * gridSize)
        local groupOffset = 0
        groupFile:write("cellPositions=")
        for frameIndex, frame in ipairs(sprite.frames) do
            local hasCels = false
            local frameImage = Image(sprite.width, sprite.height)
            local alphaFrameImage = Image(sprite.width, sprite.height)
            for layer in values(rootGroup.layers) do
                local mainCel = layer:cel(frameIndex)
                local alphaCel
                if alphaPresent then
                    alphaCel = alphaLayer:cel(frameIndex)
                end
                if layer.isVisible and not stringStarts(layer.name, "-") and mainCel ~= nil then
                    drawMain(mainCel, frameImage, layer.opacity, colorLayers, frameIndex)
                    if alphaCel ~= nil then
                        drawAlpha(alphaCel, alphaFrameImage)
                    end
                    hasCels = true
                    exportedCelCount = exportedCelCount + 1
                end
            end
            if tagMap[frameIndex] == nil then
                hasCels = false
            end
            if hasCels then
                local location = Point(groupOffset % gridSize * sprite.width, math.floor(groupOffset / gridSize) * sprite.height)
                groupImage:drawImage(frameImage, location)
                groupFile:write(groupOffset)
                if alphaPresent then
                    alphaImage:drawImage(alphaFrameImage, location)
                end
                groupOffset = groupOffset + 1
            else
                groupFile:write("*")
            end
            if frameIndex ~= frameCount then
                groupFile:write(",")
            end
        end
        groupFile:write("\n\n")

        -- find the anchor layer and export it's data
        for layer in values(rootGroup.layers) do
            if layer.name == "-anchor" then
                local position = searchCelForPixel(layer:cel(1))
                if position ~= nil then
                    groupFile:write("anchorPosition=" .. position.x .. ":" .. position.y .. "\n")
                end
            end
        end
        groupFile:write("\n")

        -- find the body part layers and export their data
        for layer in values(rootGroup.layers) do
            if stringStarts(layer.name, "-bp-") then
                local partName = string.sub(layer.name, 5, -1)
                groupFile:write("bp-" .. partName .. "=")
                for frameIndex, frame in ipairs(sprite.frames) do
                    local position = searchCelForPixel(layer:cel(frameIndex))
                    if position ~= nil then
                        groupFile:write(position.x .. ":" .. position.y)
                    else
                        groupFile:write("*")
                    end
                    if frameIndex ~= frameCount then
                        groupFile:write(",")
                    end
                end
                groupFile:write("\n")
            end
        end

        -- save the produced image
        groupImage:saveAs(imageOutputPath)
        if alphaPresent then
            alphaImage:saveAs(alphaOutputPath)
        end
    end
end

app.alert("groups [" .. exportedGroupCount .. "] cels [" .. exportedCelCount .. "] grid [" .. exportedImageGrid .. "x" .. exportedImageGrid .. "]")