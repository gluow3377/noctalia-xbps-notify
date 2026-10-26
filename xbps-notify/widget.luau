-- Bar widget: a package glyph with the number of pending updates, and a
-- tooltip listing them. It only shows the status the service publishes.
local shared = require("./shared.luau")

-- Packages listed by name in the tooltip.
local TOOLTIP_PACKAGES = 8

-- Last status published by the service; nil until it publishes one.
local status = noctalia.state.get(shared.STATE_KEY)

-- One key/value row of the tooltip.
local function row(key, value)
  return { key = key, value = value }
end

-- Tooltip rows for a status with a result: what is pending, the first
-- packages, a problem if there is one, and the time of the last successful
-- check.
local function tooltipRows(s)
  local rows = {}
  if s.phase == "checking" then
    table.insert(rows, row(noctalia.tr("tooltip.status"), noctalia.tr("status.checking")))
  end

  if s.count > 0 then
    table.insert(rows, row(noctalia.tr("tooltip.updates"), tostring(s.count)))
    if s.downloadSize > 0 then
      table.insert(rows, row(noctalia.tr("tooltip.download"), shared.formatBytes(s.downloadSize)))
    end
    local shown = math.min(TOOLTIP_PACKAGES, #s.packages)
    for i = 1, shown do
      local pkg = s.packages[i]
      table.insert(rows, row(pkg.name, shared.versionChange(pkg)))
    end
    if s.count > shown then
      table.insert(rows, row("…", noctalia.tr("summary.more", { count = s.count - shown })))
    end
    if s.xbpsFirst then
      table.insert(rows, row("xbps", noctalia.tr("tooltip.xbps_first")))
    end
  elseif s.phase ~= "checking" and s.error == nil then
    -- Nothing pending, and the last check worked.
    table.insert(rows, row(noctalia.tr("tooltip.status"), noctalia.tr("status.up_to_date")))
  end

  -- At most one problem: why the last check failed, or else the first XBPS warning.
  if s.error ~= nil then
    table.insert(rows, row(noctalia.tr("tooltip.error"), s.error))
  elseif #s.warnings > 0 then
    table.insert(rows, row(noctalia.tr("tooltip.warning"), s.warnings[1]))
  end
  if s.checkedAt ~= nil and s.checkedAt > 0 then
    table.insert(rows, row(noctalia.tr("tooltip.checked"), shared.formatClock(s.checkedAt)))
  end
  return rows
end

-- What the widget shows for the current status: glyph, glyph color, text,
-- tooltip (a string or a list of rows) and whether it is visible.
local function view()
  local glyph = noctalia.getConfig("glyph")
  if glyph == nil or glyph == "" then
    glyph = "package"
  end

  -- The first check has not finished yet.
  if status == nil or (not status.hasResult and status.phase ~= "unsupported" and status.phase ~= "error") then
    return glyph, "on_surface", "", noctalia.tr("status.checking"), true
  end

  -- No XBPS, or no check has succeeded yet: show the problem.
  if status.phase == "unsupported" or not status.hasResult then
    return "alert-triangle", "error", "", status.error or noctalia.tr("status.unsupported"), true
  end

  -- Updates pending: the count, in the accent color.
  if status.count > 0 then
    return glyph, "primary", tostring(status.count), tooltipRows(status), true
  end

  -- Nothing pending. "Hide when up to date" never hides a failed check.
  local failed = status.error ~= nil
  local visible = failed or noctalia.getConfig("hide_when_updated") ~= true
  return glyph, (if failed then "error" else "on_surface"), "", tooltipRows(status), visible
end

local function render()
  local glyph, color, text, tooltip, visible = view()
  barWidget.setVisible(visible)
  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(color)
  barWidget.setText(text)
  barWidget.setTooltip(tooltip)
end

-- Re-render whenever the service publishes a new status.
noctalia.state.watch(shared.STATE_KEY, function(value)
  status = value
  render()
end)

-- Also re-render once a minute, so changes that come without a new status,
-- such as the shell's clock format, still reach the tooltip.
function update()
  render()
end

-- Left click: open or close the update panel.
function onClick()
  noctalia.togglePanel(shared.PANEL_ID)
end

-- Right click: check now and report the result in a notification.
function onRightClick()
  shared.sendCommand("check", true)
end

noctalia.setUpdateInterval(60000)
render()
