--[[
  PluginStarter - a working skeleton for Xournal++ Lua plugins.

  Copy this folder, rename it, edit plugin.ini and replace the commands with
  your own. Everything in here runs on the current stable API.

  Install location on this Windows build:
      %LOCALAPPDATA%\xournalpp\plugins\PluginStarter\
  Linux:   ~/.config/xournalpp/plugins/PluginStarter/
  macOS:   ~/Library/Application Support/xournalpp/plugins/PluginStarter/
  Bundled: <install dir>/share/xournalpp/plugins/PluginStarter/
  After adding or editing a plugin, restart Xournal++ and tick it in
  Plugins > Plugin Manager.

  Rules that are easy to trip over:
    * main.lua is executed once at startup; initUi() is called right after.
    * app.registerUi() is only legal inside initUi(), else it raises an error.
    * There is no console output on Windows - use util.log().
    * Toolbar buttons must be dragged in from the toolbar customization
      dialog; their item id is "Plugin::<toolbarId>".
    * Elements returned by getStrokes()/getTexts() are read-only snapshots:
      change their tables, then re-add them to write changes back.
]]

local util = require("util")

-- Icons available in both bundled themes: xopp-tool-text, xopp-tool-link,
-- xopp-tool-math-tex, xopp-select-pdf-text-area, xopp-navigate-back, ...
local TOOLBAR_ICON = "xopp-tool-text"

-- Status text shown in the toolbar placeholder. Declared here so both
-- initUi() and the commands below can reach it.
local function setStatus(text)
  app.setPlaceholderValue("starter-status", text)
end

----------------------------------------------------------------------
-- UI registration
----------------------------------------------------------------------

function initUi()
  util.log("initUi() called")

  -- 1) A free-form label for the toolbar. It appears in the toolbar
  --    customization dialog under Plugins, id "Plugin::starter-status".
  app.registerPlaceholder("starter-status", "PluginStarter")

  -- 2) Menu entry with an accelerator key.
  app.registerUi({
    menu = "Show page info",
    callback = "showPageInfo",
    accelerator = "<Alt>i",
  })

  -- 3) Nested submenu: Plugins > PluginStarter > Edit > ...
  --    Use "/" for deeper nesting, e.g. parentPath = "Edit/Tools/Advanced".
  app.registerUi({
    menu = "Fit page to layer content",
    callback = "fitToLayer",
    parentPath = "Edit",
  })
  app.registerUi({
    menu = "Trim page to selection",
    callback = "trimToSelection",
    parentPath = "Edit",
  })

  -- 4) Toolbar button. Drag "Stamp page number" out of the toolbar
  --    customization dialog to make it visible; its id is
  --    "Plugin::starter-button".
  app.registerUi({
    menu = "Stamp page number",
    callback = "stampPageNumber",
    toolbarId = "starter-button",
    iconName = TOOLBAR_ICON,
  })

  -- 5) One callback shared by several entries via "mode". The mode value is
  --    passed as the single argument of the callback.
  app.registerUi({
    menu = "Recolor selection: red",
    callback = "recolorSelection",
    mode = 0xff0000,
    parentPath = "Mark",
  })
  app.registerUi({
    menu = "Recolor selection: blue",
    callback = "recolorSelection",
    mode = 0x0000ff,
    parentPath = "Mark",
  })

  -- 6) Debugging helpers.
  app.registerUi({
    menu = "Show plugin log",
    callback = "showLog",
    parentPath = "Debug",
  })
  app.registerUi({
    menu = "Write a test log entry",
    callback = "logTestEntry",
    parentPath = "Debug",
  })

  setStatus(util.pageSummary())
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------

function showPageInfo()
  local summary = util.pageSummary()
  setStatus(summary)
  util.log("page info: %s", summary)

  local bounds = util.contentBounds("page")
  local detail
  if bounds then
    detail = string.format(
      "\n\nElements on this page: %d\nContent box: x=%.1f y=%.1f  w=%.1f h=%.1f",
      bounds.count, bounds.x, bounds.y, bounds.w, bounds.h)
  else
    detail = "\n\nThis page is empty."
  end

  app.openDialog(summary .. detail, {"OK"}, "", false)
end

--- Grow (or shrink) the page to the bounding box of the current layer.
--- The layer content is redrawn on a new layer so the original stays intact.
function fitToLayer()
  local bounds = util.contentBounds("layer")
  if not bounds then
    app.openDialog("The current layer is empty.", {"OK"}, "", true)
    return
  end

  local pad = 10
  local strokes = app.getStrokes("layer")

  for _, s in ipairs(strokes) do
    s.ref = nil -- read-only handle; drop it before re-adding
    for i = 1, #s.x do
      s.x[i] = s.x[i] - bounds.x + pad
      s.y[i] = s.y[i] - bounds.y + pad
    end
  end

  app.setLayerVisibility(false)
  app.activateAction("layer-new-above-current")
  app.setCurrentLayerName("fitted")
  app.addStrokes({strokes = strokes, allowUndoRedoAction = "grouped"})

  app.setPageSize(bounds.w + 2 * pad, bounds.h + 2 * pad)
  app.refreshPage()

  local msg = string.format("Page resized to %.0f x %.0f pt", bounds.w + 2 * pad, bounds.h + 2 * pad)
  util.log(msg)
  setStatus(msg)
end

--- Shrink the page to the selection plus a small margin.
function trimToSelection()
  local bounds = util.contentBounds("selection")
  if not bounds then
    app.openDialog("Nothing is selected.", {"OK"}, "", true)
    return
  end

  local pad = 10
  app.setPageSize(bounds.w + 2 * pad, bounds.h + 2 * pad)
  app.refreshPage()

  local msg = string.format("Page trimmed to %.0f x %.0f pt", bounds.w + 2 * pad, bounds.h + 2 * pad)
  util.log(msg)
  setStatus(msg)
end

--- Write text into the document: "n / total" in the lower right corner.
function stampPageNumber()
  local d = app.getDocumentStructure()
  local page = d.pages[d.currentPage]
  if not page then return end

  local label = string.format("%d / %d", d.currentPage, #d.pages)

  app.addTexts({
    texts = {{
      text = label,
      font = {name = "Sans", size = 10},
      color = 0x666666,
      x = page.pageWidth - 60,
      y = page.pageHeight - 20,
    }},
    allowUndoRedoAction = "grouped",
  })
  app.refreshPage()

  util.log("stamped page label %s", label)
  setStatus(util.pageSummary())
end

--- "mode" callback: recolor the selection. Uses the built-in action so
--- the change lands in the undo history.
function recolorSelection(color)
  if util.countElements("selection", "strokes") == 0
     and util.countElements("selection", "texts") == 0 then
    app.openDialog("Select something first.", {"OK"}, "", true)
    return
  end

  app.changeToolColor({color = color, selection = true})
  app.refreshPage()

  util.log("recolored selection to 0x%06x", color)
  setStatus(string.format("Selection color: #%06x", color))
end

function showLog()
  app.openDialog(util.logTail(30), {"OK"}, "", false)
end

function logTestEntry()
  local msg = util.log("test entry on %s", util.pageSummary())
  app.openDialog("Appended to:\n" .. tostring(util.logPath()) ..
                 "\n\n" .. msg, {"OK"}, "", false)
end
