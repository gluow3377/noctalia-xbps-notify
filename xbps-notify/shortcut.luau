-- Control-center tile: the number of pending updates, highlighted while there
-- are any. It only shows the status the service publishes.
local shared = require("./shared.luau")

-- Last status published by the service; nil until it publishes one.
local status = noctalia.state.get(shared.STATE_KEY)

-- The tile label for the current status. A known count stays visible while a
-- new check runs; "Checking…" only replaces "Up to date".
local function label()
  if status == nil then
    return noctalia.tr("tile.checking")
  end
  if status.phase == "unsupported" then
    return noctalia.tr("tile.unsupported")
  end
  -- No result yet: the first check is still running, or it failed.
  if not status.hasResult then
    return noctalia.tr(if status.phase == "error" then "tile.error" else "tile.checking")
  end
  if status.count > 0 then
    return shared.trn("tile.updates", status.count)
  end
  if status.phase == "checking" then
    return noctalia.tr("tile.checking")
  end
  return noctalia.tr("tile.up_to_date")
end

local function render()
  shortcut.setLabel(label())
  shortcut.setIcon("package")
  -- Highlighted while updates are pending.
  shortcut.setActive(status ~= nil and status.hasResult and status.count > 0)
  shortcut.setEnabled(true)
end

-- Re-render whenever the service publishes a new status.
noctalia.state.watch(shared.STATE_KEY, function(value)
  status = value
  render()
end)

-- Click: open or close the update panel.
function onClick()
  noctalia.togglePanel(shared.PANEL_ID)
end

-- Right click: check now and report the result in a notification.
function onRightClick()
  shared.sendCommand("check", true)
end

render()
