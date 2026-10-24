--[[
  PagePngExport - Ctrl+E exports the current page as a PNG.

  Fixed settings:
      format      PNG
      resolution  150 dpi
      range       current page only
      background  transparent (no paper / grid / PDF background)
      cropping    transparent rows above/below the content are trimmed

  Flow: Ctrl+E -> "Save" file dialog (suggested name next to the .xopp)
        -> page exported -> empty top/bottom margins cut off.

  OI teaching bridge (shared mailbox with the VS Code teaching assistant):
      - The assistant's "Export to class notes" writes the A4 PNGs to img/
        and then writes their absolute paths to
            %TEMP%\oi-assist-xournalpp\latest.txt
        (one path per line, '#' lines are comments).
      - "Insert latest whiteboard image" (F8) reads that file and
        appends the images as full A4 pages. The current page is reused when
        it is empty; otherwise a page is inserted after it.
      - On such a page, Ctrl+E does not open the save dialog. It writes the
        annotated page straight back to the source PNG (150 dpi, background
        none, no cropping) so the Typst note picks up the annotations.
        The write-back is only allowed while the page still contains the
        exact image element inserted by this plugin; if the image was removed,
        moved to another page, or the document was reloaded, the normal save
        dialog is used instead.

  Cropping is done by trim.ps1, which ships with this plugin and uses
  System.Drawing that comes with Windows. Width is preserved; only the
  height shrinks. Set TRIM_ENABLED = false to keep full pages. Cropping is
  intentionally skipped for the bridge write-back: the note image is A4 and
  trimming would change its height in the note.

  Plugin folders (as used by this build):
      Windows: %LOCALAPPDATA%\xournalpp\plugins\PagePngExport\
      Linux:   ~/.config/xournalpp/plugins/PagePngExport/
      macOS:   ~/Library/Application Support/xournalpp/plugins/PagePngExport/
]]

local DPI = 150
local BACKGROUND = "none" -- "none" = transparent, "unruled" = white, "all" = paper
local ACCELERATOR = "<Ctrl>e"
local INSERT_ACCELERATOR = "F8"

local TRIM_ENABLED = true
local TRIM_MARGIN = 10 -- pixels kept above/below the content at 150 dpi

-- Images inserted by "Insert latest whiteboard image". Each entry keeps the
-- element reference returned by app.addImages; matching that reference against
-- the current page is what makes write-back safe when pages are inserted or
-- deleted (page numbers alone would go stale).
local bridged = {}

local isWindows = package.config:sub(1, 1) == "\\"

local function pluginDir()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) ~= "@" then
    return nil
  end
  return source:sub(2):match("^(.*)[/\\][^/\\]*$")
end

----------------------------------------------------------------------
-- File name helpers
----------------------------------------------------------------------

-- "C:\dir\note.xopp" -> "C:\dir", "note.xopp" -> "note"
local function splitPath(path)
  local dir, name = path:match("^(.*)[/\\]([^/\\]*)$")
  if not name then
    return "", path
  end
  return dir, name
end

-- "note.xopp" -> "note", "a.b.xopp" -> "a.b"
local function stem(name)
  return (name:gsub("%.[^.]+$", ""))
end

--- Suggested output path: next to the open .xopp, or a plain name for
--- unsaved documents (the dialog then keeps its own directory).
local function suggestedName()
  local doc = app.getDocumentStructure()
  local page = doc.currentPage or 1
  local source = doc.xoppFilename or ""

  if source ~= "" then
    local dir, name = splitPath(source)
    return dir .. "/" .. stem(name) .. "_page" .. page .. ".png"
  end

  return "untitled_page" .. page .. ".png"
end

local function withPngExtension(path)
  if path:lower():sub(-4) == ".png" then
    return path
  end
  -- Drop a foreign extension such as ".jpg" instead of producing "x.jpg.png"
  local dir, name = splitPath(path)
  local base = stem(name)
  if dir == "" then
    return base .. ".png"
  end
  return dir .. "/" .. base .. ".png"
end

local function baseName(path)
  local _, name = splitPath(path)
  return name
end

----------------------------------------------------------------------
-- Shared mailbox (VS Code teaching assistant -> Xournal++)
----------------------------------------------------------------------

local function mailboxPath()
  local dir = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR")
  if not dir or dir == "" then
    if package.config:sub(1, 1) == "/" then
      dir = "/tmp"
    else
      return nil
    end
  end
  dir = dir:gsub("[/\\]+$", "")
  local sep = package.config:sub(1, 1)
  return dir .. sep .. "oi-assist-xournalpp" .. sep .. "latest.txt"
end

local function readMailbox()
  local file = mailboxPath()
  if not file then
    return {}
  end
  local handle = io.open(file, "r")
  if not handle then
    return {}
  end
  local files = {}
  for rawLine in handle:lines() do
    local line = rawLine:gsub("\r$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      files[#files + 1] = line
    end
  end
  handle:close()
  return files
end

local function log(message)
  local ok, dir = pcall(app.getFolder, "state")
  if not ok then
    return
  end
  local handle = io.open(dir .. "/bridge.log", "a")
  if not handle then
    return
  end
  handle:write(os.date("[%Y-%m-%d %H:%M:%S] "), message, "\n")
  handle:close()
end

--- Non-blocking success feedback. A dialog would need a click after every
--- page; the tray balloon disappears on its own.
local function toast(message)
  if not isWindows then
    return
  end

  local dir = pluginDir()
  local ok, stateDir = pcall(app.getFolder, "state")
  if not dir or not ok then
    return
  end

  -- The command goes through cmd.exe; reject paths it would mangle.
  if dir:find('"', 1, true) or dir:find("%", 1, true) or
     stateDir:find('"', 1, true) or stateDir:find("%", 1, true) then
    log("toast skipped: unsupported character in plugin/state path")
    return
  end

  local messageFile = stateDir .. "/toast.txt"
  local handle = io.open(messageFile, "w")
  if not handle then
    return
  end
  handle:write(message)
  handle:close()

  -- start /B returns immediately; the PowerShell helper outlives this call.
  local cmd = string.format(
    'start "" /B powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%s\\toast.ps1" -Path "%s"',
    dir, messageFile)
  os.execute(cmd)
end

local function currentPageInfo()
  local doc = app.getDocumentStructure()
  return doc.currentPage, doc.pages[doc.currentPage]
end

--- Pages whose background is itself an image/PDF are not safe to insert onto:
--- the whiteboard image would be laid over an unrelated background.
local function hasSpecialBackground(page)
  return page ~= nil and (page.pageTypeFormat == ":image" or page.pageTypeFormat == ":pdf")
end

--- True when the current page has anything on it. The "page" scope releases
--- the current selection (that is how the C++ side enumerates elements), so
--- callers must be ready for a pending selection to be finalized.
local function pageHasContent()
  local _, page = currentPageInfo()
  if hasSpecialBackground(page) then
    return true
  end
  local okStrokes, strokes = pcall(app.getStrokes, "page")
  local okTexts, texts = pcall(app.getTexts, "page")
  local okImages, images = pcall(app.getImages, "page")
  return (okStrokes and type(strokes) == "table" and #strokes > 0)
      or (okTexts and type(texts) == "table" and #texts > 0)
      or (okImages and type(images) == "table" and #images > 0)
end

--- Inserts a new page after the current one and returns its number, or nil.
local function addPageAfterCurrent()
  local before = currentPageInfo()
  if not before then
    return nil
  end

  app.activateAction("new-page-after")
  local after = currentPageInfo()
  if after == before then
    -- Some builds do not move to the new page as a side effect of the action.
    app.setCurrentPage(before + 1)
    after = currentPageInfo()
  end

  if after == before then
    return nil
  end

  -- new-page-after copies the background of the current page. For a bridged
  -- whiteboard page the image is an element, so a plain page is the right
  -- canvas; this also keeps a PDF/image background from leaking in.
  local _, page = currentPageInfo()
  if hasSpecialBackground(page) then
    app.changeCurrentPageBackground("plain")
  end
  app.refreshPage()

  return after
end

--- Adds one image to the current page, filling it while preserving the aspect
--- ratio. Returns the page number and the element reference used for write-back.
local function insertImageOnCurrentPage(path)
  local pageNo, page = currentPageInfo()
  if not page then
    return nil, "no current page"
  end

  local ok, refs = pcall(app.addImages, {
    images = {{
      path = path,
      x = 0,
      y = 0,
      -- app.addImages takes integers (luaL_optinteger). Rounding up and
      -- letting automaticScaling clamp to the page keeps the image inside
      -- the page with only a sub-pixel gap.
      maxWidth = math.ceil(page.pageWidth),
      maxHeight = math.ceil(page.pageHeight),
      aspectRatio = true,
    }},
    allowUndoRedoAction = "grouped",
  })
  if not ok then
    return nil, tostring(refs)
  end

  local ref = refs and refs[1]
  if type(ref) == "string" then
    return nil, ref
  end
  if ref == nil then
    return nil, "image insertion returned no reference"
  end

  -- app.addImages leaves the image in a floating selection. Releasing the
  -- selection moves the same element into the layer, so the reference above
  -- stays valid for the later write-back check.
  app.clearSelection()
  app.refreshPage()
  return pageNo, ref
end

--- Finds the source image for the current page by element identity.
--- Returns the matching entry, or nil plus a reason when the page is unsafe
--- to write back (no bridge image, or more than one).
local function bridgedTargetOnCurrentPage()
  if #bridged == 0 then
    return nil
  end

  local ok, images = pcall(app.getImages, "page")
  if not ok or type(images) ~= "table" then
    return nil
  end

  local onPage = {}
  for _, image in ipairs(images) do
    if image.ref ~= nil then
      onPage[image.ref] = true
    end
  end

  local found = nil
  for _, entry in ipairs(bridged) do
    if entry.ref ~= nil and onPage[entry.ref] then
      if found then
        return nil, "multiple"
      end
      found = entry
    end
  end
  return found
end

----------------------------------------------------------------------
-- Cropping
----------------------------------------------------------------------

--- Removes transparent rows above and below the content, in place.
--- Returns a status string, or nil when nothing was done.
local function trimVertically(path)
  if not TRIM_ENABLED or not isWindows then
    return nil
  end

  local dir = pluginDir()
  if not dir then
    return nil
  end

  -- The command string goes through cmd.exe, so refuse paths that would
  -- break quoting or be expanded by the shell.
  if path:find('"', 1, true) or path:find("%", 1, true) then
    return "not cropped (unsupported character in the file name)"
  end

  -- stderr must be redirected into stdout, otherwise a failing script
  -- leaves us with an empty message. `2>&1` is understood by cmd.exe.
  local cmd = string.format(
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%s\\trim.ps1" -Path "%s" -Margin %d -VerticalOnly 2>&1',
    dir, path, TRIM_MARGIN)

  local pipe = io.popen(cmd, "r")
  if not pipe then
    return "not cropped (could not start PowerShell)"
  end

  local output = (pipe:read("*a") or ""):gsub("%s+$", "")
  local ok = pipe:close()

  if not ok then
    return "cropping failed: " .. (output ~= "" and output or "unknown error")
  end
  if output == "" then
    return nil
  end
  return output
end

----------------------------------------------------------------------
-- Export
----------------------------------------------------------------------

local function exportCurrentPage(path, trim, quiet)
  local doc = app.getDocumentStructure()

  local ok, err = pcall(app.export, {
    outputFile = path,
    range = tostring(doc.currentPage),
    background = BACKGROUND,
    pngDpi = DPI,
  })

  if not ok then
    if not quiet then
      app.openDialog("PNG export failed:\n" .. tostring(err), {"OK"}, "", true)
    end
    return false, tostring(err)
  end

  if not trim then
    return true
  end

  local status = trimVertically(path)
  -- The image itself was written, so a cropping problem is only a warning.
  if status and status:find("^cropping failed") and not quiet then
    app.openDialog("PNG exported, but cropping failed:\n" .. status, {"OK"}, "", true)
  end
  return true
end

--- Writes the annotated current page back to the source PNG of a bridged page.
--- No cropping: the source is an A4 note image, and changing its height would
--- change the layout of the image in the Typst note.
local function writeBackBridgedPage(entry)
  local ok, err = exportCurrentPage(entry.path, false, true)
  if ok then
    log("write-back ok: " .. entry.path)
    toast("已回写：" .. baseName(entry.path))
    return true
  end
  log("write-back failed: " .. entry.path .. " - " .. tostring(err))
  return false, err
end

--- Reads the shared mailbox and appends every image as a full page.
function insertLatestWhiteboardImage()
  local files = readMailbox()
  if #files == 0 then
    app.openDialog(
      "No whiteboard image found.\n\n" ..
      "In VS Code, use \"Export to class notes\" first.\n" ..
      "The bridge looks for:\n" .. tostring(mailboxPath()),
      {"OK"}, "", true)
    return
  end

  local inserted = {}
  local errors = {}

  for index, path in ipairs(files) do
    if index > 1 or pageHasContent() then
      local page = addPageAfterCurrent()
      if not page then
        errors[#errors + 1] = path .. "\ncould not create a new page"
        break
      end
    end

    local pageNo, refOrError = insertImageOnCurrentPage(path)
    if pageNo then
      bridged[#bridged + 1] = { path = path, ref = refOrError, page = pageNo }
      inserted[#inserted + 1] = pageNo
      log(string.format("inserted %s on page %d", path, pageNo))
    else
      errors[#errors + 1] = path .. "\n" .. tostring(refOrError)
      log("insert failed: " .. path .. " - " .. tostring(refOrError))
    end
  end

  if inserted[1] then
    app.scrollToPage(inserted[1])
  end

  if #errors > 0 then
    app.openDialog(
      "Could not insert " .. #errors .. " image(s):\n\n" .. table.concat(errors, "\n\n"),
      {"OK"}, "", true)
  end
end

--- Explicit menu counterpart to the automatic write-back behind Ctrl+E.
function writeBackCurrentWhiteboardImage()
  local entry, reason = bridgedTargetOnCurrentPage()
  if not entry then
    local message
    if reason == "multiple" then
      message = "More than one bridged whiteboard image is on this page.\n" ..
                "Use Ctrl+E to export it with the normal save dialog instead."
    else
      message = "This page does not contain a bridged whiteboard image.\n\n" ..
                "Use Ctrl+E to export it as usual."
    end
    app.openDialog(message, {"OK"}, "", true)
    return
  end

  local ok, err = writeBackBridgedPage(entry)
  if not ok then
    app.openDialog("Could not write back to:\n" .. entry.path .. "\n\n" .. tostring(err),
                   {"OK"}, "", true)
  end
end

-- Called by the save dialog. An empty string means the user cancelled.
function onFileChosen(path)
  if path == nil or path == "" then
    return
  end
  exportCurrentPage(withPngExtension(path), true)
end

function onFileChosenFullPage(path)
  if path == nil or path == "" then
    return
  end
  exportCurrentPage(withPngExtension(path), false)
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------

function initUi()
  log("initUi: OI bridge ready")
  app.registerUi({
    menu = "Export current page as PNG",
    callback = "exportCurrentPagePng",
    accelerator = ACCELERATOR,
  })
  app.registerUi({
    menu = "Export current page as PNG (full page, no cropping)",
    callback = "exportCurrentPagePngFull",
  })
  app.registerUi({
    menu = "Insert latest whiteboard image (OI)",
    callback = "insertLatestWhiteboardImage",
    accelerator = INSERT_ACCELERATOR,
  })
  app.registerUi({
    menu = "Write back current whiteboard image (OI)",
    callback = "writeBackCurrentWhiteboardImage",
  })
end

--- Entry point behind Ctrl+E.
function exportCurrentPagePng()
  local entry, reason = bridgedTargetOnCurrentPage()
  if entry then
    local ok, err = writeBackBridgedPage(entry)
    if ok then
      return
    end
    app.openDialog(
      "Could not write back to the source image:\n" .. entry.path .. "\n\n" .. tostring(err) ..
      "\n\nThe save dialog will open instead.",
      {"OK"}, "", true)
  elseif reason == "multiple" then
    app.openDialog(
      "More than one bridged whiteboard image is on this page.\n" ..
      "The save dialog will open instead.",
      {"OK"}, "", true)
  end

  app.fileDialogSave("onFileChosen", suggestedName())
end

function exportCurrentPagePngFull()
  app.fileDialogSave("onFileChosenFullPage", suggestedName())
end
