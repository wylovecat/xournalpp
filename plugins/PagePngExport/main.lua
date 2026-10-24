--[[
  PagePngExport - Ctrl+E exports the current page as a PNG.

  Fixed settings (normal Ctrl+E save dialog):
      format      PNG
      resolution  150 dpi
      range       current page only
      background  transparent (no paper / grid / PDF background)
      cropping    transparent rows above/below the content are trimmed

  Flow: Ctrl+E -> "Save" file dialog (suggested name next to the .xopp)
        -> page exported -> empty top/bottom margins cut off.

  OI teaching bridge (shared mailbox with the VS Code teaching assistant):

  Lecture flow (current):
      - Opening a problem board in VS Code creates the note placeholder and
        appends one line to
            %TEMP%\oi-assist-xournalpp\lecture-queue.txt
        The queue is a UTF-8, tab-separated/escaped text file with a version
        header. Its own path stays ASCII so Lua can open it on Chinese Windows
        note folders; the paths inside may be Chinese.
      - "Append queued problems to lecture" (F7, fallback Ctrl+Alt+L) reads
        the queue for the currently open .xopp, appends one A4 page per
        pending problem with the statement image at the top, and stores
            OI:<id>:<seq>:<dpi>:<base>
        in the page's <background name>. The extension watches the saved
        .xopp and syncs the note image list from these tokens.
      - Ctrl+E on a page with an OI token writes the page tight back to
        <lecture dir>/img/<base>.png (or -p2.png for seq 2). It works after
        restart and after pages are reordered because the token travels with
        the page. The note .typ is updated by VS Code after Ctrl+S.
      - A page without a token that follows a problem page can be bound as a
        continuation: Ctrl+E asks once, writes -pN.png, and sets the token.

  Legacy PNG bridge (still supported):
      - The assistant's old "Export to class notes" writes tight PNGs to img/
        and their absolute paths to %TEMP%\oi-assist-xournalpp\latest.txt.
      - "Insert latest whiteboard image" (F8 / Ctrl+Alt+I) inserts each image
        at the top of an A4 page. Ctrl+E then writes back through the in-memory
        image reference; after a restart this legacy mapping is gone, so the
        normal save dialog is used. New code should use the lecture flow.

  Cropping for the normal Ctrl+E (without a bridged image) is done by
  trim.ps1, which ships with this plugin and uses System.Drawing that comes
  with Windows. Width is preserved; only the height shrinks. Set
  TRIM_ENABLED = false to keep full pages.

  Plugin folders (as used by this build):
      Windows: %LOCALAPPDATA%\xournalpp\plugins\PagePngExport\
      Linux:   ~/.config/xournalpp/plugins/PagePngExport/
      macOS:   ~/Library/Application Support/xournalpp/plugins/PagePngExport/
]]

local DPI = 150
local BACKGROUND = "none" -- "none" = transparent, "unruled" = white, "all" = paper
local ACCELERATOR = "<Ctrl>e"
local INSERT_ACCELERATOR = "F8"
-- F9 is already "Show Toolbars" in Xournal++; F7 is free.
local LECTURE_ACCELERATOR = "F7"
local LECTURE_ACCELERATOR_ALT = "<Ctrl><Alt>l"
local LECTURE_QUEUE_HEADER = "# oi-assist-lecture-queue v1"
local A4_WIDTH = 595.275591
local A4_HEIGHT = 841.889764

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

local function bridgeTempDir()
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
  return dir .. sep .. "oi-assist-xournalpp"
end

local function mailboxPath()
  local dir = bridgeTempDir()
  if not dir then
    return nil
  end
  local sep = package.config:sub(1, 1)
  return dir .. sep .. "latest.txt"
end

--- Lecture queue lives in the system temp dir (ASCII path). Lua `io.open`
--- on a Chinese Windows note directory is not reliable, so the extension
--- writes this file here; paths inside it are still full UTF-8 strings.
local function lectureQueuePath()
  local dir = bridgeTempDir()
  if not dir then
    return nil
  end
  local sep = package.config:sub(1, 1)
  return dir .. sep .. "lecture-queue.txt"
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

----------------------------------------------------------------------
-- Lecture queue (VS Code -> Xournal++), tab-separated / escaped
----------------------------------------------------------------------

local function unescapeField(value)
  local out = {}
  local i = 1
  while i <= #value do
    local ch = value:sub(i, i)
    if ch ~= "\\" then
      out[#out + 1] = ch
      i = i + 1
    else
      local n = value:sub(i + 1, i + 1)
      if n == "\\" then
        out[#out + 1] = "\\"
      elseif n == "t" then
        out[#out + 1] = "\t"
      elseif n == "n" then
        out[#out + 1] = "\n"
      elseif n == "r" then
        out[#out + 1] = "\r"
      else
        error("unknown escape")
      end
      i = i + 2
    end
  end
  return table.concat(out)
end

local function splitTab(line)
  local fields = {}
  local pos = 1
  while true do
    local tab = line:find("\t", pos, true)
    if not tab then
      fields[#fields + 1] = line:sub(pos)
      break
    end
    fields[#fields + 1] = line:sub(pos, tab - 1)
    pos = tab + 1
  end
  return fields
end

local function normalizePath(value)
  local out = (value or ""):gsub("\\", "/"):gsub("/+$", "")
  if isWindows then
    out = out:lower()
  end
  return out
end

local function samePath(a, b)
  return normalizePath(a) == normalizePath(b)
end

--- Returns items, errors, queueFile. Missing queue file => items nil.
local function readLectureQueue()
  local file = lectureQueuePath()
  if not file then
    return nil, {"无法确定临时目录"}, nil
  end
  local handle = io.open(file, "rb")
  if not handle then
    return nil, {}, file
  end
  local items = {}
  local errors = {}
  local sawHeader = false
  for rawLine in handle:lines() do
    local line = rawLine:gsub("\r$", "")
    if line == LECTURE_QUEUE_HEADER then
      sawHeader = true
    elseif line ~= "" and line:sub(1, 1) ~= "#" then
      if not sawHeader then
        errors[#errors + 1] = "queue line before header"
      else
        local fields = splitTab(line)
        if #fields ~= 6 then
          errors[#errors + 1] = "queue field count"
        else
          local ok, item = pcall(function()
            return {
              lecturePath = unescapeField(fields[1]),
              id = unescapeField(fields[2]),
              title = unescapeField(fields[3]),
              assetPath = unescapeField(fields[4]),
              base = unescapeField(fields[5]),
              dpi = tonumber(unescapeField(fields[6])),
            }
          end)
          if not ok then
            errors[#errors + 1] = "queue escape"
          elseif item.lecturePath == "" or item.id == "" or item.assetPath == ""
                 or item.base == "" or not item.dpi then
            errors[#errors + 1] = "queue required field"
          else
            items[#items + 1] = item
          end
        end
      end
    end
  end
  handle:close()
  if not sawHeader then
    errors[#errors + 1] = "queue header missing"
  end
  return items, errors, file
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
  local okLinks, links = pcall(app.getLinks, "page")
  return (okStrokes and type(strokes) == "table" and #strokes > 0)
      or (okTexts and type(texts) == "table" and #texts > 0)
      or (okImages and type(images) == "table" and #images > 0)
      or (okLinks and type(links) == "table" and #links > 0)
end

--- Inserts a new page after the current one and returns its number, or nil.
----------------------------------------------------------------------
-- Lecture page tokens: OI:<id>:<seq>:<dpi>:<base>
----------------------------------------------------------------------

local function tokenPart(value, fallback)
  local out = (value or ""):gsub(":", "_"):gsub("^%s+", ""):gsub("%s+$", "")
  if out == "" then
    return fallback
  end
  return out
end

local function makeToken(id, seq, dpi, base)
  return string.format("OI:%s:%d:%d:%s",
    tokenPart(id, "题目"),
    math.max(1, math.floor(tonumber(seq) or 1)),
    math.max(72, math.min(600, math.floor((tonumber(dpi) or DPI) + 0.5))),
    tokenPart(base, "板书"))
end

local function parseToken(name)
  local id, seq, dpi, base = (name or ""):match("^OI:([^:]+):([1-9]%d*):(%d+):(.+)$")
  if not id then
    return nil
  end
  local n = tonumber(seq)
  local d = tonumber(dpi)
  if not n or not d or d < 72 or d > 600 or base == "" then
    return nil
  end
  return { id = id, seq = n, dpi = math.floor(d + 0.5), base = base }
end

local function pageToken(page)
  local layers = page and page.layers
  local background = layers and layers[0]
  local name = background and background.name or ""
  return parseToken(name)
end

--- Current document + its directory, or nil when unsaved.
local function lectureDocument()
  local doc = app.getDocumentStructure()
  local source = doc.xoppFilename or ""
  if source == "" then
    return nil, nil
  end
  local dir = splitPath(source)
  return doc, dir
end

local function lectureNoteImagePath(dir, token, seq)
  local n = seq or token.seq
  local name = token.base .. (n == 1 and ".png" or ("-p" .. tostring(n) .. ".png"))
  return dir .. "/img/" .. name
end

local function documentTokens(doc)
  local byId = {}
  local maxSeq = {}
  for pageNo = 1, #doc.pages do
    local token = pageToken(doc.pages[pageNo])
    if token then
      byId[token.id] = true
      maxSeq[token.id] = math.max(maxSeq[token.id] or 0, token.seq)
    end
  end
  return byId, maxSeq
end

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

local function exportCurrentPage(path, trim, quiet, dpi)
  local doc = app.getDocumentStructure()

  local ok, err = pcall(app.export, {
    outputFile = path,
    range = tostring(doc.currentPage),
    background = BACKGROUND,
    pngDpi = dpi or DPI,
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

--- Bottom edge (pt) of all content on the current page: bridged image,
--- annotations (strokes/text/images/links). Used to crop the A4 page before
--- write-back so the Typst note does not get a large blank area.
local function contentBottomOnCurrentPage()
  local _, page = currentPageInfo()
  if not page then
    return nil
  end

  local bottom = 0
  local function consider(y, h)
    if type(y) == "number" and type(h) == "number" and h > 0 then
      local b = y + h
      if b > bottom then
        bottom = b
      end
    end
  end

  local okStrokes, strokes = pcall(app.getStrokes, "page")
  if okStrokes and type(strokes) == "table" then
    for _, s in ipairs(strokes) do
      local ys = s.y
      local w = tonumber(s.width) or 0.5
      if type(ys) == "table" then
        for _, y in ipairs(ys) do
          consider(y, w / 2)
        end
      end
    end
  end

  local okTexts, texts = pcall(app.getTexts, "page")
  if okTexts and type(texts) == "table" then
    for _, t in ipairs(texts) do
      consider(t.y, t.height)
    end
  end

  local okImages, images = pcall(app.getImages, "page")
  if okImages and type(images) == "table" then
    for _, im in ipairs(images) do
      consider(im.y, im.height)
    end
  end

  local okLinks, links = pcall(app.getLinks, "page")
  if okLinks and type(links) == "table" then
    for _, l in ipairs(links) do
      consider(l.y, l.height)
    end
  end

  return bottom
end

--- Effective dpi of the bridged image: the extension may render at 150 or
--- 300 dpi, and exporting the page at a fixed 150 would halve a 300 dpi note
--- image. Returns nil when the image cannot be measured (fall back to DPI).
local function bridgedImageDpi(entry)
  local ok, images = pcall(app.getImages, "page")
  if not ok or type(images) ~= "table" then
    return nil
  end
  for _, image in ipairs(images) do
    if image.ref == entry.ref then
      local width = tonumber(image.width)
      local pixels = tonumber(image.imageWidth)
      if width and width > 0 and pixels and pixels > 0 then
        local dpi = pixels / (width / 72)
        if dpi >= 72 and dpi <= 1200 then
          return math.floor(dpi + 0.5)
        end
      end
      return nil
    end
  end
  return nil
end

--- Writes the annotated current page back to the source PNG of a bridged page.
--- The note image is tight; this page is A4 with blank below it. Before export
--- the page is temporarily shortened to the content bottom, then restored, so
--- the source PNG has no large blank top/bottom area. The export dpi follows
--- the inserted image, so a 300 dpi note stays at 300 dpi.
local function writeBackBridgedPage(entry)
  local _, page = currentPageInfo()
  if not page then
    return false, "no current page"
  end

  local originalW, originalH = page.pageWidth, page.pageHeight
  local bottom = contentBottomOnCurrentPage()
  local margin = 10
  local targetH = originalH
  if type(bottom) == "number" and bottom > 0 then
    targetH = math.min(originalH, bottom + margin)
  end
  local dpi = bridgedImageDpi(entry)

  local shortened = targetH < originalH
  if shortened then
    app.setPageSize(originalW, targetH)
  end
  local ok, err = exportCurrentPage(entry.path, false, true, dpi)
  if shortened then
    app.setPageSize(originalW, originalH)
  end

  if ok then
    log("write-back ok: " .. entry.path)
    toast("已回写：" .. baseName(entry.path))
    return true
  end
  log("write-back failed: " .. entry.path .. " - " .. tostring(err))
  return false, err
end

----------------------------------------------------------------------
-- Lecture: Ctrl+E writes the current page back to its note image
----------------------------------------------------------------------

local function lectureTargetOnCurrentPage()
  local _, page = currentPageInfo()
  if not page then
    return nil
  end
  local token = pageToken(page)
  if not token then
    return nil
  end
  local _, dir = lectureDocument()
  if not dir then
    return nil
  end
  return {
    notePath = lectureNoteImagePath(dir, token, token.seq),
    dpi = token.dpi,
    id = token.id,
    seq = token.seq,
    token = makeToken(token.id, token.seq, token.dpi, token.base),
    continuation = false,
  }
end

--- Page without a token: if it follows a problem page and has content,
--- offer to bind it as the next continuation of that problem.
local function continuationTarget()
  local doc, dir = lectureDocument()
  if not doc then
    return nil
  end
  local currentNo = doc.currentPage
  local _, page = currentPageInfo()
  if not page or pageToken(page) or not pageHasContent() then
    return nil
  end

  local owner = nil
  for pageNo = currentNo - 1, 1, -1 do
    local token = pageToken(doc.pages[pageNo])
    if token then
      owner = token
      break
    end
  end
  if not owner then
    return nil
  end
  -- Refuse a page inserted in the middle of a problem block: the next token
  -- with the same id means this page is not at the end, so we cannot guess seq.
  for pageNo = currentNo + 1, #doc.pages do
    local token = pageToken(doc.pages[pageNo])
    if token and token.id == owner.id then
      return nil
    end
  end

  local _, maxSeq = documentTokens(doc)
  local seq = (maxSeq[owner.id] or 0) + 1
  return {
    notePath = lectureNoteImagePath(dir, owner, seq),
    dpi = owner.dpi,
    id = owner.id,
    seq = seq,
    token = makeToken(owner.id, seq, owner.dpi, owner.base),
    continuation = true,
  }
end

--- Export the current page tight and atomically replace its note image.
local function writeBackLecturePage(target)
  local doc = app.getDocumentStructure()
  local _, page = currentPageInfo()
  if not page then
    return false, "no current page"
  end

  local originalW, originalH = page.pageWidth, page.pageHeight
  local bottom = contentBottomOnCurrentPage()
  local targetH = originalH
  if type(bottom) == "number" and bottom > 0 then
    targetH = math.min(originalH, bottom + 10)
  end
  local shortened = targetH < originalH
  if shortened then
    app.setPageSize(originalW, targetH)
  end

  local temp = target.notePath .. ".tmp.png"
  local ok, err = pcall(app.export, {
    outputFile = temp,
    range = tostring(doc.currentPage),
    background = BACKGROUND,
    pngDpi = target.dpi or DPI,
  })
  if shortened then
    app.setPageSize(originalW, originalH)
  end
  if not ok then
    log("lecture write-back export failed: " .. tostring(err))
    return false, tostring(err)
  end

  local moved, moveErr = app.glib_rename(temp, target.notePath)
  if not moved then
    local ok2, renamed, err2 = pcall(os.rename, temp, target.notePath)
    if not ok2 or not renamed then
      log("lecture write-back rename failed: " .. tostring(moveErr) .. " / " .. tostring(err2))
      return false, tostring(moveErr)
    end
  end

  app.setBackgroundName(target.token)
  local message = "已回写：" .. baseName(target.notePath) .. "（记得 Ctrl+S 保存整讲）"
  toast(message)
  log(message)
  return true
end

local pendingContinuation = nil

--- Callback for the "is this a continuation page?" dialog.
function onContinuationChoice(choice)
  local target = pendingContinuation
  pendingContinuation = nil
  if choice == 1 and target then
    local ok, err = writeBackLecturePage(target)
    if ok then
      return
    end
    app.openDialog(
      "续页没有回写成功：\n" .. tostring(err) .. "\n\n会用普通保存框代替。",
      {"OK"}, "", true)
  end
  app.fileDialogSave("onFileChosen", suggestedName())
end

----------------------------------------------------------------------
-- Lecture: append pending problem pages (F7)
----------------------------------------------------------------------

local function addPageAtEnd()
  local before = #app.getDocumentStructure().pages
  app.activateAction("new-page-at-end")
  local after = app.getDocumentStructure()
  if #after.pages <= before then
    -- Older builds may not move to the new page; retry from the last page.
    app.setCurrentPage(before)
    app.activateAction("new-page-after")
    after = app.getDocumentStructure()
  end
  if #after.pages <= before then
    return nil
  end
  app.setCurrentPage(#after.pages)
  return #after.pages
end

local function ensureLecturePage()
  local _, page = currentPageInfo()
  if not page then
    return nil
  end
  if math.abs(page.pageWidth - A4_WIDTH) > 0.5 or math.abs(page.pageHeight - A4_HEIGHT) > 0.5 then
    app.setPageSize(A4_WIDTH, A4_HEIGHT)
  end
  _, page = currentPageInfo()
  if page and page.pageTypeFormat ~= "plain" then
    app.changeCurrentPageBackground("plain")
  end
  return currentPageInfo()
end

--- F7: append every pending problem for the currently open lecture.
function insertPendingLectureProblems()
  local doc, dir = lectureDocument()
  if not doc then
    app.openDialog(
      "当前文档还没有保存为 .xopp。\n\n请先保存成与课堂笔记同名的整讲文件（A.typ → A.xopp），再按 F7。",
      {"OK"}, "", true)
    return
  end

  local items, errors, queueFile = readLectureQueue()
  if not items then
    app.openDialog(
      "找不到本节板书的交接队列。\n\n先在 VS Code 打开一道题的白板（会自动排队），并确认 Xournal++ 打开的是：\n" ..
      tostring(doc.xoppFilename) .. "\n\n队列文件：\n" .. tostring(queueFile),
      {"OK"}, "", true)
    return
  end

  for _, item in ipairs(errors) do
    log("lecture queue: " .. item)
  end

  local tokens = documentTokens(doc)
  local seen = {}
  local pending = {}
  local otherLectures = {}
  for _, item in ipairs(items) do
    if samePath(item.lecturePath, doc.xoppFilename) then
      if not tokens[item.id] and not seen[item.id] then
        seen[item.id] = true
        pending[#pending + 1] = item
      end
    elseif not otherLectures[item.lecturePath] then
      otherLectures[item.lecturePath] = true
    end
  end

  if #pending == 0 then
    local extra = ""
    local names = {}
    for lecturePath in pairs(otherLectures) do
      names[#names + 1] = lecturePath
    end
    if #names > 0 then
      extra = "\n\n队列里还有其它整讲：\n" .. table.concat(names, "\n")
    end
    if #errors > 0 then
      extra = extra .. "\n\n队列文件有 " .. #errors .. " 行无法解析，详见 bridge.log。"
    end
    app.openDialog(
      "当前文档没有待插入的题目。\n\n本讲：\n" .. tostring(doc.xoppFilename) .. extra,
      {"OK"}, "", true)
    return
  end

  local reuseBlank = (#doc.pages == 1 and pageToken(doc.pages[1]) == nil and not pageHasContent())
  local inserted = {}
  local failed = {}

  for _, item in ipairs(pending) do
    local pageNo
    if reuseBlank then
      reuseBlank = false
      pageNo = 1
    else
      pageNo = addPageAtEnd()
    end
    if not pageNo then
      failed[#failed + 1] = item.id .. "\n无法新建页面"
    else
      ensureLecturePage()
      local insertedPage, refOrError = insertImageOnCurrentPage(item.assetPath)
      if insertedPage then
        app.setBackgroundName(makeToken(item.id, 1, item.dpi, item.base))
        inserted[#inserted + 1] = insertedPage
        log(string.format("lecture: inserted %s on page %d", item.id, insertedPage))
      else
        failed[#failed + 1] = item.id .. "\n" .. tostring(refOrError)
      end
    end
  end

  if inserted[1] then
    app.scrollToPage(inserted[1])
  end
  if #inserted > 0 then
    local message = string.format("已插入 %d 道题。批注后按 Ctrl+E 回写；记得 Ctrl+S 保存整讲。", #inserted)
    toast(message)
    log(message)
  end
  if #failed > 0 or #errors > 0 then
    local lines = {}
    for _, item in ipairs(failed) do
      lines[#lines + 1] = item
    end
    for _, item in ipairs(errors) do
      lines[#lines + 1] = "队列：" .. item
    end
    app.openDialog(
      "有 " .. (#failed + #errors) .. " 项没有插入：\n\n" .. table.concat(lines, "\n\n"),
      {"OK"}, "", true)
  end
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
    menu = "Append queued problems to lecture (OI) — F7",
    callback = "insertPendingLectureProblems",
    accelerator = LECTURE_ACCELERATOR,
  })
  -- F7 can be grabbed by window managers; keep a portable alternative.
  app.registerUi({
    menu = "Append queued problems to lecture (OI) — Ctrl+Alt+L",
    callback = "insertPendingLectureProblems",
    accelerator = LECTURE_ACCELERATOR_ALT,
  })
  app.registerUi({
    menu = "Insert latest whiteboard image (OI) — F8",
    callback = "insertLatestWhiteboardImage",
    accelerator = INSERT_ACCELERATOR,
  })
  -- F8 is grabbed by some window managers (e.g. Cinnamon). Keep a portable
  -- alternative on the same callback.
  app.registerUi({
    menu = "Insert latest whiteboard image (OI) — Ctrl+Alt+I",
    callback = "insertLatestWhiteboardImage",
    accelerator = "<Ctrl><Alt>i",
  })
  app.registerUi({
    menu = "Write back current whiteboard image (OI)",
    callback = "writeBackCurrentWhiteboardImage",
  })
end

--- Entry point behind Ctrl+E.
function exportCurrentPagePng()
  pendingContinuation = nil

  -- 1) A page inserted by F7 carries OI:<id>:<seq>:<dpi>:<base>.
  local lecture = lectureTargetOnCurrentPage()
  if lecture then
    local ok, err = writeBackLecturePage(lecture)
    if ok then
      return
    end
    app.openDialog(
      "Could not write back to this note image:\n" .. lecture.notePath .. "\n\n" .. tostring(err) ..
      "\n\nThe save dialog will open instead.",
      {"OK"}, "", true)
    app.fileDialogSave("onFileChosen", suggestedName())
    return
  end

  -- 2) Legacy F8 bridge (the note PNG was inserted as an image page).
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

  -- 3) A manually added page after a problem page: offer to bind it as a continuation.
  local continuation = continuationTarget()
  if continuation then
    pendingContinuation = continuation
    app.openDialog(
      string.format(
        "本页没有绑定题目。\n\n把它作为 %s 的第 %d 页续页，回写到：\n%s\n\n之后记得 Ctrl+S 保存整讲。",
        continuation.id, continuation.seq, continuation.notePath),
      {"回写续页", "取消"},
      "onContinuationChoice",
      false)
    return
  end

  app.fileDialogSave("onFileChosen", suggestedName())
end

function exportCurrentPagePngFull()
  app.fileDialogSave("onFileChosenFullPage", suggestedName())
end
