-- Register all Toolbar actions and initialize all UI stuff
function initUi()
  app.registerUi({["menu"] = "Cycle through color list", ["callback"] = "cycle", ["accelerator"] = "<Alt>c"});
  -- if you want to have multiple color lists you must use the app.registerUi function multiple times
  -- with different callback functions and accelerators
end

-- start with first color
local currentColor = 0

-- Fetch the palette currently selected in the app (Preferences > Colors), so
-- the cycler cycles through the very colors shown in the UI (issue #7780)
local function getColorList()
  local palette = app.getColorPalette()
  if palette == nil or #palette == 0 then
    -- Fallback to the default palette if the API is unavailable or empty
    return {
      {["name"] = "black",      ["color"] = 0x000000},
      {["name"] = "green",      ["color"] = 0x008000},
      {["name"] = "lightblue",  ["color"] = 0x00c0ff},
      {["name"] = "lightgreen", ["color"] = 0x00ff00},
      {["name"] = "blue",       ["color"] = 0x3333cc},
      {["name"] = "gray",       ["color"] = 0x808080},
      {["name"] = "red",        ["color"] = 0xff0000},
      {["name"] = "magenta",    ["color"] = 0xff00ff},
      {["name"] = "orange",     ["color"] = 0xff8000},
      {["name"] = "yellow",     ["color"] = 0xffff00},
      {["name"] = "white",      ["color"] = 0xffffff}
    }
  end
  return palette
end

function cycle()
  local colorList = getColorList()
  -- % #colorList + 1 also wraps around when the palette changed size since the last call
  currentColor = currentColor % #colorList + 1
  -- apply color to currently used tool and allow coloring of elements from selections
  app.changeToolColor({["color"] = colorList[currentColor]["color"], ["selection"] = true})
  -- use app.changeToolColor({["color"] = colorList[currentColor]["color"], ["tool"] = "pen"})
  -- instead if you only want to change pen color
  -- similarly if you want to change highlighter color or the color from another tool with color capabilities.
end
