-- Constants and helpers shared by all entries of the plugin (service, bar
-- widget, panel, shortcut). Each entry runs in its own Luau VM, so they
-- exchange plain values only, through the per-plugin state channel
-- (noctalia.state).
local M = {}

-- Full entry ids, as used by noctalia.togglePanel() and `noctalia msg`.
M.PLUGIN_ID = "gluow3377/xbps-notify"
M.PANEL_ID = M.PLUGIN_ID .. ":panel"
M.SERVICE_ID = M.PLUGIN_ID .. ":service"

-- State channel keys: the service publishes its status under STATE_KEY, the
-- other entries send it requests under COMMAND_KEY.
M.STATE_KEY = "status"
M.COMMAND_KEY = "command"

-- Transaction types in the `xbps-install -n` plan that get special treatment.
-- Every other type (install, remove, ...) is listed as an extra entry.
M.ACTION_UPDATE = "update"
M.ACTION_HOLD = "hold"

-- The published status carries at most this many packages and extra entries,
-- to keep it small; the totals are published separately.
M.MAX_LISTED = 200
M.MAX_EXTRAS_LISTED = 50

-- Sends a request ("check" or "upgrade") to the service. With notifyResult,
-- the service reports the outcome of the check in a notification.
function M.sendCommand(action, notifyResult)
  noctalia.state.set(M.COMMAND_KEY, { action = action, notify = notifyResult == true })
end

-- Makes process output safe to display. Valid UTF-8 is returned unchanged; in
-- lines that are not valid UTF-8, every non-ASCII byte becomes "?".
function M.cleanText(text)
  text = text or ""
  if utf8.len(text) ~= nil then
    return text
  end
  return (string.gsub(text, "[^\n]+", function(line)
    if utf8.len(line) ~= nil then
      return line
    end
    return (string.gsub(line, "[\128-\255]", "?"))
  end))
end

-- Splits a pkgver such as "xbps-0.59.2_1" into name ("xbps") and version
-- ("0.59.2_1") at the last "-", since Void versions never contain one.
-- Without a "-", the whole string is the name and the version is "".
function M.splitPkgver(pkgver)
  local name, version = string.match(pkgver, "^(.+)%-([^%-]+)$")
  if name == nil then
    return pkgver, ""
  end
  return name, version
end

-- Parses the plan printed by `xbps-install -n`, one line per transaction entry:
--   <pkgver> <action> <arch> <repository> <installed size> <download size>
-- Lines in any other format are skipped. Returns a list of
-- { name, version, action, downloadSize }.
function M.parseTransaction(stdout)
  local entries = {}
  for line in string.gmatch(stdout or "", "[^\n]+") do
    -- The repository is whatever lies between the arch and the two sizes at
    -- the end of the line.
    local pkgver, action, download = string.match(line, "^(%S+) (%S+) %S+ .- %d+ (%d+)%s*$")
    if pkgver ~= nil then
      local name, version = M.splitPkgver(pkgver)
      table.insert(entries, {
        name = name,
        version = version,
        action = action,
        downloadSize = tonumber(download) or 0,
      })
    end
  end
  return entries
end

-- Parses `xbps-query -l`, one installed package per line:
--   <state> <pkgver> <short description>
-- where <state> is two characters, e.g. "ii". Returns
-- { [name] = { version, description } } for the names in the `wanted` set only.
function M.parseInstalled(stdout, wanted)
  local installed = {}
  for line in string.gmatch(stdout or "", "[^\n]+") do
    local pkgver, description = string.match(line, "^%S%S +(%S+) *(.*)$")
    if pkgver ~= nil then
      local name, version = M.splitPkgver(pkgver)
      if wanted[name] then
        installed[name] = { version = version, description = description }
      end
    end
  end
  return installed
end

-- Returns the messages of the "ERROR: ..." lines XBPS printed, without the prefix.
function M.errorLines(stderr)
  local lines = {}
  for line in string.gmatch(stderr or "", "[^\n]+") do
    local message = string.match(line, "^ERROR: *(.-) *$")
    if message ~= nil and message ~= "" then
      table.insert(lines, message)
    end
  end
  return lines
end

-- Returns the last non-blank line of `text`, trimmed, or nil if there is none.
function M.lastLine(text)
  local last = nil
  for line in string.gmatch(text or "", "[^\n]+") do
    local trimmed = string.match(line, "^%s*(.-)%s*$")
    if trimmed ~= "" then
      last = trimmed
    end
  end
  return last
end

-- Turns the "ignored packages" setting into anchored Lua patterns: the
-- shell-style "*" wildcard matches anything, every other character itself.
function M.compileIgnoreList(list)
  local patterns = {}
  for _, item in ipairs(list or {}) do
    local trimmed = string.match(item, "^%s*(.-)%s*$")
    if trimmed ~= "" then
      -- Escape the Lua pattern magic characters except "*", which becomes ".*".
      local escaped = string.gsub(trimmed, "[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
      escaped = string.gsub(escaped, "%*", ".*")
      table.insert(patterns, "^" .. escaped .. "$")
    end
  end
  return patterns
end

-- True if the package name matches one of the patterns from compileIgnoreList().
function M.isIgnored(name, patterns)
  for _, pattern in ipairs(patterns) do
    if string.match(name, pattern) then
      return true
    end
  end
  return false
end

-- Translation keys of the size units, one step per factor of 1024.
local UNIT_KEYS = { "units.b", "units.kib", "units.mib", "units.gib", "units.tib" }

-- Formats a size in bytes with binary units, e.g. "1.5 MiB". The unit names
-- and the decimal separator come from the translations.
function M.formatBytes(bytes)
  local value = bytes or 0
  local index = 1
  while value >= 1024 and index < #UNIT_KEYS do
    value /= 1024
    index += 1
  end
  local unit = noctalia.tr(UNIT_KEYS[index])
  -- Plain bytes need no decimals.
  if index == 1 then
    return string.format("%d %s", value, unit)
  end
  local number = string.gsub(string.format("%.1f", value), "%.", noctalia.tr("units.decimal"))
  return number .. " " .. unit
end

-- Picks the plural form of `count` for the current language. Each translation
-- file names its rule in "plural_rule": "east_slavic" (Russian) uses the forms
-- one / few / many, anything else the English one / other.
local function pluralForm(count)
  local n = math.abs(math.floor(count))
  if noctalia.tr("plural_rule") == "east_slavic" then
    -- one: 1, 21, 31, ... but not 11; few: 2-4, 22-24, ... but not 12-14;
    -- many: everything else, including 0 and 11-14.
    local mod10, mod100 = n % 10, n % 100
    if mod10 == 1 and mod100 ~= 11 then
      return "one"
    elseif mod10 >= 2 and mod10 <= 4 and (mod100 < 12 or mod100 > 14) then
      return "few"
    end
    return "many"
  end
  return if n == 1 then "one" else "other"
end

-- Translates a string with plural forms: looks up "<key>.<form>" for `count`
-- and fills in {count} plus the placeholders given in `subst`.
function M.trn(key, count, subst)
  local values = { count = count }
  for k, v in pairs(subst or {}) do
    values[k] = v
  end
  return noctalia.tr(key .. "." .. pluralForm(count), values)
end

-- "old → new" when the installed version is known, otherwise just the new one.
function M.versionChange(pkg)
  if pkg.oldVersion ~= nil and pkg.oldVersion ~= "" then
    return pkg.oldVersion .. " → " .. pkg.version
  end
  return pkg.version
end

-- The names of the first `limit` packages, comma-separated, followed by
-- "and N more" when `total` is larger than the number of names shown.
function M.namesSummary(packages, total, limit)
  local names = {}
  for i = 1, math.min(limit, #packages) do
    table.insert(names, packages[i].name)
  end
  local text = table.concat(names, ", ")
  if total > #names then
    text ..= " " .. noctalia.tr("summary.more", { count = total - #names })
  end
  return text
end

-- Formats a unix time as a time of day, in the shell's clock format.
function M.formatClock(unixSeconds)
  return noctalia.formatTime(noctalia.timeFormat(), unixSeconds)
end

-- Quotes a string for POSIX sh: single quotes around it, each ' written as '\''.
function M.shellQuote(text)
  return "'" .. (string.gsub(text, "'", "'\\''")) .. "'"
end

-- The built-in upgrade command, run as root through `elevate` (sudo, doas or
-- pkexec). While xbps itself is outdated, XBPS refuses every other update, so
-- xbps goes first and the rest follows, using the index the first command
-- synced (-S).
function M.upgradeCommand(elevate, xbpsFirst)
  if xbpsFirst then
    return `{elevate} xbps-install -Su xbps && {elevate} xbps-install -u`
  end
  return `{elevate} xbps-install -Su`
end

-- Builds the sh script the upgrade terminal runs: set the window title, run
-- `command`, ask the service over IPC to check again, say whether the upgrade
-- succeeded and wait for Enter, so the window stays open until the output has
-- been read. The steps are joined with "; ", so each one runs whatever the
-- previous one returned. `texts` holds the translated title and messages.
function M.terminalScript(command, texts)
  local recheck = `noctalia msg plugin {M.SERVICE_ID} all check after-update >/dev/null 2>&1`
  return table.concat({
    -- OSC 0 escape sequence: sets the terminal window title.
    `printf '\\033]0;%s\\007' {M.shellQuote(texts.title)}`,
    command,
    -- Keep the exit status of the upgrade before the next steps overwrite $?.
    "rc=$?",
    recheck,
    "echo",
    `if [ "$rc" -eq 0 ]; then echo {M.shellQuote(texts.done)}; else echo {M.shellQuote(texts.failed)}; fi`,
    `printf '%s ' {M.shellQuote(texts.close)}`,
    "read -r _xbps_notify_key",
  }, "; ")
end

return M
