-- Author: Coqtail contributors
-- LSP backend: supports coq-lsp (and future servers) via Neovim's built-in vim.lsp.
-- When a supported LSP client is attached to the buffer, this module handles goal
-- display and file-progress highlights in place of the XML/coqidetop protocol.

local M = {}

local panels = require("coqtail.panels")

-- ============================================================
-- Forward declarations (allow _BACKENDS to reference helpers
-- defined later in the file without global pollution)
-- ============================================================

local _debounced_refresh, _ensure_handler, _on_progress
local _coqlsp_progress_to_highlights, _match_from_range
local _format_coqlsp_goals, _format_coqlsp_messages

-- ============================================================
-- Backend registry
-- ============================================================

-- Each backend describes one LSP server variant.  Adding a new server (e.g.
-- vsrocq) requires only a new entry here; the lifecycle code is shared.
--
-- Fields:
--   client_names          list of possible vim.lsp client names
--   goals_method          LSP request method for proof state
--   goals_params(buf,cur) build request params from buffer + 1-indexed cursor
--   format_response(res)  (goal_lines, info_lines) from LSP response
--   progress_notification LSP notification method for file progress
--   progress_to_highlights(buf,result) → highlights table for panels.refresh

local _BACKENDS = {
  coqlsp = {
    client_names          = { "rocq", "coq_lsp" },
    goals_method          = "proof/goals",
    goals_params          = function(buf, cursor)
      return {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position     = { line = cursor[1] - 1, character = cursor[2] },
      }
    end,
    format_response       = function(result)
      return _format_coqlsp_goals(result.goals),
             _format_coqlsp_messages(result.messages)
    end,
    progress_notification = "$/coq/fileProgress",
    progress_to_highlights = function(buf, result)
      return _coqlsp_progress_to_highlights(buf, result.processing)
    end,
  },
  -- Future: vsrocq = { client_names = {"vsrocq"}, ... }
}

-- ============================================================
-- Per-buffer LSP-mode state
-- ============================================================

-- _sessions[buf] = { timer = uv_timer|nil, augroup = int, backend = table }
local _sessions = {}

-- Notification handlers are registered globally at most once per method name.
local _handlers_registered = {}

-- ============================================================
-- Public API
-- ============================================================

--- Find the active LSP client and matching backend for `buf`.
-- Respects g:coqtail_lsp_client_name as a name override.
-- Returns (client, backend) or (nil, nil).
function M.get_backend(buf)
  local override = vim.g.coqtail_lsp_client_name
  for _, backend in pairs(_BACKENDS) do
    local names = override and { override } or backend.client_names
    for _, name in ipairs(names) do
      local clients = vim.lsp.get_clients({ bufnr = buf, name = name })
      if #clients > 0 then
        return clients[1], backend
      end
    end
  end
  return nil, nil
end

--- Return true when a supported LSP client is attached to `buf`.
function M.is_active(buf)
  local client = M.get_backend(buf)
  return client ~= nil
end

--- Return true when LSP mode has been started for `buf`.
function M.is_running(buf)
  return _sessions[buf] ~= nil
end

--- Start LSP mode for `buf`.  `panels.init()` and `panels.open()` must
--- already have been called by the caller (init.lua M.start).
function M.start(buf, after_start_func)
  local client, backend = M.get_backend(buf)
  if not client then return end

  -- Register notification handler (once per notification method name).
  _ensure_handler(backend.progress_notification, function(err, result, ctx)
    _on_progress(err, result, ctx, backend)
  end)

  local ag = vim.api.nvim_create_augroup("CoqtailLSP_" .. buf, { clear = true })
  _sessions[buf] = { timer = nil, augroup = ag, backend = backend }

  -- Refresh goals on cursor movement (debounced).
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group  = ag,
    buffer = buf,
    callback = function() _debounced_refresh(buf) end,
  })

  -- Re-open panels when returning to the buffer.
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = ag, buffer = buf,
    callback = function() panels.hide() end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = ag, buffer = buf,
    callback = function()
      panels.open(false)
      M.refresh(buf)
    end,
  })

  if after_start_func then after_start_func() end

  M.refresh(buf)
end

--- Stop LSP mode for `buf` and clean up.
function M.stop(buf)
  local state = _sessions[buf]
  if not state then return end

  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end

  pcall(vim.api.nvim_del_augroup_by_id, state.augroup)

  panels.cleanup(buf)
  _sessions[buf] = nil
end

--- Request proof goals at the current cursor and update the panels.
function M.refresh(buf)
  local state = _sessions[buf]
  if not state then return end

  local client, backend = M.get_backend(buf)
  if not client then return end

  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then return end

  local cursor = vim.api.nvim_win_get_cursor(wins[1])
  local params = backend.goals_params(buf, cursor)

  client.request(backend.goals_method, params, function(err, result)
    if err or not result then return end
    local goal_lines, info_lines = backend.format_response(result)
    vim.schedule(function()
      if not _sessions[buf] then return end
      panels.refresh(buf, {}, {
        [panels.GOAL] = { goal_lines, {} },
        [panels.INFO] = { info_lines, {} },
      }, false)
    end)
  end, buf)
end

-- ============================================================
-- Private helpers
-- ============================================================

_debounced_refresh = function(buf)
  local state = _sessions[buf]
  if not state then return end
  if state.timer then
    state.timer:stop()
    state.timer:close()
  end
  state.timer = vim.uv.new_timer()
  state.timer:start(100, 0, function()
    if state.timer then
      state.timer:close()
      state.timer = nil
    end
    vim.schedule(function() M.refresh(buf) end)
  end)
end

_ensure_handler = function(notification, handler)
  if _handlers_registered[notification] then return end
  _handlers_registered[notification] = true
  vim.lsp.handlers[notification] = handler
end

_on_progress = function(err, result, _ctx, backend)
  if err or not result then return end
  local buf = vim.uri_to_bufnr(result.textDocument.uri)
  if not _sessions[buf] then return end
  local highlights = backend.progress_to_highlights(buf, result)
  vim.schedule(function()
    if not _sessions[buf] then return end
    panels.refresh(buf, highlights, {}, false)
  end)
end

-- ============================================================
-- coq-lsp specific helpers
-- ============================================================

local function _null(v)
  return v == nil or v == vim.NIL
end

_coqlsp_progress_to_highlights = function(buf, processing)
  local sent  = {}
  local err   = {}

  for _, info in ipairs(processing or {}) do
    local matches = _match_from_range(buf, info.range)
    if info.kind == 1 then       -- processed/sent
      vim.list_extend(sent, matches)
    elseif info.kind == 2        -- axiom (treated as warning → error colour)
        or info.kind == 3 then   -- error
      vim.list_extend(err, matches)
    end
  end

  return { checked = {}, sent = sent, error = err, omitted = {} }
end

_match_from_range = function(buf, range)
  local sline = range.start.line + 1
  local scol  = range.start.character + 1
  local eline = range["end"].line + 1
  local ecol  = range["end"].character + 1
  local result = {}
  for line = sline, eline do
    local col  = (line == sline) and scol or 1
    local span
    if line == eline then
      span = ecol - col
    else
      local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
      span = #text - col + 1
    end
    if span > 0 then
      table.insert(result, { line, col, span })
    end
  end
  return result
end

-- Port of s:parse_goals from autoload/coqtail/lsp.vim (coq-lsp branch).
_format_coqlsp_goals = function(goals)
  if _null(goals) then return {} end

  local lines   = {}
  local ngoals  = #(goals.goals or {})
  local nhidden = 0
  if goals.stack and #goals.stack > 0 then
    local frame = goals.stack[1]
    local prevs = (type(frame) == "table" and type(frame[1]) == "table") and frame[1] or {}
    local nexts = (type(frame) == "table" and type(frame[2]) == "table") and frame[2] or {}
    nhidden = #prevs + #nexts
  end
  local nshelved = #(goals.shelf or {})
  local nadmit   = #(goals.given_up or {})

  table.insert(lines, string.format("%d subgoal%s", ngoals, ngoals == 1 and "" or "s"))
  if nhidden > 0 then
    table.insert(lines, string.format("(%d unfocused at this level)", nhidden))
  end
  if nshelved > 0 or nadmit > 0 then
    local parts = {}
    if nshelved > 0 then table.insert(parts, string.format("%d shelved",  nshelved)) end
    if nadmit   > 0 then table.insert(parts, string.format("%d admitted", nadmit))   end
    table.insert(lines, table.concat(parts, " "))
  end
  table.insert(lines, "")

  if ngoals == 0 then
    -- Look for the next goal in the focus stack.
    local next_goal = nil
    for _, frame in ipairs(goals.stack or {}) do
      local nexts = type(frame) == "table" and frame[2] or nil
      if nexts and type(nexts) == "table" and #nexts > 0 then
        next_goal = nexts[1]
        break
      end
    end

    if next_goal then
      local bullet    = (not _null(goals.bullet)) and goals.bullet or nil
      local next_info = "Next goal"
      local info_name = next_goal.info and not _null(next_goal.info.name) and next_goal.info.name
      if info_name then
        next_info = next_info .. string.format(" [%s]", info_name)
      end
      if bullet then
        bullet    = bullet:gsub("%.$", "")
        next_info = next_info .. string.format(" (%s)", bullet)
      end
      next_info = next_info .. ":"
      table.insert(lines, next_info)
      table.insert(lines, "")
      for _, l in ipairs(vim.split(next_goal.ty or "", "\n")) do
        table.insert(lines, l)
      end
    else
      table.insert(lines, "All goals completed.")
    end
  else
    for idx, goal in ipairs(goals.goals) do
      if idx == 1 then
        -- Hypotheses are shown only for the current (first) goal.
        for _, hyp in ipairs(goal.hyps or {}) do
          local names = table.concat(hyp.names or {}, ", ")
          local line  = names .. " : " .. (hyp.ty or "")
          if not _null(hyp.def) then
            line = line .. " := " .. hyp.def
          end
          table.insert(lines, line)
        end
      end

      local hbar      = string.rep("=", 25) .. string.format(" (%d / %d)", idx, ngoals)
      local goal_name = goal.info and not _null(goal.info.name) and goal.info.name
      if goal_name then
        hbar = hbar .. string.format(" [%s]", goal_name)
      end
      table.insert(lines, "")
      table.insert(lines, hbar)
      table.insert(lines, "")
      for _, l in ipairs(vim.split(goal.ty or "", "\n")) do
        table.insert(lines, l)
      end
    end
  end

  return lines
end

-- Port of s:parse_messages from autoload/coqtail/lsp.vim (coq-lsp branch).
_format_coqlsp_messages = function(msgs)
  if _null(msgs) then return {} end
  local lines = {}
  for _, msg in ipairs(msgs) do
    if not _null(msg.text) then
      table.insert(lines, msg.text)
    end
  end
  return lines
end

return M
