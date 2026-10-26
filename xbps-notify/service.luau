-- Background service of the plugin. It checks XBPS for pending updates,
-- publishes the result on the state channel for the bar widget, the panel and
-- the control-center tile, sends the notifications, and starts the upgrade in
-- a terminal.
--
-- A check is a dry run of a full system upgrade (`xbps-install -Mun`, no root
-- needed), followed by `xbps-query -l` for the installed versions. Checks run
-- on a timer, on request (widget, panel, tile, IPC) and after the package
-- database has changed.
local shared = require("./shared.luau")

-- How often update() runs; every timer below is checked on this tick.
local TICK_MS = 15000
-- Time limits for the processes of a check. The dry run may download the
-- repository index; xbps-query only reads the local package database.
local DRY_RUN_TIMEOUT_MS = 60000
local QUERY_TIMEOUT_MS = 15000
-- Delay of the first check after the service starts.
local STARTUP_DELAY_S = 15
-- Retry delay after a failed check, doubled for each further failure in a row
-- and never longer than the regular check interval.
local ERROR_RETRY_S = 300
-- A check still running after this long is abandoned, in case a process
-- callback never arrives.
local CHECK_STALL_S = 150
-- The package database. When its file changes (packages were installed,
-- upgraded or removed), a check runs once it has stopped changing for
-- PKGDB_SETTLE_S.
local PKGDB_DIR = "/var/db/xbps"
local PKGDB_SETTLE_S = 10
-- Number of package names listed in a notification.
local NOTIFY_NAMES = 3
-- While announced updates are still pending, newer ones are announced at most
-- this often (Void publishes updates many times a day).
local RENOTIFY_S = 6 * 3600

-- The status published to the other entries under shared.STATE_KEY.
local status = {
  phase = "pending", -- "pending" (no check yet), "checking", "idle", "error" or "unsupported"
  hasResult = false, -- true once a check has succeeded; the fields below are valid from then on
  count = 0, -- pending updates, ignored packages not included
  packages = {}, -- the first MAX_LISTED of them by name: { name, version, oldVersion, description, downloadSize }
  extras = {}, -- other entries of the transaction (new dependencies, removals, ...): { name, version, action }
  extrasCount = 0, -- all of them; extras holds at most MAX_EXTRAS_LISTED
  held = 0, -- updates kept back with `xbps-pkgdb -m hold`
  ignored = 0, -- updates left out by the "ignored packages" setting
  downloadSize = 0, -- bytes to download for the counted updates and the extras
  xbpsFirst = false, -- xbps itself must be updated before XBPS allows any other update
  warnings = {}, -- problems XBPS reported in a check that still produced a plan
  error = nil, -- why the last check failed; the result above then comes from an earlier check
  checkedAt = 0, -- unix time of the last successful check
}

-- The state channel lives as long as the plugin and survives a restart of this
-- service (e.g. a hot reload), so carry on with the last result instead of
-- going back to "checking".
local previous = noctalia.state.get(shared.STATE_KEY)
if type(previous) == "table" and previous.hasResult then
  for key, value in pairs(previous) do
    status[key] = value
  end
  -- A check that was running before the restart will never report back.
  status.phase = if status.error ~= nil then "error" else "idle"
end

local checking = false -- a check is running; only one runs at a time
local generation = 0 -- bumped per check; callbacks of an abandoned check see a newer value and do nothing
local checkStartedAt = 0
local queued = nil -- options of a check requested while another one was running
local failStreak = 0 -- failed checks in a row, for the retry backoff
local nextCheckAt = os.time() + STARTUP_DELAY_S -- unix time of the next scheduled check, nil if none
local lastFinishedAt = nil -- the next check is scheduled from this time
local lastDryRun = nil -- the last successful dry run, re-applied when settings change
local syncRepos = noctalia.getConfig("sync_repos") ~= false -- pass -M to the dry run

-- Package database watch, see watchPkgdb().
local pkgdbPath = nil -- found on first use
local pkgdbMtime = nil -- last modification time seen
local pkgdbChangedAt = nil -- when a change was seen that no check has covered yet

-- All pending updates of the last check. status.packages is capped, but the
-- notifications have to know every one of them.
local pending = {}

-- Updates already announced, as a set of "name@version", and when that was.
-- Kept on the state channel so a restart of the service does not repeat the
-- notification; a restart of the shell (e.g. a new login) repeats it once.
local announced = noctalia.state.get("announced") or {}
local announcedAt = noctalia.state.get("announcedAt") or 0

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- Sends the status to the widget, the panel and the tile.
local function publish()
  noctalia.state.set(shared.STATE_KEY, status)
end

-- The "check interval" setting (minutes) in seconds; 0 turns periodic checks off.
local function intervalSeconds()
  local minutes = tonumber(noctalia.getConfig("check_interval")) or 60
  return math.max(0, math.floor(minutes)) * 60
end

-- The interval the schedule is based on, to notice changes in onConfigChanged().
local currentInterval = intervalSeconds()

-- Schedules the next check, counted from `from`. After a failure it comes
-- sooner: ERROR_RETRY_S, doubled for every further failure in a row, but
-- never later than the regular interval.
local function scheduleFrom(from, failed)
  local interval = intervalSeconds()
  if interval == 0 then
    -- No periodic checks, and no retries either.
    nextCheckAt = nil
  elseif failed then
    local backoff = ERROR_RETRY_S * 2 ^ math.max(0, failStreak - 1)
    nextCheckAt = from + math.min(backoff, interval)
  else
    nextCheckAt = from + interval
  end
end

-- Notifies about the pending updates. While xbps has to be updated first, the
-- dry run lists nothing else, so the notification explains that instead.
local function announceUpdates()
  local title = tr("notify.title")
  if status.xbpsFirst then
    noctalia.notify(title, tr("notify.xbps_first"))
    return
  end
  local names = shared.namesSummary(status.packages, status.count, NOTIFY_NAMES)
  noctalia.notify(title, shared.trn("notify.body", status.count, { names = names }))
end

-- Sends the notification a successful check calls for, if any:
--   * a manual check always reports its result;
--   * the check after an upgrade started by the plugin confirms it when
--     nothing is left (if updates are left, the next rule applies);
--   * otherwise updates that were not announced before are announced, if
--     notifications are on and enough updates are pending. While announced
--     updates are still pending, that happens at most every RENOTIFY_S.
local function notifyAfterCheck(opts)
  local current = {}
  local hasNew, stillPending = false, false
  for _, pkg in ipairs(pending) do
    -- Keyed by version too, so a newer version of a pending update counts as new.
    local id = pkg.name .. "@" .. pkg.version
    current[id] = true
    if announced[id] then
      stillPending = true
    else
      hasNew = true
    end
  end
  local now = os.time()

  if opts.manual then
    if status.count > 0 then
      announceUpdates()
    else
      noctalia.notify(tr("notify.title_ok"), tr("status.up_to_date"))
    end
  elseif opts.afterUpdate and status.count == 0 then
    noctalia.notify(tr("notify.title_ok"), tr("notify.upgraded"))
  elseif hasNew
    and (not stillPending or now - announcedAt >= RENOTIFY_S)
    and noctalia.getConfig("notify") ~= false
    and status.count >= (tonumber(noctalia.getConfig("notify_threshold")) or 1)
  then
    announceUpdates()
  else
    -- No notification. Once nothing is pending, forget what was announced, so
    -- the same updates are announced again should they come back.
    if status.count == 0 and next(announced) ~= nil then
      announced = {}
      noctalia.state.set("announced", announced)
    end
    return
  end

  -- A notification went out, covering the updates pending now.
  announced = current
  announcedAt = now
  noctalia.state.set("announced", announced)
  noctalia.state.set("announcedAt", announcedAt)
end

-- Turns a parsed dry run (see onDryRun()) into the status, applying the
-- current ignore list. onConfigChanged() calls it again with the last dry run
-- when the settings change, without running XBPS again.
local function applyDryRun(raw)
  local ignorePatterns = shared.compileIgnoreList(noctalia.getConfig("ignored_packages"))
  local packages, extras = {}, {}
  local held, ignored, downloadSize = 0, 0, 0
  local xbpsFirst = false

  for _, entry in ipairs(raw.entries) do
    if entry.action == shared.ACTION_HOLD then
      -- An update XBPS keeps back because the package is held; only count it.
      held += 1
    elseif entry.action == shared.ACTION_UPDATE then
      -- An outdated xbps blocks every other update, even when it is ignored itself.
      if entry.name == "xbps" then
        xbpsFirst = true
      end
      if shared.isIgnored(entry.name, ignorePatterns) then
        ignored += 1
      else
        -- Installed version and description come from `xbps-query -l`; they
        -- are missing if that query failed.
        local info = raw.installed[entry.name]
        table.insert(packages, {
          name = entry.name,
          version = entry.version,
          oldVersion = info and info.version or "",
          description = info and info.description or "",
          downloadSize = entry.downloadSize,
        })
        downloadSize += entry.downloadSize
      end
    else
      -- Anything else the upgrade would do: new dependencies, removals, ...
      table.insert(extras, { name = entry.name, version = entry.version, action = entry.action })
      downloadSize += entry.downloadSize
    end
  end

  table.sort(packages, function(a, b)
    return a.name < b.name
  end)
  -- The notifications need every update; the published lists are capped below.
  pending = packages

  status.phase = "idle"
  status.hasResult = true
  status.count = #packages
  status.packages = table.move(packages, 1, math.min(#packages, shared.MAX_LISTED), 1, {})
  status.extrasCount = #extras
  status.extras = table.move(extras, 1, math.min(#extras, shared.MAX_EXTRAS_LISTED), 1, {})
  status.held = held
  status.ignored = ignored
  status.downloadSize = downloadSize
  status.xbpsFirst = xbpsFirst
  status.warnings = raw.warnings
  status.error = nil
  status.checkedAt = raw.checkedAt
end

-- Assigned further down; finish() needs it to run a queued check.
local runCheck

-- Common end of every check: schedules the next one, publishes the status,
-- notifies, and runs a check that was requested in the meantime.
local function finish(opts, failed)
  checking = false
  lastFinishedAt = os.time()
  failStreak = if failed then failStreak + 1 else 0
  scheduleFrom(lastFinishedAt, failed)
  publish()
  if not failed then
    notifyAfterCheck(opts)
  elseif opts.manual then
    -- Automatic checks fail quietly (the widget shows the error); a check the
    -- user asked for gets an answer.
    noctalia.notifyError(tr("notify.title_error"), status.error)
  end
  if queued ~= nil then
    local followUp = queued
    queued = nil
    runCheck(followUp)
  end
end

-- Ends a check as failed. The last result stays published along with the error.
local function fail(message, opts)
  status.phase = "error"
  status.error = message
  finish(opts, true)
end

-- Ends a check successfully; `raw` is kept for onConfigChanged().
local function complete(raw, opts)
  lastDryRun = raw
  applyDryRun(raw)
  finish(opts, false)
end

-- Handles the result of the dry run. XBPS prints its errors as "ERROR: ..."
-- lines, and its exit code alone does not tell whether the check worked, so
-- the plan and the errors are judged together.
local function onDryRun(result, opts, gen)
  local stderr = shared.cleanText(result.stderr)
  local problems = shared.errorLines(stderr)
  if result.timedOut then
    fail(tr("errors.timeout"), opts)
    return
  end

  local entries = shared.parseTransaction(shared.cleanText(result.stdout))
  -- Failed without a plan: report the most specific message there is.
  if result.exitCode ~= 0 and #entries == 0 then
    fail(problems[#problems] or shared.lastLine(stderr) or tr("errors.exit_code", { code = result.exitCode }), opts)
    return
  end
  -- When no repository can be reached, xbps-install still exits with 0 and an
  -- empty plan. Errors without a plan are a failed check, never "up to date".
  if #entries == 0 and #problems > 0 then
    fail(problems[#problems], opts)
    return
  end
  -- A plan, but a non-zero exit code without an ERROR line: keep the plan and
  -- warn with the last line of stderr.
  if result.exitCode ~= 0 and #problems == 0 then
    table.insert(problems, shared.lastLine(stderr) or tr("errors.exit_code", { code = result.exitCode }))
  end

  -- The plan is usable from here on. Problems XBPS reported along with it
  -- (e.g. one mirror unreachable, not enough disk space) become warnings.
  local raw = {
    entries = entries,
    installed = {}, -- filled from `xbps-query -l` below
    warnings = problems,
    checkedAt = os.time(),
  }

  -- Look up the installed version and description of the packages to update.
  local wanted, any = {}, false
  for _, entry in ipairs(entries) do
    if entry.action == shared.ACTION_UPDATE then
      wanted[entry.name] = true
      any = true
    end
  end
  if not any then
    complete(raw, opts)
    return
  end

  local accepted = noctalia.runAsync({ "xbps-query", "-l" }, function(query)
    -- The check was abandoned in the meantime (see update()).
    if gen ~= generation then
      return
    end
    -- If the query fails, the list is still shown, only without the installed versions.
    if query.exitCode == 0 and not query.timedOut then
      raw.installed = shared.parseInstalled(shared.cleanText(query.stdout), wanted)
    end
    complete(raw, opts)
  end, QUERY_TIMEOUT_MS)
  -- xbps-query could not be started: carry on without the installed versions.
  if not accepted then
    complete(raw, opts)
  end
end

-- Finds the package database file. Its name carries the database format
-- version (e.g. pkgdb-0.38.plist), so it is matched by pattern.
local function findPkgdb()
  local names = noctalia.listDir(PKGDB_DIR)
  if names == nil then
    return nil
  end
  for _, name in ipairs(names) do
    if string.match(name, "^pkgdb%-[%d%.]+%.plist$") then
      return PKGDB_DIR .. "/" .. name
    end
  end
  return nil
end

-- File info ({ size, mtime, isDir }) of the package database, or nil if there
-- is none. The file is looked up again when it goes missing.
local function pkgdbInfo()
  if pkgdbPath == nil then
    pkgdbPath = findPkgdb()
    if pkgdbPath == nil then
      return nil
    end
  end
  local info = noctalia.fileInfo(pkgdbPath)
  if info == nil then
    pkgdbPath = nil
  end
  return info
end

-- Called when a check starts: the check sees the database as it is now, so
-- the changes noticed so far need no check of their own.
local function markPkgdbSeen()
  local info = pkgdbInfo()
  if info ~= nil then
    pkgdbMtime = info.mtime
    pkgdbChangedAt = nil
  end
end

-- Called on every tick. After the package database has changed (an upgrade
-- from the plugin, a terminal or any other tool), checks again once it has
-- stopped changing for PKGDB_SETTLE_S, so the count drops right after an
-- upgrade.
local function watchPkgdb(now)
  local info = pkgdbInfo()
  if info == nil then
    return
  end
  if pkgdbMtime == nil then
    -- First look: just remember the current state.
    pkgdbMtime = info.mtime
  elseif info.mtime ~= pkgdbMtime then
    -- Changed (or changed again): wait until it settles.
    pkgdbMtime = info.mtime
    pkgdbChangedAt = now
  elseif pkgdbChangedAt ~= nil and now - pkgdbChangedAt >= PKGDB_SETTLE_S then
    pkgdbChangedAt = nil
    runCheck({})
  end
end

-- Starts a check. opts.manual: the user asked for it, so the result is
-- reported in a notification. opts.afterUpdate: the upgrade terminal asked for
-- it when the upgrade ended.
runCheck = function(opts)
  opts = opts or {}
  if checking then
    -- One check at a time. Run this one when the current check finishes,
    -- merged with any request already waiting, so no option is lost.
    queued = {
      manual = (queued ~= nil and queued.manual) or opts.manual,
      afterUpdate = (queued ~= nil and queued.afterUpdate) or opts.afterUpdate,
    }
    return
  end

  -- No XBPS (not Void Linux): say so and stop scheduling checks.
  if not noctalia.commandExists("xbps-install") then
    status.phase = "unsupported"
    status.error = tr("status.unsupported")
    publish()
    nextCheckAt = nil
    if opts.manual then
      noctalia.notifyError(tr("notify.title_error"), status.error)
    end
    return
  end

  checking = true
  generation += 1
  local gen = generation
  checkStartedAt = os.time()
  markPkgdbSeen()
  status.phase = "checking"
  publish()

  -- `xbps-install [-M] -u -n`: a dry run (-n) of a full system upgrade (-u),
  -- which needs no root. -M fetches the remote repository index into memory
  -- instead of reading the local cache. The argument array bypasses the shell.
  local argv = { "xbps-install", "-u", "-n" }
  if syncRepos then
    table.insert(argv, 2, "-M")
  end
  local accepted = noctalia.runAsync(argv, function(result)
    -- Drop the result of a check that was abandoned in the meantime.
    if gen == generation then
      onDryRun(result, opts, gen)
    end
  end, DRY_RUN_TIMEOUT_MS)
  if not accepted then
    fail(tr("errors.spawn"), opts)
  end
end

-- The tool that gives the upgrade root rights: the one chosen in the settings,
-- or for "auto" the first of sudo, doas and pkexec found on PATH.
local function resolveElevation()
  local choice = noctalia.getConfig("elevation") or "auto"
  if choice ~= "auto" then
    return choice
  end
  for _, tool in ipairs({ "sudo", "doas", "pkexec" }) do
    if noctalia.commandExists(tool) then
      return tool
    end
  end
  return nil
end

-- Opens a terminal running the upgrade: the custom command from the settings,
-- or the built-in one. See shared.terminalScript() for what runs around it.
local function startUpgrade()
  local command = noctalia.string.trim(noctalia.getConfig("update_command") or "")
  if command == "" then
    local elevate = resolveElevation()
    if elevate == nil then
      noctalia.notifyError(tr("notify.title_error"), tr("errors.no_elevation"))
      return
    end
    command = shared.upgradeCommand(elevate, status.xbpsFirst)
  end

  local script = shared.terminalScript(command, {
    title = tr("terminal.title"),
    done = tr("terminal.done"),
    failed = tr("terminal.failed"),
    close = tr("terminal.close"),
  })
  if not noctalia.runInTerminal(script) then
    noctalia.notifyError(tr("notify.title_error"), tr("errors.no_terminal"))
  end
end

-- Requests from the widget, the panel and the tile (see shared.sendCommand()).
noctalia.state.watch(shared.COMMAND_KEY, function(command)
  if type(command) ~= "table" then
    return
  end
  if command.action == "check" then
    runCheck({ manual = command.notify == true })
  elseif command.action == "upgrade" then
    startUpgrade()
  end
end)

-- IPC: `noctalia msg plugin gluow3377/xbps-notify:service all <event> [payload]`
--   check               check now and report the result in a notification
--   check after-update  sent by the upgrade terminal once the upgrade has ended
--   update              open a terminal running the upgrade
function onIpc(event, payload)
  if event == "check" then
    if payload == "after-update" then
      runCheck({ afterUpdate = true })
    else
      runCheck({ manual = true })
    end
  elseif event == "update" then
    startUpgrade()
  else
    noctalia.log(`unknown IPC event '{event}' (expected check or update)`)
  end
end

-- Called when a plugin setting changes. Because this hook is defined, Noctalia
-- keeps the service and its state running instead of restarting it.
function onConfigChanged()
  local interval = intervalSeconds()
  if interval ~= currentInterval then
    currentInterval = interval
    -- Reschedule from the last finished check, keeping the shorter retry delay
    -- after a failure. A running check schedules the next one when it ends.
    if lastFinishedAt ~= nil and not checking then
      scheduleFrom(lastFinishedAt, status.phase == "error")
    end
  end

  local sync = noctalia.getConfig("sync_repos") ~= false
  if sync ~= syncRepos then
    -- The other index source may give a different plan: check again now.
    syncRepos = sync
    runCheck({})
  elseif lastDryRun ~= nil and not checking and status.phase ~= "error" then
    -- Other settings (e.g. the ignore list) only change how the plan is shown,
    -- so re-apply the last dry run instead of running XBPS again. Not while a
    -- check runs (its result uses the new settings anyway), nor after a failed
    -- one (re-applying would clear the error).
    applyDryRun(lastDryRun)
    publish()
  end
end

-- Runs every TICK_MS: abandons a stalled check, watches the package database
-- and starts the next check when it is due.
function update()
  local now = os.time()
  if checking and now - checkStartedAt >= CHECK_STALL_S then
    -- Bumping the generation turns the stalled check's callbacks into no-ops.
    generation += 1
    fail(tr("errors.stalled"), {})
  end
  watchPkgdb(now)
  if not checking and nextCheckAt ~= nil and now >= nextCheckAt then
    runCheck({})
  end
end

noctalia.setUpdateInterval(TICK_MS)
-- Publish right away, so the other entries show the restored result or "checking".
publish()
