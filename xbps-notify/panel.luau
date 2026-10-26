-- Update panel: the pending updates with their versions, descriptions and
-- sizes, the rest of the upgrade transaction, and the button that starts the
-- upgrade. It renders the status the service publishes and sends its requests
-- back through shared.sendCommand().
local shared = require("./shared.luau")

-- At most this many XBPS warnings are shown above the list.
local MAX_WARNINGS = 2

local status = noctalia.state.get(shared.STATE_KEY) -- last status published by the service
local isOpen = false
local showClose = true -- whether to show a close button, per the shell setting

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- Labels of the transaction types other than update and hold; unknown types
-- are shown as XBPS names them.
local ACTION_KEYS = {
  install = "actions.install",
  reinstall = "actions.reinstall",
  remove = "actions.remove",
  configure = "actions.configure",
  download = "actions.download",
}

-- True until the first check has either produced a result or failed.
local function waitingForFirstResult(s)
  return s == nil or (not s.hasResult and s.phase ~= "error" and s.phase ~= "unsupported")
end

-- The line under the title: what is pending (or what is going on) and when
-- the last successful check ran.
local function subtitle(s)
  if waitingForFirstResult(s) then
    return tr("status.checking")
  end
  if s.phase == "unsupported" then
    return tr("panel.unsupported_title")
  end
  if not s.hasResult then
    return tr("panel.check_failed_title")
  end

  local parts = {}
  if s.phase == "checking" then
    table.insert(parts, tr("status.checking"))
  elseif s.count > 0 then
    table.insert(parts, shared.trn("panel.available", s.count))
    if s.downloadSize > 0 then
      table.insert(parts, shared.formatBytes(s.downloadSize))
    end
  else
    table.insert(parts, tr("status.up_to_date"))
  end
  if s.phase ~= "checking" and s.checkedAt ~= nil and s.checkedAt > 0 then
    table.insert(parts, tr("panel.checked_at", { time = shared.formatClock(s.checkedAt) }))
  end
  return table.concat(parts, " · ")
end

-- Title row with the refresh, settings and (optional) close buttons.
local function header()
  local checking = status ~= nil and status.phase == "checking"
  local children = {
    ui.glyph({ name = "package", size = 22, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = subtitle(status), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      tooltip = tr("panel.check"),
      enabled = not checking,
      onClick = function()
        -- No notification: the panel shows the result itself.
        shared.sendCommand("check", false)
      end,
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      tooltip = tr("panel.settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    }),
  }
  if showClose then
    table.insert(children, ui.button({
      glyph = "close",
      variant = "ghost",
      onClick = function()
        panel.close()
      end,
    }))
  end
  return ui.row({ align = "center", gap = 8 }, children)
end

-- A tinted row with an icon, for errors, warnings and hints above the list.
local function notice(glyph, color, text)
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = color .. "/0.12" }, {
    ui.glyph({ name = glyph, size = 18, color = color }),
    ui.label({ text = text, flexGrow = 1, color = "on_surface", maxLines = 3 }),
  })
end

-- A large centered icon with a title and a detail line, shown instead of the
-- list when there is nothing to list.
local function placeholder(glyph, color, title, detail)
  return ui.column({ flexGrow = 1, gap = 8, align = "center", justify = "center" }, {
    ui.glyph({ name = glyph, size = 40, color = color }),
    ui.label({ text = title, fontSize = 15, fontWeight = "medium", color = "on_surface", textAlign = "center" }),
    ui.label({ text = detail, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
  })
end

-- One pending update: name and version change, then description and download size.
local function packageRow(pkg)
  local details = {
    ui.label({ text = pkg.description, fontSize = 12, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
  }
  if pkg.downloadSize > 0 then
    table.insert(details, ui.label({ text = shared.formatBytes(pkg.downloadSize), fontSize = 12, color = "on_surface_variant" }))
  end
  -- Keyed rows let a re-render reuse the existing controls instead of rebuilding them.
  return ui.column({ key = "pkg:" .. pkg.name, gap = 2, paddingH = 10, paddingV = 6, radius = 8, fill = "surface_variant/0.45" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = pkg.name, fontWeight = "medium", color = "on_surface", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = shared.versionChange(pkg), fontSize = 12, color = "primary", maxLines = 1 }),
    }),
    ui.row({ gap = 8, align = "center" }, details),
  })
end

-- Another entry of the upgrade transaction (new dependency, removal, ...) with its type.
local function extraRow(entry)
  local key = ACTION_KEYS[entry.action]
  return ui.row({
    key = "extra:" .. entry.action .. ":" .. entry.name,
    gap = 8,
    align = "center",
    paddingH = 10,
    paddingV = 6,
    radius = 8,
    fill = "surface_variant/0.25",
  }, {
    ui.label({ text = entry.name .. "-" .. entry.version, color = "on_surface", flexGrow = 1, maxLines = 1 }),
    ui.label({ text = (if key then tr(key) else entry.action), fontSize = 12, color = "on_surface_variant" }),
  })
end

-- "and N more" below a list the service had to cap.
local function moreLabel(count)
  return ui.label({ text = tr("summary.more", { count = count }), color = "on_surface_variant", textAlign = "center" })
end

-- The scrolling content: notices first, then the updates, then the rest of
-- the transaction.
local function packageList(s)
  local sections = {}
  -- The last check failed, so the list below comes from an earlier one.
  if s.error ~= nil then
    table.insert(sections, notice("alert-triangle", "error", tr("panel.stale", { message = s.error })))
  end
  if s.xbpsFirst then
    table.insert(sections, notice("info-circle", "primary", tr("panel.xbps_first")))
  end
  for i = 1, math.min(MAX_WARNINGS, #s.warnings) do
    table.insert(sections, notice("alert-triangle", "error", tr("panel.xbps_warning", { message = s.warnings[i] })))
  end

  if #s.packages > 0 then
    local rows = {}
    for _, pkg in ipairs(s.packages) do
      table.insert(rows, packageRow(pkg))
    end
    table.insert(sections, ui.column({ key = "packages", gap = 6 }, rows))
  end
  if s.count > #s.packages then
    table.insert(sections, moreLabel(s.count - #s.packages))
  end

  if s.extrasCount > 0 then
    local rows = {}
    for _, entry in ipairs(s.extras) do
      table.insert(rows, extraRow(entry))
    end
    table.insert(sections, ui.label({ text = tr("panel.also"), fontWeight = "medium", color = "on_surface_variant" }))
    table.insert(sections, ui.column({ key = "extras", gap = 6 }, rows))
    if s.extrasCount > #s.extras then
      table.insert(sections, moreLabel(s.extrasCount - #s.extras))
    end
  end
  return ui.scroll({ flexGrow = 1, gap = 6 }, sections)
end

-- The main area: a placeholder while there is nothing to list, else the list.
local function body(s)
  if waitingForFirstResult(s) then
    return placeholder("loader", "primary", tr("status.checking"), tr("panel.checking_detail"))
  end
  if s.phase == "unsupported" then
    return placeholder("alert-triangle", "error", tr("panel.unsupported_title"), tr("status.unsupported"))
  end
  if not s.hasResult then
    return placeholder("alert-triangle", "error", tr("panel.check_failed_title"), s.error or "")
  end
  if s.count == 0 and s.extrasCount == 0 then
    -- Up to date as far as the last result goes. A failed check or an XBPS
    -- warning replaces the usual all-clear detail line.
    local problem = nil
    if s.error ~= nil then
      problem = tr("panel.stale", { message = s.error })
    elseif #s.warnings > 0 then
      problem = tr("panel.xbps_warning", { message = s.warnings[1] })
    end
    local detail = problem or tr("panel.up_to_date_detail")
    return placeholder("circle-check", (if problem then "error" else "primary"), tr("status.up_to_date"), detail)
  end
  return packageList(s)
end

-- Notes about held and ignored packages, and the upgrade button.
local function footer(s)
  local notes = {}
  if s ~= nil and s.hasResult then
    if s.held > 0 then
      table.insert(notes, shared.trn("panel.held", s.held))
    end
    if s.ignored > 0 then
      table.insert(notes, shared.trn("panel.ignored", s.ignored))
    end
  end
  -- The upgrade is offered whenever the transaction is not empty, even when
  -- only new dependencies or removals are left (e.g. all updates are ignored).
  local canUpgrade = s ~= nil and s.hasResult and (s.count > 0 or s.extrasCount > 0)
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = table.concat(notes, " · "), fontSize = 12, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
    ui.button({
      text = tr("panel.upgrade"),
      glyph = "download",
      variant = "primary",
      enabled = canUpgrade,
      onClick = function()
        -- The service opens the terminal.
        shared.sendCommand("upgrade")
        panel.close()
      end,
    }),
  })
end

-- Renders the whole panel. Nothing to do while it is closed; onOpen() renders
-- it with the latest status.
local function render()
  if not isOpen then
    return
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    header(),
    body(status),
    footer(status),
  }))
end

-- Keep the status current even while the panel is closed.
noctalia.state.watch(shared.STATE_KEY, function(value)
  status = value
  render()
end)

function onOpen(_context)
  isOpen = true
  -- A shell setting, so it is read again on every open.
  showClose = noctalia.getSetting("shell.show_close_buttons") ~= false
  status = noctalia.state.get(shared.STATE_KEY)
  render()
end

function onClose()
  isOpen = false
end
