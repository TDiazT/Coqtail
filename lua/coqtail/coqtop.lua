-- Author: Coqtail contributors
-- Port of python/coqtop.py to Lua.
--
-- Manages a coqidetop subprocess and provides a sequential interface to the
-- Rocq XML protocol. All public methods are callback-based; async I/O is
-- handled internally via Neovim's vim.uv (libuv) and Lua coroutines.

local xi = require("coqtail.xml_interface")

local M = {}

-- ============================================================
-- Helpers
-- ============================================================

local function join_not_empty(msgs, sep)
  sep = sep or "\n\n"
  local parts = {}
  for _, m in ipairs(msgs) do
    if m and m ~= "" then parts[#parts + 1] = m end
  end
  return table.concat(parts, sep)
end

-- Run fn inside a new coroutine and kick it off immediately.
local function async(fn)
  coroutine.wrap(fn)()
end

-- ============================================================
-- Coqtop
-- ============================================================

local Coqtop = {}
Coqtop.__index = Coqtop

--- Create a new Coqtop instance.
-- add_info_cb: optional function(string) called with info panel messages
function Coqtop.new(add_info_cb)
  return setmetatable({
    -- Process handles
    _handle  = nil,   -- vim.uv process handle
    _stdin   = nil,   -- uv_pipe_t for writing
    _stdout  = nil,   -- uv_pipe_t for reading
    _stderr  = nil,   -- uv_pipe_t for stderr

    -- Rocq state
    xml       = nil,  -- XMLInterface instance
    states    = {},   -- stack of previous state_ids
    state_id  = -1,   -- current (tip) state_id
    root_state = -1,  -- initial state_id

    -- I/O buffers
    _stdout_buf = "",
    _stderr_buf = "",

    -- Pending request state
    -- {co=coroutine, timer=uv_timer_or_nil}
    _pending = nil,

    -- Flags
    stopping    = false,
    _dune_proc  = nil,  -- running dune handle for interrupt

    add_info_cb = add_info_cb,
  }, Coqtop)
end

-- ============================================================
-- Internal I/O
-- ============================================================

-- Called whenever data arrives on stdout.
function Coqtop:_on_stdout(err, data)
  if self.stopping then return end
  if err or not data then
    -- EOF or error: process died
    if not self.stopping then
      vim.schedule(function() self:stop() end)
    end
    return
  end

  self._stdout_buf = self._stdout_buf .. data

  -- Only bother if we have a complete value node and someone is waiting
  if not xi.worth_parsing(self._stdout_buf) then return end
  if not self._pending then return end

  local result = self.xml:raw_response(self._stdout_buf)
  if result == nil then return end  -- incomplete XML, keep accumulating

  -- Consume the buffer and the pending slot
  self._stdout_buf = ""
  local pending    = self._pending
  self._pending    = nil

  local err_str    = self._stderr_buf
  self._stderr_buf = ""

  if pending.timer then
    pending.timer:stop()
    pending.timer:close()
  end

  -- Schedule the resume so that Vim API calls (matchadd, nvim_buf_set_lines,
  -- etc.) are allowed in the resumed coroutine context.
  local co_ref    = pending.co
  local result_ref = result
  local err_ref   = err_str
  vim.schedule(function() coroutine.resume(co_ref, result_ref, err_ref) end)
end

-- Called whenever data arrives on stderr.
function Coqtop:_on_stderr(err, data)
  if self.stopping then return end
  if err or not data then return end

  self._stderr_buf = self._stderr_buf .. data

  local trimmed = data:match("^%s*(.-)%s*$")
  if trimmed ~= "" then
    vim.schedule(function()
      vim.notify("[coqtail stderr] " .. trimmed, vim.log.levels.WARN)
      if self.add_info_cb then self.add_info_cb(trimmed) end
    end)
  end
end

--- Send XML bytes to coqidetop's stdin and yield until a response arrives.
-- Must be called from within a coroutine.
-- Returns: result (Ok/Err), err_str (string)
function Coqtop:_call(cmd_xml, timeout)
  assert(coroutine.running(), "_call must be called from within a coroutine")

  -- Preserve any stale buffered data so async feedback arriving between commands
  -- (e.g. "Def is defined.") is included in the next response parse.
  -- Exception: if the stale data already contains </value> it is from a stray
  -- response and must be discarded to avoid mis-parsing the upcoming response.
  if xi.worth_parsing(self._stdout_buf) then self._stdout_buf = "" end
  -- Only clear stderr to avoid stale error attribution.
  self._stderr_buf = ""

  local co      = coroutine.running()
  local pending = { co = co, timer = nil }
  self._pending = pending

  -- Optional timeout
  if timeout and timeout > 0 then
    local timer = vim.uv.new_timer()
    pending.timer = timer
    timer:start(timeout * 1000, 0, function()
      -- Timer fired: timeout
      if self._pending ~= pending then return end  -- already resolved
      self._pending = nil
      timer:stop()
      timer:close()
      self:interrupt()
      vim.schedule(function() coroutine.resume(co, xi.TIMEOUT_ERR, "") end)
    end)
  end

  -- Write to stdin
  self._stdin:write(cmd_xml, function(write_err)
    if write_err then
      if self._pending ~= pending then return end
      self._pending = nil
      if pending.timer then
        pending.timer:stop()
        pending.timer:close()
      end
      local err_obj = xi.Err.new("Write error: " .. tostring(write_err))
      vim.schedule(function() coroutine.resume(co, err_obj, "") end)
    end
    -- On success the response arrives via _on_stdout
  end)

  return coroutine.yield()
end

--- Standardize a response and combine accumulated messages.
-- Returns: result (Ok/Err, standardized), err_str
local function std_call(iface, cmd, result, err_str, stderr_is_warning)
  -- Check stderr for non-warning errors
  if not stderr_is_warning and iface.warnings_wf then
    local _, errs = xi.partition_warnings(err_str)
    if errs ~= "" then
      return xi.STDERR_ERR, err_str
    end
  end
  return iface:standardize(cmd, result), err_str
end

-- ============================================================
-- Executable discovery
-- ============================================================

--- Find the Rocq executable and initialize the XML interface.
-- Returns: version_info table on success, or error string on failure.
function Coqtop:find_rocq(coq_path, coq_prog)
  -- pcall correctly captures multiple return values from the wrapped function.
  local ok, iface, info = pcall(function()
    return xi.XMLInterface(coq_path, coq_prog)
  end)

  if not ok or not iface then
    self.xml = nil
    -- On failure pcall stores the error message in 'iface'.
    return tostring(iface or "XMLInterface failed")
  end

  self.xml        = iface
  self.version_str = info and info.str_version or ""
  return info
end

-- ============================================================
-- Dune integration
-- ============================================================

--- Check whether filename lives in a valid dune project.
-- Returns true or raises a string error.
function Coqtop:_is_valid_dune_project(filename)
  if not self.xml then return false end
  if not self.xml.valid_module(filename) then return false end

  local dir = filename:match("^(.*)/[^/]*$") or "."
  local result = vim.system(
    { "dune", "describe", "workspace" },
    { cwd = dir, text = true }
  ):wait()

  if result.code ~= 0 then
    error(result.stderr or "dune describe workspace failed")
  end
  return true
end

--- Check whether `dune <toplevel> top` works for this filename.
local function can_run_dune_toplevel(toplevel, filename)
  local dir  = filename:match("^(.*)/[^/]*$") or "."
  local base = filename:match("[^/]*$")
  local result = vim.system(
    { "dune", toplevel, "top", "--no-build", "--toplevel", "echo", base },
    { cwd = dir, text = true }
  ):wait()
  return result.code == 0
end

--- Determine whether to use "rocq" or "coq" as the dune toplevel keyword.
local function get_dune_toplevel(filename)
  if can_run_dune_toplevel("rocq", filename) then return "rocq" end
  return "coq"
end

--- Run `dune <toplevel> top` and return the list of arguments.
-- dune_compile_deps: if true, allow dune to compile dependencies
-- Returns: args_list or raises string error
function Coqtop:_get_dune_args(filename, dune_compile_deps)
  local dir      = filename:match("^(.*)/[^/]*$") or "."
  local base     = filename:match("[^/]*$")
  local toplevel = get_dune_toplevel(filename)

  local cmd = {
    "dune", toplevel, "top", base,
    "--toplevel", "echo",
    "--display=short",
  }
  if not dune_compile_deps then
    cmd[#cmd + 1] = "--no-build"
  end

  -- Run dune asynchronously; stream stderr to add_info_cb
  local stdout_buf = {}
  local stderr_buf = {}

  -- For the dune subprocess we use vim.system which is synchronous in
  -- Neovim 0.10+.  Stderr is forwarded to the info callback if set.
  local result = vim.system(cmd, {
    cwd  = dir,
    text = true,
    stderr = function(err, data)
      if data and data ~= "" then
        stderr_buf[#stderr_buf + 1] = data
        if self.add_info_cb then
          vim.schedule(function()
            if self.add_info_cb then self.add_info_cb(data:match("^%s*(.-)%s*$")) end
          end)
        end
      end
    end,
  }):wait()

  if result.code ~= 0 then
    local err_msg = table.concat(stderr_buf)
    error("dune error: " .. err_msg)
  end

  -- Split stdout into args
  local args = {}
  for w in (result.stdout or ""):gmatch("%S+") do
    args[#args + 1] = w
  end
  return args
end

-- ============================================================
-- Process lifecycle
-- ============================================================

--- Start the coqidetop process.
-- filename:          the .v file being edited
-- coqproject_args:   list of extra args from _CoqProject
-- opts:              table with use_dune, dune_compile_deps, timeout, stderr_is_warning
-- cb:                function(err_msg_or_nil, warn_str)
function Coqtop:start(filename, coqproject_args, opts, cb)
  assert(self._handle == nil, "already running")
  assert(self.xml     ~= nil, "call find_rocq() before start()")

  opts = opts or {}
  local use_dune          = opts.use_dune          or false
  local dune_compile_deps = opts.dune_compile_deps or false
  local timeout           = opts.timeout           or 0
  local stderr_is_warning = opts.stderr_is_warning or false

  async(function()
    -- Gather launch arguments
    local args = {}
    for _, a in ipairs(coqproject_args) do args[#args + 1] = a end

    if use_dune then
      local ok, dune_args = pcall(function()
        if self:_is_valid_dune_project(filename) then
          return self:_get_dune_args(filename, dune_compile_deps)
        end
        return {}
      end)
      if not ok then
        cb(tostring(dune_args), "")
        return
      end
      -- dune args prepended, user args take precedence
      local merged = {}
      for _, a in ipairs(dune_args)         do merged[#merged + 1] = a end
      for _, a in ipairs(coqproject_args)   do merged[#merged + 1] = a end
      args = merged
    end

    -- Build the full launch command
    local ok, launch = pcall(function() return self.xml:launch(filename, args) end)
    if not ok then
      cb(tostring(launch), "")
      return
    end

    -- Spawn the process
    local stdin_pipe  = vim.uv.new_pipe(false)
    local stdout_pipe = vim.uv.new_pipe(false)
    local stderr_pipe = vim.uv.new_pipe(false)

    local prog = table.remove(launch, 1)
    local handle, spawn_err = vim.uv.spawn(prog, {
      args  = launch,
      stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
    }, function(_code, _signal)
      -- Process exited
      vim.schedule(function()
        if not self.stopping then self:stop() end
      end)
    end)

    if not handle then
      stdin_pipe:close()
      stdout_pipe:close()
      stderr_pipe:close()
      cb(("Failed to spawn %s: %s"):format(prog, tostring(spawn_err)), "")
      return
    end

    -- Verify it didn't die immediately (give it a brief moment)
    -- We rely on the exit callback above if it dies later.
    self._handle = handle
    self._stdin  = stdin_pipe
    self._stdout = stdout_pipe
    self._stderr = stderr_pipe

    -- Start reading
    stdout_pipe:read_start(function(err, data)
      self:_on_stdout(err, data)
    end)
    stderr_pipe:read_start(function(err, data)
      self:_on_stderr(err, data)
    end)

    -- Initialize Rocq with the Init call
    local init_cmd, init_xml = self.xml:init()
    local response, err_str

    if init_xml ~= nil then
      response, err_str = self:_call(init_xml, timeout)
      response, err_str = std_call(self.xml, init_cmd, response, err_str, stderr_is_warning)
    else
      -- v8.4: init is a no-op, standardize returns Ok(0)
      response = self.xml:standardize(init_cmd, xi.Ok.new(nil))
      err_str  = ""
    end

    if not response:is_ok() then
      cb(response.msg, err_str)
      return
    end

    self.root_state = response.val
    self.state_id   = response.val

    cb(nil, err_str)
  end)
end

--- Stop the coqidetop process.
function Coqtop:stop()
  if self._dune_proc then
    -- If dune is running, stop it first
    pcall(function() self._dune_proc:kill("sigterm") end)
    self._dune_proc = nil
  end

  if self._handle then
    self.stopping = true

    pcall(function() self._stdin:write("") end)
    pcall(function() self._stdin:shutdown() end)
    pcall(function() self._stdin:close() end)
    pcall(function() self._stdout:read_stop() end)
    pcall(function() self._stdout:close() end)
    pcall(function() self._stderr:read_stop() end)
    pcall(function() self._stderr:close() end)
    pcall(function() self._handle:kill("sigterm") end)
    pcall(function() self._handle:close() end)

    self._handle = nil
    self._stdin  = nil
    self._stdout = nil
    self._stderr = nil

    -- Cancel any pending call
    if self._pending then
      local pending     = self._pending
      self._pending     = nil
      if pending.timer then
        pending.timer:stop()
        pending.timer:close()
      end
      coroutine.resume(pending.co, xi.Err.new("Rocq process stopped"), "")
    end
  end
end

--- Send SIGINT to coqidetop (or SIGTERM to dune if running).
function Coqtop:interrupt()
  if self._dune_proc then
    pcall(function() self._dune_proc:kill("sigterm") end)
    self._dune_proc = nil
  elseif self._handle then
    pcall(function() self._handle:kill("sigint") end)
  end
end

--- Return true if coqidetop is running.
function Coqtop:running()
  return self._handle ~= nil and not self.stopping
end

-- ============================================================
-- Rocq commands
-- ============================================================

--- Advance Rocq by sending cmd.
-- cb(ok, msg, loc_or_nil, err_str)
function Coqtop:advance(cmd, in_script, opts, cb)
  opts = opts or {}
  local timeout           = opts.timeout           or 0
  local stderr_is_warning = opts.stderr_is_warning or false
  local encoding          = opts.encoding          or "utf-8"  -- kept for compat

  async(function()
    if not self:running() then
      cb(false, "Rocq is not running.", nil, "")
      return
    end

    -- Send Add
    local add_cmd, add_xml = self.xml:add(cmd, self.state_id)
    local response, err1   = self:_call(add_xml, timeout)
    response, err1 = std_call(self.xml, add_cmd, response, err1, stderr_is_warning)

    if not response:is_ok() then
      cb(false, response.msg, response.loc, err1)
      return
    end

    -- Send Status (forces evaluation)
    local st_cmd, st_xml = self.xml:status()
    local status,  err2  = self:_call(st_xml, timeout)
    status, err2 = std_call(self.xml, st_cmd, status, err2, stderr_is_warning)

    local msgs = join_not_empty({ response.msg, response.val.res_msg, status.msg })
    local err  = err1 .. err2

    if not status:is_ok() then
      -- Rewind to before the failed add
      local ea_cmd, ea_xml = self.xml:edit_at(self.state_id, 1)
      self:_call(ea_xml)
      cb(false, msgs, status.loc, err)
      return
    end

    if in_script then
      self.states[#self.states + 1] = self.state_id
    end
    self.state_id = response.val.state_id

    cb(true, msgs, nil, err)
  end)
end

--- Go back `steps` states.
-- cb(ok, msg, extra_steps_or_nil, err_str)
function Coqtop:rewind(steps, opts, cb)
  opts  = opts  or {}
  steps = steps or 1
  local stderr_is_warning = opts.stderr_is_warning or false

  async(function()
    if not self:running() then
      cb(false, "Rocq is not running.", nil, "")
      return
    end

    local actual_steps = steps

    if actual_steps > #self.states then
      actual_steps  = #self.states  -- save before clearing
      self.state_id = self.root_state
      self.states   = {}
    else
      -- In 8.4, queries are recorded with state_id = -1.
      -- Count them within the rewound slice to avoid over-rewinding Rocq.
      local fake_steps = 0
      for i = #self.states - actual_steps + 1, #self.states do
        if self.states[i] == -1 then fake_steps = fake_steps + 1 end
      end

      local target = self.states[#self.states - actual_steps + 1]
      self.state_id = (target ~= -1) and target or 0
      -- Trim state stack
      for _ = 1, actual_steps do table.remove(self.states) end
      actual_steps = actual_steps - fake_steps
    end

    local ea_cmd, ea_xml = self.xml:edit_at(self.state_id, actual_steps)
    local response, err  = self:_call(ea_xml)
    response, err = std_call(self.xml, ea_cmd, response, err, stderr_is_warning)

    cb(
      response:is_ok(),
      response.msg,
      response:is_ok() and response.val or nil,
      err
    )
  end)
end

--- Query Rocq with cmd.
-- cb(ok, msg, loc_or_nil, err_str)
function Coqtop:query(cmd, in_script, opts, cb)
  opts = opts or {}
  local timeout           = opts.timeout           or 0
  local stderr_is_warning = opts.stderr_is_warning or false

  async(function()
    if not self:running() then
      cb(false, "Rocq is not running.", nil, "")
      return
    end

    local q_cmd, q_xml   = self.xml:query(cmd, self.state_id)
    local response, err  = self:_call(q_xml, timeout)
    response, err = std_call(self.xml, q_cmd, response, err, stderr_is_warning)

    if response:is_ok() and in_script then
      -- Record state so rewind works; use -1 for 8.4 (step-based rewind)
      if xi.vge(self.xml.version, { 8, 5, 0 }) then
        self.states[#self.states + 1] = self.state_id
      else
        self.states[#self.states + 1] = -1
      end
    end

    cb(
      response:is_ok(),
      response.msg,
      response:is_ok() and nil or response.loc,
      err
    )
  end)
end

--- Get the current goals.
-- cb(ok, msg, goals_or_nil, err_str)
function Coqtop:goals(opts, cb)
  opts = opts or {}

  -- Use Subgoals (8.16+) if available, otherwise Goal
  if self.xml.subgoal then
    self:_subgoals(opts, cb)
  else
    self:_goal(opts, cb)
  end
end

function Coqtop:_goal(opts, cb)
  local timeout           = opts.timeout           or 0
  local stderr_is_warning = opts.stderr_is_warning or false

  async(function()
    if not self:running() then
      cb(false, "Rocq is not running.", nil, "")
      return
    end

    local g_cmd, g_xml   = self.xml:goal()
    local response, err  = self:_call(g_xml, timeout)
    response, err = std_call(self.xml, g_cmd, response, err, stderr_is_warning)

    cb(
      response:is_ok(),
      response.msg,
      response:is_ok() and response.val or nil,
      err
    )
  end)
end

function Coqtop:_subgoals(opts, cb)
  local timeout           = opts.timeout           or 0
  local stderr_is_warning = opts.stderr_is_warning or false

  async(function()
    if not self:running() then
      cb(false, "Rocq is not running.", nil, "")
      return
    end

    -- Full info for focused goals only
    local sg_cmd, sg_xml = self.xml:subgoal("full",
      true,  -- fg
      false, -- bg
      false, -- shelved
      false  -- given_up
    )
    local resp_main, err_main = self:_call(sg_xml, timeout)
    resp_main, err_main = std_call(self.xml, sg_cmd, resp_main, err_main, stderr_is_warning)

    if not resp_main:is_ok() then
      cb(false, resp_main.msg, nil, err_main)
      return
    end

    -- No proof in progress
    if resp_main.val == nil then
      cb(true, resp_main.msg, nil, err_main)
      return
    end

    -- Short info for background / shelved / given_up goals (no hypotheses)
    -- Temporarily disable proof diffs to avoid a known Rocq bug
    -- (https://github.com/coq/coq/issues/16564)
    self:_suppress_diffs(opts, function(restore)
      async(function()
        local sg2_cmd, sg2_xml = self.xml:subgoal("short",
          false, -- fg
          true,  -- bg
          true,  -- shelved
          true   -- given_up
        )
        local resp_extra, err_extra = self:_call(sg2_xml, timeout)
        resp_extra, err_extra = std_call(self.xml, sg2_cmd, resp_extra, err_extra, stderr_is_warning)

        restore(function()
          local msgs = join_not_empty({ resp_main.msg, resp_extra.msg })
          local errs = err_main .. err_extra

          if not resp_extra:is_ok() then
            cb(false, msgs, nil, errs)
            return
          end

          -- Merge: fg from main call, the rest from extra call
          local goals = {
            fg       = resp_main.val.fg,
            bg       = resp_extra.val.bg,
            shelved  = resp_extra.val.shelved,
            given_up = resp_extra.val.given_up,
          }
          cb(true, msgs, goals, errs)
        end)
      end)
    end)
  end)
end

--- Set or get an option.
-- cb(ok, msg, loc_or_nil, err_str)
function Coqtop:do_option(cmd, in_script, opts, cb)
  opts = opts or {}
  local timeout           = opts.timeout           or 0
  local stderr_is_warning = opts.stderr_is_warning or false

  -- Options that Rocq expects to be set via SetOptions (not Add)
  local SCOLDABLE = {
    ["Printing Implicit"]             = true,
    ["Printing Coercions"]            = true,
    ["Printing Matching"]             = true,
    ["Printing Synth"]                = true,
    ["Printing Notations"]            = true,
    ["Printing Parentheses"]          = true,
    ["Printing All"]                  = true,
    ["Printing Records"]              = true,
    ["Printing Existential Instances"]= true,
    ["Printing Universes"]            = true,
    ["Printing Unfocused"]            = true,
    ["Printing Goal Names"]           = true,
    ["Diffs"]                         = true,
  }

  local vals, opt_name = self.xml.parse_option(cmd)

  -- Non-scoldable Set options: just use advance()
  if vals ~= nil and not SCOLDABLE[opt_name] then
    self:advance(cmd, in_script, opts, cb)
    return
  end

  async(function()
    if not self:running() then
      cb(false, "Rocq is not running.", nil, "")
      return
    end

    local option_ok = true
    local ret, err, response

    if vals == nil then
      -- Test: GetOptions
      local go_cmd, go_xml = self.xml:get_options()
      response, err = self:_call(go_xml, timeout)
      response, err = std_call(self.xml, go_cmd, response, err, stderr_is_warning)

      if response:is_ok() then
        ret = nil
        for _, item in ipairs(response.val) do
          local name, _desc, val = item[1], item[2], item[3]
          if name == opt_name then
            ret = ("%s: %s"):format(_desc, tostring(val))
            break
          end
        end
        if ret == nil then
          ret = "Invalid option name"
          option_ok = false
        end
      else
        ret = response.msg
        option_ok = false
      end
    else
      -- Set/Unset: SetOptions, try each candidate value
      local errs = {}
      for _, val in ipairs(vals) do
        local so_cmd, so_xml = self.xml:set_options(opt_name, val)
        response, err = self:_call(so_xml, timeout)
        response, err = std_call(self.xml, so_cmd, response, err, stderr_is_warning)
        ret = response.msg
        errs[#errs + 1] = err
        -- SetOptions returns empty msg on success
        option_ok = option_ok and (ret == "")
        if response:is_ok() then break end
      end
      err = table.concat(errs)
    end

    if in_script and response:is_ok() and option_ok then
      -- Associate the option change with a new state id by running a noop
      self:advance(self.xml.noop, in_script, opts, function(ok, _, _, _)
        assert(ok, "noop failed unexpectedly")
        cb(true, ret, nil, err)
      end)
      return
    elseif in_script and not option_ok then
      -- Fall back to advance() for unusual options
      self:advance(cmd, in_script, opts, cb)
      return
    end

    cb(
      response:is_ok(),
      response:is_ok() and ret or response.msg,
      response:is_ok() and nil or response.loc,
      err
    )
  end)
end

--- Route cmd to advance / query / do_option as appropriate.
-- cb(ok, msg, loc_or_nil, err_str)
function Coqtop:dispatch(cmd, cmd_no_comment, in_script, opts, cb)
  cmd_no_comment = cmd_no_comment or cmd

  if self.xml.is_option(cmd_no_comment) then
    self:do_option(cmd_no_comment, in_script, opts, cb)
  elseif self.xml:is_query(cmd_no_comment) then
    self:query(cmd, in_script, opts, cb)
  elseif in_script then
    self:advance(cmd, in_script, opts, cb)
  else
    cb(true, "Command only allowed in script.", nil, "")
  end
end

-- ============================================================
-- Diffs suppression
-- ============================================================

--- Temporarily disable proof diffs, run inner(restore), then re-enable.
-- inner: function(restore) — restore is function(done_cb) that re-enables diffs
-- This mirrors Python's suppress_diffs() context manager.
function Coqtop:_suppress_diffs(opts, inner)
  local expect_prefix = "Diffs: Some(val="

  self:do_option("Test Diffs", false, opts, function(ok, response, _, _)
    local diffs = "off"
    if ok and response:sub(1, #expect_prefix) == expect_prefix then
      diffs = response:sub(#expect_prefix + 1, -1):match("^(.-)%)$") or "off"
      diffs = diffs:gsub("^'", ""):gsub("'$", "")
    end

    local function restore(done_cb)
      if diffs ~= "off" then
        self:do_option(('Set Diffs "%s"'):format(diffs), false, opts, function()
          done_cb()
        end)
      else
        done_cb()
      end
    end

    if diffs ~= "off" then
      self:do_option('Set Diffs "off"', false, opts, function()
        inner(restore)
      end)
    else
      inner(restore)
    end
  end)
end

-- ============================================================
-- Debug
-- ============================================================

--- Toggle debug logging. Returns log file path or nil.
function Coqtop:toggle_debug()
  if self._log_path then
    -- Disable
    local path = self._log_path
    self._log_path = nil
    self._log_file = nil
    return nil
  else
    -- Enable: create a temp file
    local path = vim.fn.tempname() .. "_coqtop_debug.log"
    local f, err_msg = io.open(path, "w")
    if not f then
      vim.notify("Coqtail: failed to open debug log: " .. tostring(err_msg), vim.log.levels.WARN)
      return nil
    end
    self._log_path = path
    self._log_file = f
    return path
  end
end

M.Coqtop = Coqtop

return M
