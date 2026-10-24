--[[
  util.lua - shared helpers for the PluginStarter plugin.

  Files in the plugin folder are importable with require("util") because
  Plugin::addPluginToLuaPath() prepends "<plugin dir>/?.lua" to package.path.
  All plugins share one global namespace inside their own lua_State, so the
  module table pattern below keeps things tidy.
]]

local M = {}

----------------------------------------------------------------------
-- Logging
--
-- The Windows GUI build has no console, so print() goes nowhere visible.
-- Everything is appended to a file in the plugin's state folder.
----------------------------------------------------------------------

local logFile = nil

local function resolveLogFile()
  if logFile then return logFile end
  local ok, dir = pcall(app.getFolder, "state")
  if not ok then return nil end
  logFile = dir .. "/plugin-starter.log"
  return logFile
end

function M.logPath()
  return resolveLogFile()
end

function M.log(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  local path = resolveLogFile()
  if not path then return msg end

  local f = io.open(path, "a")
  if not f then return msg end
  f:write(os.date("[%Y-%m-%d %H:%M:%S] "), msg, "\n")
  f:close()
  return msg
end

function M.logTail(maxLines)
  local path = resolveLogFile()
  if not path then return "(no log file available)" end

  local f = io.open(path, "r")
  if not f then return "(log file does not exist yet)" end

  local kept = {}
  for line in f:lines() do
    kept[#kept + 1] = line
    if #kept > maxLines then table.remove(kept, 1) end
  end
  f:close()

  if #kept == 0 then return "(log is empty)" end
  return table.concat(kept, "\n")
end

----------------------------------------------------------------------
-- Document helpers
----------------------------------------------------------------------

--- Current page and totals, as one readable line.
function M.pageSummary()
  local d = app.getDocumentStructure()
  local p = d.pages[d.currentPage]
  if not p then return "No page selected" end

  return string.format("page %d/%d - %.1f x %.1f pt - background: %s",
                       d.currentPage, #d.pages, p.pageWidth, p.pageHeight,
                       tostring(p.pageTypeFormat))
end

--- Axis-aligned bounding box of strokes and texts in a given scope.
--- scope: "selection" | "layer" | "page"
--- Returns nil when the scope contains no elements (and nil + message when
--- the API refuses, e.g. "selection" with an empty selection).
---
--- Note: the "page" and "layer" scopes silently release the current
--- selection (that is how the C++ side enumerates elements), so querying
--- them is not side-effect free.
function M.contentBounds(scope)
  -- getStrokes("selection") raises a Lua error when nothing is selected,
  -- so both calls are guarded.
  local okStrokes, strokes = pcall(app.getStrokes, scope)
  local okTexts, texts = pcall(app.getTexts, scope)

  if not okStrokes and not okTexts then
    return nil, tostring(strokes)
  end

  local minX, minY = math.huge, math.huge
  local maxX, maxY = -math.huge, -math.huge
  local count = 0

  for _, s in ipairs(okStrokes and strokes or {}) do
    count = count + 1
    local half = (s.width or 0) / 2
    for i = 1, #s.x do
      local x, y = s.x[i], s.y[i]
      if x - half < minX then minX = x - half end
      if y - half < minY then minY = y - half end
      if x + half > maxX then maxX = x + half end
      if y + half > maxY then maxY = y + half end
    end
  end

  for _, t in ipairs(okTexts and texts or {}) do
    count = count + 1
    local w, h = t.width or 0, t.height or 0
    if t.x < minX then minX = t.x end
    if t.y < minY then minY = t.y end
    if t.x + w > maxX then maxX = t.x + w end
    if t.y + h > maxY then maxY = t.y + h end
  end

  if count == 0 then return nil end
  return {x = minX, y = minY, w = maxX - minX, h = maxY - minY, count = count}
end

--- Number of elements in a scope, without throwing on an empty selection.
function M.countElements(scope, kind)
  local ok, list = pcall(app[kind == "texts" and "getTexts" or "getStrokes"], scope)
  if not ok or type(list) ~= "table" then return 0 end
  return #list
end

return M
