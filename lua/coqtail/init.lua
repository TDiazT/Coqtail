-- Author: Coqtail contributors
-- Main Neovim entry point: commands, mappings, autocommands.

local M = {}

local panels   = require("coqtail.panels")
local session  = require("coqtail.session")
local util     = require("coqtail.util")
local coqproj  = require("coqtail.coqproject")
local version  = require("coqtail.version")

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

local GOAL_LINES = 5
local UNSUPPORTED_MSG =
  "Coqtail does not officially support your version of Rocq (%s).\n"
  .. "Continuing with the interface for the latest supported version (%s)."

local function default(var, val)
  if vim.g[var] == nil then
    vim.g[var] = val
  end
end

local function init_globals()
  default("coqtail_project_names",         { "_CoqProject", "_RocqProject" })
  default("coqtail_update_tagstack",        true)
  default("coqtail_treat_stderr_as_warning", false)
  default("coqtail_build_system",           "prefer-dune")
  default("coqtail_dune_compile_deps",      false)
end

-- ---------------------------------------------------------------------------
-- Session helpers
-- ---------------------------------------------------------------------------

local function get_session(buf)
  return session.get(buf or vim.api.nvim_get_current_buf())
end

local function is_running(buf)
  local sess = get_session(buf)
  return sess ~= nil and sess.started
end

-- Build opts table forwarded to every session call.
local function make_opts(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local sess = get_session(buf)
  return {
    encoding       = vim.o.encoding,
    timeout        = sess and sess.timeout or 0,
    filename       = vim.api.nvim_buf_get_name(buf),
    stderr_is_warning = vim.g.coqtail_treat_stderr_as_warning or false,
  }
end

-- ---------------------------------------------------------------------------
-- Version helpers
-- ---------------------------------------------------------------------------

local function locate_dune()
  return vim.fn.findfile("dune-project", ".;") ~= ""
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Find the path for a library name (used by includeexpr).
function M.findlib(lib)
  local buf = panels.getmain()
  local sess = get_session(buf)
  if not sess then return lib end
  local ok, result
  local done = false
  sess:find_lib(lib, make_opts(buf), function(o, r)
    ok, result = o, r
    done = true
  end)
  -- Spin wait (sync context from includeexpr)
  vim.wait(5000, function() return done end, 10)
  return (ok and result ~= nil) and result or lib
end

-- ---------------------------------------------------------------------------
-- Goal window helpers
-- ---------------------------------------------------------------------------

local function goal_start(ngoal)
  return vim.fn.search(string.format("\\m^=\\+ (%d /", ngoal), "nw")
end

local function goal_end(ngoal)
  if goal_start(ngoal) == 0 then return 0 end
  local endn = goal_start(ngoal + 1)
  return endn ~= 0 and endn - 2 or vim.fn.line("$")
end

local function goal_next()
  local g = vim.fn.search([[\m^=\+ (\d]], "nWbc")
  if g == 0 then return 1 end
  return tonumber(vim.fn.matchstr(vim.fn.getline(g), [[\d\+]])) + 1
end

local function goal_prev()
  local next = goal_next()
  return next ~= 1 and next - 2 or 0
end

--- Scroll goal panel to show the start or end of the nth goal.
-- ngoal = -1: next, ngoal = -2: previous, ngoal >= 1: specific
function M.gotogoal(ngoal, start)
  local panel = panels.switch(panels.GOAL)
  if panel == panels.NONE then return false end

  local n = ngoal == -1 and goal_next() or ngoal == -2 and goal_prev() or ngoal
  local sline = goal_start(n)
  local eline = goal_end(n)
  local line  = start and sline or eline
  if line ~= 0 then
    if start then
      local off = 1 + (vim.g.coqtail_goal_lines or GOAL_LINES)
      line = math.min(line + off, eline)
    end
    vim.cmd("normal! " .. line .. "zb")
  end

  panels.switch(panel)
  return true
end

-- ---------------------------------------------------------------------------
-- Definition lookup
-- ---------------------------------------------------------------------------

local function finddef(target)
  local buf  = panels.getmain()
  local sess = get_session(buf)
  if not sess then return nil end
  local result
  local done = false
  sess:find_def(target, make_opts(buf), function(_ok, loc)
    result = loc
    done = true
  end)
  vim.wait(5000, function() return done end, 10)
  return result
end

local function patch_path_for_dune(path)
  return path:gsub("/_build/default", "")
end

--- Populate quickfix list with definition locations of `target`.
function M.gotodef(target, bang)
  local loc = finddef(target)
  if type(loc) ~= "table" then
    util.warn("Cannot locate " .. target .. ".")
    return
  end
  local path, searches = loc[1], loc[2]
  local patched = patch_path_for_dune(path)

  if util.qflist_search(panels.getmain(), patched, searches) then
    local swb = vim.o.switchbuf
    vim.o.switchbuf = vim.o.switchbuf .. ",usetab"
    local item = util.preparetagstack()
    local ok = pcall(vim.cmd, "cfirst" .. (bang and "!" or ""))
    if ok then
      util.pushtagstack(item)
    else
      vim.cmd("botright cwindow")
    end
    vim.o.switchbuf = swb
  end
end

--- Return a list of tag entries for `target` (used by tagfunc).
function M.gettags(target, _flags, _info)
  local loc = finddef(target)
  if type(loc) ~= "table" then return nil end
  local path, searches = loc[1], loc[2]
  local tags = {}
  for _, search in ipairs(searches) do
    tags[#tags + 1] = {
      name     = target,
      filename = patch_path_for_dune(path),
      cmd      = "/\\v" .. search,
    }
  end
  return tags
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

--- Move cursor to endpoint or errorpoint.
function M.jumpto(target)
  local panel = panels.switch(panels.MAIN)
  if panel == panels.NONE then return end
  local buf  = panels.getmain()
  local sess = get_session(buf)
  if not sess then return end
  local pos
  if target == "endpoint" then
    pos = sess:endpoint()
  else
    pos = sess:errorpoint()
  end
  if pos then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
  end
end

--- Advance/rewind to the given line/col (0 = use cursor).
function M.toline(line, admit)
  local buf  = panels.getmain()
  local sess = get_session(buf)
  if not sess then return end
  local l = line == 0 and vim.fn.line(".") or line
  local c = line == 0 and vim.fn.col(".")  or vim.fn.col({ l, "$" })
  sess:to_line(l - 1, c - 1, admit, make_opts(buf), function() end)
end

--- Refresh goal/info panels.
function M.refresh()
  local buf  = panels.getmain()
  local sess = get_session(buf)
  if not sess then return end
  sess:refresh(make_opts(buf), true, false, true, function() end)
end

--- Open panels (if needed) and refresh.
function M.open_and_refresh(force)
  panels.open(force)
  M.refresh()
end

--- Interrupt the current Rocq command.
function M.interrupt()
  local buf  = panels.getmain()
  local sess = get_session(buf)
  if sess then sess:interrupt() end
end

-- ---------------------------------------------------------------------------
-- Start / Stop
-- ---------------------------------------------------------------------------

local function init_proof_diffs(coq_version)
  local arg = util.getvar({ vim.b, vim.g }, "coqtail_auto_set_proof_diffs", "")
  if arg == "" then return end
  if version.atleast(coq_version, "8.9.*") then
    local buf  = panels.getmain()
    local sess = get_session(buf)
    if sess then
      sess:query({ "Set", "Diffs", '"' .. arg .. '"' }, make_opts(buf), true, function() end)
    end
  end
end

--- Start Rocq for the current buffer.
-- @param after_start_func  optional callback run after successful start
-- @param coq_args          extra CLI arguments
function M.start(after_start_func, coq_args)
  local buf = vim.api.nvim_get_current_buf()

  if is_running(buf) then
    util.warn("Rocq is already running.")
    return false
  end

  -- Create a session if there isn't one.
  if not session.exists(buf) then
    session.create(buf)
  end
  local sess = get_session(buf)

  -- Initialize panels.
  panels.init()
  panels.open(false)

  local opts = make_opts(buf)

  -- Find Rocq binary; pass through to session.start → coqtop.find_rocq.
  opts.coq_path = vim.fn.expand(
    util.getvar({ vim.b, vim.g }, "coqtail_coq_path", vim.env.COQBIN or ""))
  opts.coq_prog = util.getvar({ vim.b, vim.g }, "coqtail_coq_prog", "")

  -- Locate project files.
  local proj_files, proj_args = coqproj.locate()
  vim.b[buf].coqtail_project_files = proj_files

  local in_dune = locate_dune()
  vim.b[buf].coqtail_in_dune_project = in_dune

  -- Determine build system.
  local use_dune
  local bs = vim.g.coqtail_build_system or "prefer-dune"
  if bs == "prefer-dune" then
    use_dune = in_dune
  elseif bs == "prefer-coqproject" then
    use_dune = (#proj_files == 0) and in_dune or false
  elseif bs == "dune" then
    use_dune = true
  elseif bs == "coqproject" then
    use_dune = false
  else
    util.err("Invalid value for config g:coqtail_build_system: " .. tostring(bs))
    M.stop()
    return false
  end
  vim.b[buf].coqtail_use_dune = use_dune

  local args_to_pass = use_dune and vim.deepcopy(coq_args or {})
                                 or vim.list_extend(vim.deepcopy(proj_args), coq_args or {})
  -- Expand each argument.
  for i, a in ipairs(args_to_pass) do
    args_to_pass[i] = vim.fn.expand(a)
  end

  sess:start(args_to_pass, opts, function(ok, err_msg, stderr)
    if not ok then
      local msg = "Failed to launch Rocq."
      if err_msg then msg = msg .. "\n" .. err_msg end
      if stderr and stderr ~= "" then msg = msg .. "\n" .. stderr end
      util.err(msg)
      M.stop()
      return
    end

    sess.started = true

    -- Show splash in info panel.
    local info_winid = vim.fn.bufwinid(vim.b[buf].coqtail_panel_bufs
                        and vim.b[buf].coqtail_panel_bufs[panels.INFO] or -1)
    if info_winid ~= -1 then
      local w = vim.api.nvim_win_get_width(info_winid)
      local h = vim.api.nvim_win_get_height(info_winid)
      sess:splash(sess.coqtop.version_str or "", w, h, opts)
    end

    init_proof_diffs(sess.coqtop.version_str or "")

    -- Only refresh goals when we won't immediately step/advance.
    -- after_start_func (e.g. RocqNext on cold start) sends its own coqidetop
    -- requests; running M.refresh() concurrently would corrupt the pending-
    -- coroutine slot and lose both responses.
    if after_start_func then
      after_start_func()
    else
      M.refresh()
    end

    -- Set up autocmds for this buffer.
    local ag = vim.api.nvim_create_augroup("CoqtailSync_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = ag, buffer = buf,
      callback = function() sess:sync(make_opts(buf), function() end) end,
    })
    vim.api.nvim_create_autocmd("BufWinLeave", {
      group = ag, buffer = buf,
      callback = function() panels.hide() end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = ag, buffer = buf,
      callback = function() M.open_and_refresh(false) end,
    })
    vim.api.nvim_create_autocmd("WinNew", {
      group = ag, buffer = buf,
      callback = function() M.refresh() end,
    })
  end)

  return true
end

--- Stop Rocq and clean up.
function M.stop()
  local buf = panels.getmain()
  local sess = get_session(buf)

  -- Guard against double-stop.
  if vim.b[buf] and vim.b[buf].coqtail_stopping then return end
  if vim.b[buf] then vim.b[buf].coqtail_stopping = true end

  M.interrupt()
  panels.switch(panels.MAIN)

  -- Remove buffer autocmds.
  pcall(vim.api.nvim_del_augroup_by_name, "CoqtailSync_" .. buf)
  pcall(vim.api.nvim_del_augroup_by_name, "CoqtailQuit_" .. buf)

  panels.cleanup(buf)

  if sess then
    sess:stop()
  end
  session.remove(buf)

  if vim.b[buf] then
    vim.b[buf].coqtail_started  = false
    vim.b[buf].coqtail_stopping = false
  end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local QUERY_COMPLETIONS = {
  "Search", "SearchAbout", "SearchPattern", "SearchRewrite", "SearchHead",
  "Check", "Print", "About", "Locate", "Show",
}

local function query_complete(arg, cmd, _cursor)
  local parts = vim.split(cmd, "%s+", { trimempty = true })
  return #parts <= 2 and table.concat(QUERY_COMPLETIONS, "\n") or ""
end

--- Define buffer-local commands (Coq* and Rocq* aliases).
function M.define_commands()
  local buf = vim.api.nvim_get_current_buf()

  local function cmd(name, rocq_name, opts, fn)
    vim.api.nvim_buf_create_user_command(buf, name,      fn, opts)
    vim.api.nvim_buf_create_user_command(buf, rocq_name, fn, opts)
  end

  -- RocqStart / CoqStart
  cmd("CoqStart", "RocqStart", { nargs = "*", complete = "file", bar = true },
    function(a)
      M.start(nil, a.fargs)
    end)

  -- RocqStop / CoqStop
  cmd("CoqStop", "RocqStop", { bar = true },
    function(_) M.stop() end)

  -- RocqInterrupt / CoqInterrupt
  cmd("CoqInterrupt", "RocqInterrupt", { bar = true },
    function(_) M.interrupt() end)

  -- RocqNext / CoqNext
  cmd("CoqNext", "RocqNext", { count = 1, bar = true }, function(a)
    if not is_running(buf) then M.start(function()
      local sess = get_session(buf)
      if sess then sess:step(a.count, make_opts(buf), function() end) end
    end, {}) return end
    local sess = get_session(buf)
    if sess then sess:step(a.count, make_opts(buf), function() end) end
  end)

  -- RocqUndo / CoqUndo
  cmd("CoqUndo", "RocqUndo", { count = 1, bar = true }, function(a)
    if not is_running(buf) then return end
    local sess = get_session(buf)
    if sess then sess:rewind(a.count, make_opts(buf), function() end) end
  end)

  -- RocqToLine / CoqToLine
  cmd("CoqToLine", "RocqToLine", { count = 0, bar = true }, function(a)
    if not is_running(buf) then M.start(function() M.toline(a.count, false) end, {}) return end
    M.toline(a.count, false)
  end)

  -- RocqOmitToLine / CoqOmitToLine
  cmd("CoqOmitToLine", "RocqOmitToLine", { count = 0, bar = true }, function(a)
    if not is_running(buf) then M.start(function() M.toline(a.count, true) end, {}) return end
    M.toline(a.count, true)
  end)

  -- RocqToTop / CoqToTop
  cmd("CoqToTop", "RocqToTop", { bar = true }, function(_)
    if not is_running(buf) then return end
    local sess = get_session(buf)
    if sess then sess:to_top(make_opts(buf), function() end) end
  end)

  -- RocqJumpToEnd / CoqJumpToEnd
  cmd("CoqJumpToEnd", "RocqJumpToEnd", { bar = true }, function(_)
    if not is_running(buf) then M.start(function() M.jumpto("endpoint") end, {}) return end
    M.jumpto("endpoint")
  end)

  -- RocqJumpToError / CoqJumpToError
  cmd("CoqJumpToError", "RocqJumpToError", { bar = true }, function(_)
    if not is_running(buf) then return end
    M.jumpto("errorpoint")
  end)

  -- RocqGotoDef / CoqGotoDef
  cmd("CoqGotoDef", "RocqGotoDef", { nargs = 1, bang = true }, function(a)
    if not is_running(buf) then M.start(function() M.gotodef(a.args, a.bang) end, {}) return end
    M.gotodef(a.args, a.bang)
  end)

  -- Rocq / Coq  (queries)
  cmd("Coq", "Rocq", {
    nargs = "+",
    complete = function(arg, cmd, cursor) return query_complete(arg, cmd, cursor) end,
  }, function(a)
    if not is_running(buf) then M.start(function()
      local sess = get_session(buf)
      if sess then sess:query(a.fargs, make_opts(buf), false, function() end) end
    end, {}) return end
    local sess = get_session(buf)
    if sess then sess:query(a.fargs, make_opts(buf), false, function() end) end
  end)

  -- RocqRestorePanels / CoqRestorePanels
  cmd("CoqRestorePanels", "RocqRestorePanels", { bar = true }, function(_)
    if not is_running(buf) then M.start(function() M.open_and_refresh(true) end, {}) return end
    M.open_and_refresh(true)
  end)

  -- RocqGotoGoal / CoqGotoGoal
  cmd("CoqGotoGoal", "RocqGotoGoal", { count = 1, bang = true, bar = true }, function(a)
    if not is_running(buf) then return end
    M.gotogoal(a.count, not a.bang)
  end)

  -- RocqGotoGoalNext / CoqGotoGoalNext
  cmd("CoqGotoGoalNext", "RocqGotoGoalNext", { bang = true, bar = true }, function(a)
    if not is_running(buf) then return end
    M.gotogoal(-1, not a.bang)
  end)

  -- RocqGotoGoalPrev / CoqGotoGoalPrev
  cmd("CoqGotoGoalPrev", "RocqGotoGoalPrev", { bang = true, bar = true }, function(a)
    if not is_running(buf) then return end
    M.gotogoal(-2, not a.bang)
  end)

  -- RocqToggleDebug / CoqToggleDebug
  cmd("CoqToggleDebug", "RocqToggleDebug", { bar = true }, function(_)
    if not session.exists(buf) then
      session.create(buf)
    end
    local sess = get_session(buf)
    if sess then sess:toggle_debug() end
  end)
end

-- ---------------------------------------------------------------------------
-- Mappings
-- ---------------------------------------------------------------------------

--- Define <Plug> and default mappings.
function M.define_mappings()
  local buf = vim.api.nvim_get_current_buf()
  local bmap = function(mode, lhs, rhs, opts)
    opts = vim.tbl_extend("force", { buffer = buf, silent = true }, opts or {})
    vim.keymap.set(mode, lhs, rhs, opts)
  end

  -- <Plug> mappings
  bmap("n", "<Plug>CoqStart",            ":RocqStart<CR>")
  bmap("n", "<Plug>CoqStop",             ":RocqStop<CR>")
  bmap("n", "<Plug>CoqInterrupt",        ":RocqInterrupt<CR>")
  bmap("n", "<Plug>CoqNext",             ":<C-U>execute v:count1 'CoqNext'<CR>")
  bmap("n", "<Plug>CoqUndo",             ":<C-U>execute v:count1 'CoqUndo'<CR>")
  bmap("n", "<Plug>CoqToLine",           ":<C-U>execute v:count 'CoqToLine'<CR>")
  bmap("n", "<Plug>CoqOmitToLine",       ":<C-U>execute v:count 'CoqOmitToLine'<CR>")
  bmap("n", "<Plug>CoqToTop",            ":RocqToTop<CR>")
  bmap("n", "<Plug>CoqJumpToEnd",        ":RocqJumpToEnd<CR>")
  bmap("n", "<Plug>CoqJumpToError",      ":RocqJumpToError<CR>")
  bmap("i", "<Plug>CoqNext",             "<C-\\><C-o>:RocqNext<CR>")
  bmap("i", "<Plug>CoqUndo",             "<C-\\><C-o>:RocqUndo<CR>")
  bmap("i", "<Plug>CoqToLine",           "<C-\\><C-o>:RocqToLine<CR>")
  bmap("i", "<Plug>CoqOmitToLine",       "<C-\\><C-o>:RocqOmitToLine<CR>")
  bmap("i", "<Plug>CoqToTop",            "<C-\\><C-o>:RocqToTop<CR>")
  bmap("i", "<Plug>CoqJumpToEnd",        "<C-\\><C-o>:RocqJumpToEnd<CR>")
  bmap("i", "<Plug>CoqJumpToError",      "<C-\\><C-o>:RocqJumpToError<CR>")
  bmap("n", "<Plug>CoqGotoDef",
    ":RocqGotoDef <C-r>=v:lua.require('coqtail').getcurword()<CR><CR>")
  bmap("n", "<Plug>CoqSearch",
    ":Rocq Search <C-r>=v:lua.require('coqtail').getcurword()<CR><CR>")
  bmap("n", "<Plug>CoqCheck",
    ":Rocq Check <C-r>=v:lua.require('coqtail').getcurword()<CR><CR>")
  bmap("n", "<Plug>CoqAbout",
    ":Rocq About <C-r>=v:lua.require('coqtail').getcurword()<CR><CR>")
  bmap("n", "<Plug>CoqPrint",
    ":Rocq Print <C-r>=v:lua.require('coqtail').getcurword()<CR><CR>")
  bmap("n", "<Plug>CoqLocate",
    ":Rocq Locate <C-r>=v:lua.require('coqtail').getcurword()<CR><CR>")
  bmap("x", "<Plug>CoqSearch",
    "<ESC>:Rocq Search <C-r>=v:lua.require('coqtail').getvisual()<CR><CR>")
  bmap("x", "<Plug>CoqCheck",
    "<ESC>:Rocq Check <C-r>=v:lua.require('coqtail').getvisual()<CR><CR>")
  bmap("x", "<Plug>CoqAbout",
    "<ESC>:Rocq About <C-r>=v:lua.require('coqtail').getvisual()<CR><CR>")
  bmap("x", "<Plug>CoqPrint",
    "<ESC>:Rocq Print <C-r>=v:lua.require('coqtail').getvisual()<CR><CR>")
  bmap("x", "<Plug>CoqLocate",
    "<ESC>:Rocq Locate <C-r>=v:lua.require('coqtail').getvisual()<CR><CR>")
  bmap("n", "<Plug>CoqRestorePanels",    ":RocqRestorePanels<CR>")
  bmap("n", "<Plug>CoqGotoGoalStart",    ":<C-U>execute v:count1 'CoqGotoGoal'<CR>")
  bmap("n", "<Plug>CoqGotoGoalEnd",      ":<C-U>execute v:count1 'CoqGotoGoal!'<CR>")
  bmap("n", "<Plug>CoqGotoGoalNextStart",":RocqGotoGoalNext<CR>")
  bmap("n", "<Plug>CoqGotoGoalNextEnd",  ":RocqGotoGoalNext!<CR>")
  bmap("n", "<Plug>CoqGotoGoalPrevStart",":RocqGotoGoalPrev<CR>")
  bmap("n", "<Plug>CoqGotoGoalPrevEnd",  ":RocqGotoGoalPrev!<CR>")
  bmap("n", "<Plug>CoqToggleDebug",      ":RocqToggleDebug<CR>")

  -- Rocq* aliases for all Coq* <Plug> maps
  local aliases = {
    { "n",  "Start"            },
    { "n",  "Stop"             },
    { "n",  "Interrupt"        },
    { "ni", "Next"             },
    { "ni", "Undo"             },
    { "ni", "ToLine"           },
    { "ni", "OmitToLine"       },  -- no default key in original, but alias exists
    { "ni", "ToTop"            },
    { "ni", "JumpToEnd"        },
    { "ni", "JumpToError"      },
    { "n",  "GotoDef"          },
    { "nx", "Search"           },
    { "nx", "Check"            },
    { "nx", "About"            },
    { "nx", "Print"            },
    { "nx", "Locate"           },
    { "ni", "RestorePanels"    },
    { "n",  "GotoGoalStart"    },
    { "n",  "GotoGoalEnd"      },
    { "n",  "GotoGoalNextStart"},
    { "n",  "GotoGoalNextEnd"  },
    { "n",  "GotoGoalPrevStart"},
    { "n",  "GotoGoalPrevEnd"  },
    { "n",  "ToggleDebug"      },
  }
  for _, info in ipairs(aliases) do
    local modes, cmd_name = info[1], info[2]
    for mode in modes:gmatch(".") do
      bmap(mode, "<Plug>Rocq" .. cmd_name, "<Plug>Coq" .. cmd_name)
    end
  end

  -- Skip default keybindings if user opted out.
  if vim.g.coqtail_nomap then return end
  local imap = not vim.g.coqtail_noimap

  local map_prefix  = vim.g.coqtail_map_prefix  or "<leader>c"
  local imap_prefix = vim.g.coqtail_imap_prefix or map_prefix

  -- {cmd, key, modes}  (key starting with '!' means no prefix)
  local maps = {
    { "Start",             "c",      "n"  },
    { "Stop",              "q",      "n"  },
    { "Interrupt",         "!\026c", "n"  },  -- <C-c> without prefix
    { "Next",              "j",      "ni" },
    { "Undo",              "k",      "ni" },
    { "ToLine",            "l",      "ni" },
    { "ToTop",             "T",      "ni" },
    { "JumpToEnd",         "G",      "ni" },
    { "JumpToError",       "E",      "ni" },
    { "GotoDef",           "gd",     "n"  },
    { "Search",            "s",      "nx" },
    { "Check",             "h",      "nx" },
    { "About",             "a",      "nx" },
    { "Print",             "p",      "nx" },
    { "Locate",            "f",      "nx" },
    { "RestorePanels",     "r",      "ni" },
    { "GotoGoalStart",     "gg",     "ni" },
    { "GotoGoalEnd",       "gG",     "ni" },
    { "GotoGoalNextStart", "!]g",    "n"  },
    { "GotoGoalNextEnd",   "!]G",    "n"  },
    { "GotoGoalPrevStart", "![g",    "n"  },
    { "GotoGoalPrevEnd",   "![G",    "n"  },
    { "ToggleDebug",       "d",      "n"  },
  }

  -- v1.5 compat overrides
  local compat15 = false
  local vc = vim.g.coqtail_version_compat or {}
  for _, v in ipairs(vc) do
    if v == "1.5" then compat15 = true; break end
  end
  if compat15 then
    local overrides = {
      { "GotoDef",           "g",   "n" },
      { "GotoGoalEnd",       "GG",  "ni"},
      { "GotoGoalNextStart", "!g]", "n" },
      { "GotoGoalNextEnd",   "!G]", "n" },
      { "GotoGoalPrevStart", "!g[", "n" },
      { "GotoGoalPrevEnd",   "!G[", "n" },
    }
    local override_map = {}
    for _, o in ipairs(overrides) do override_map[o[1]] = o end
    for i, m in ipairs(maps) do
      if override_map[m[1]] then maps[i] = override_map[m[1]] end
    end
  end

  for _, info in ipairs(maps) do
    local cmd_name, key, modes = info[1], info[2], info[3]
    local plug = "<Plug>Rocq" .. cmd_name
    local no_prefix = key:sub(1, 1) == "!"
    if no_prefix then key = key:sub(2) end

    for mode in modes:gmatch(".") do
      if mode == "i" and not imap then goto continue end
      -- Only map if not already mapped to this <Plug>.
      if vim.fn.hasmapto(plug, mode) == 0 then
        local prefix = no_prefix and "" or (mode == "i" and imap_prefix or map_prefix)
        bmap(mode, prefix .. key, plug)
      end
      ::continue::
    end
  end

  -- User hook
  if vim.fn.exists("*CoqtailHookDefineMappings") ~= 0 then
    vim.fn.call("CoqtailHookDefineMappings", {})
  end
end

-- ---------------------------------------------------------------------------
-- Registration (called from ftplugin)
-- ---------------------------------------------------------------------------

--- Expose cursor-word / visual helpers for use in mappings via v:lua.
function M.getcurword() return util.getcurword() end
function M.getvisual()  return util.getvisual()  end

--- Initialize the plugin for the current buffer.
-- Called from ftplugin/coq.lua for each new Rocq buffer.
function M.register()
  init_globals()

  local buf = vim.api.nvim_get_current_buf()
  if vim.b[buf].coqtail_registered then return end
  vim.b[buf].coqtail_registered = true

  vim.b[buf].coqtail_started   = false
  vim.b[buf].coqtail_stopping  = false
  vim.b[buf].coqtail_timeout   = 0
  vim.b[buf].coqtail_log_name  = ""

  M.define_commands()
  M.define_mappings()

  -- Quit autocmd: stop Rocq when the last window showing this buffer closes.
  local ag = vim.api.nvim_create_augroup("CoqtailQuit_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("QuitPre", {
    group = ag, buffer = buf,
    callback = function()
      if #vim.fn.win_findbuf(buf) == 1 then
        M.stop()
      end
    end,
  })

  -- Clear highlights when a window switches away from this buffer.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("CoqtailCleanupHl", { clear = false }),
    callback = function() panels.cleanuphl() end,
  })
end

return M
