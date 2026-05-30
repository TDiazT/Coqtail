-- Author: Coqtail contributors
-- Goal and Info panel management.
-- Port of autoload/coqtail/panels.vim.

local M = {}

-- ============================================================
-- Constants
-- ============================================================

M.NONE = ""
M.MAIN = "main"
M.GOAL = "goal"
M.INFO = "info"
M.AUX  = { M.GOAL, M.INFO }

-- Highlight groups for checked/sent/error/omitted regions.
local HL_GROUPS = {
  { "checked", "CoqtailChecked" },
  { "sent",    "CoqtailSent"    },
  { "error",   "CoqtailError"   },
  { "omitted", "CoqtailOmitted" },
}

-- Extmark namespaces (buffer-scoped, compatible with tree-sitter).
local NS        = vim.api.nvim_create_namespace("coqtail")
local NS_RICHPP = vim.api.nvim_create_namespace("coqtail_richpp")

-- Define Coqtail highlight groups. Uses `default = true` so user overrides
-- (e.g. via colorscheme or explicit `hi CoqtailChecked`) take precedence.
-- Must run at module load AND after any ColorScheme event (which calls hi clear).
local function define_highlights()
  local dark = vim.o.background == "dark"
  vim.api.nvim_set_hl(0, "CoqtailChecked", {
    default = true,
    ctermbg = dark and 17  or 157,
    bg      = dark and "#113311" or "LightGreen",
  })
  vim.api.nvim_set_hl(0, "CoqtailSent", {
    default = true,
    ctermbg = dark and 60  or 40,
    bg      = dark and "#007630" or "LimeGreen",
  })
  vim.api.nvim_set_hl(0, "CoqtailError",          { default = true, link = "Error"      })
  vim.api.nvim_set_hl(0, "CoqtailOmitted",         { default = true, link = "coqProofAdmit" })
  vim.api.nvim_set_hl(0, "CoqtailDiffAdded",       { default = true, link = "DiffText"   })
  vim.api.nvim_set_hl(0, "CoqtailDiffAddedBg",     { default = true, link = "DiffChange" })
  vim.api.nvim_set_hl(0, "CoqtailDiffRemoved",     { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "CoqtailDiffRemovedBg",   { default = true, link = "DiffDelete" })
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group    = vim.api.nvim_create_augroup("CoqtailHighlightLua", { clear = true }),
  callback = define_highlights,
})

-- Highlight groups for richpp (tagged token) spans.
local RICHPP_HL_GROUPS = {
  ["diff.added"]      = "CoqtailDiffAdded",
  ["diff.removed"]    = "CoqtailDiffRemoved",
  ["diff.added.bg"]   = "CoqtailDiffAddedBg",
  ["diff.removed.bg"] = "CoqtailDiffRemovedBg",
}

-- Unique counter for panel buffer names.
local counter = 0

-- ============================================================
-- Default configuration (may be overridden by user)
-- ============================================================

-- Panel layout: for each aux panel, a list of {relative_panel, direction}.
-- Direction is one of "above", "below", "left", "right".
local function default_layout()
  return {
    [M.GOAL] = { { M.INFO, "above" }, { M.MAIN, "right"  } },
    [M.INFO] = { { M.GOAL, "below" }, { M.MAIN, "right"  } },
  }
end

-- Whether to scroll each panel on update.
local function default_scroll()
  return { [M.GOAL] = false, [M.INFO] = true }
end

-- ============================================================
-- Per-buffer state helpers
-- ============================================================

--- Get panel_bufs table for `buf` (or empty table).
-- panel_bufs = {main=bufnr, goal=bufnr, info=bufnr}
local function get_panel_bufs(buf)
  local ok, v = pcall(vim.api.nvim_buf_get_var, buf, "coqtail_panel_bufs")
  return ok and v or {}
end

local function set_panel_bufs(buf, t)
  vim.api.nvim_buf_set_var(buf, "coqtail_panel_bufs", t)
end

--- Get the window ID of panel `panel` in the context of buffer `buf`.
local function panel_winid(buf, panel)
  local bufs = get_panel_bufs(buf)
  local pbuf  = bufs[panel]
  if not pbuf then return -1 end
  return vim.fn.bufwinid(pbuf)
end

--- Detect which panel is currently focused (by buffer number).
local function get_cur_panel(buf)
  for panel, pbuf in pairs(get_panel_bufs(buf)) do
    if pbuf == buf then return panel end
  end
  return M.NONE
end

-- ============================================================
-- Highlighting
-- ============================================================

--- Clear all Coqtail region highlights from `buf`.
local function clearhl(buf)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
end

--- Set a single extmark range on `buf` if the range is valid.
local function set_range(buf, grp, range)
  if not range then return end
  pcall(vim.api.nvim_buf_set_extmark, buf, NS, range[1], range[2], {
    end_row   = range[3],
    end_col   = range[4],
    hl_group  = grp,
    priority  = 90,
  })
end

--- Update region highlights on `buf` from coordinate ranges.
-- highlights: {checked, sent, error} = {sr,sc,er,ec}; omitted = list of same.
local function updatehl(buf, highlights)
  clearhl(buf)
  for _, entry in ipairs(HL_GROUPS) do
    local var, grp = entry[1], entry[2]
    local r = highlights[var]
    if type(r) == "table" then
      if type(r[1]) == "number" then
        set_range(buf, grp, r)
      else
        for _, range in ipairs(r) do set_range(buf, grp, range) end
      end
    end
  end
end

-- ============================================================
-- Panel scrolling
-- ============================================================

local function do_scroll()
  -- Scroll up if content doesn't fill the window
  local winh  = vim.fn.winheight(0)
  local disph = vim.fn.line("w$") - vim.fn.line("w0") + 1
  if vim.fn.line("w0") ~= 1 and disph < winh then
    vim.cmd("normal! Gz-")
  end
end

-- ============================================================
-- Panel content replacement
-- ============================================================

--- Replace the contents of a panel buffer (must be called in window context).
-- txt: list of strings
-- richpp: list of {line_no, col, span, hlgroup}
-- scroll: whether to scroll
local function replace(panel, txt, richpp, scroll)
  -- Save view
  local view = vim.fn.winsaveview()

  -- Update buffer text
  local pbuf = vim.api.nvim_get_current_buf()
  local old  = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
  -- Normalise empty buffer representation
  if #old == 1 and old[1] == "" then old = {} end
  if not vim.deep_equal(old, txt) then
    vim.api.nvim_buf_set_option(pbuf, "modifiable", true)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, txt)
    vim.api.nvim_buf_set_option(pbuf, "modifiable", false)
  end

  -- Apply richpp highlights (replaces previous ones via namespace clear).
  vim.api.nvim_buf_clear_namespace(pbuf, NS_RICHPP, 0, -1)
  for _, h in ipairs(richpp) do
    local line_no, col, span, tag = h[1], h[2], h[3], h[4]
    local hlg = RICHPP_HL_GROUPS[tag]
    if hlg then
      pcall(vim.api.nvim_buf_set_extmark, pbuf, NS_RICHPP, line_no - 1, col - 1, {
        end_col  = col - 1 + span,
        hl_group = hlg,
        priority = 90,
      })
    end
  end

  -- Restore view (or scroll)
  local scroll_cfg = (vim.g.coqtail_panel_scroll or default_scroll())
  if not scroll or not scroll_cfg[panel] then
    vim.fn.winrestview(view)
  end
  do_scroll()
end

-- ============================================================
-- Panel window management
-- ============================================================

--- Switch to panel `panel` from the context of buffer `buf`.
-- Returns the previous panel name (or NONE if not found).
function M.switch(panel)
  local buf       = vim.api.nvim_get_current_buf()
  local cur_panel = get_cur_panel(buf)
  if panel ~= cur_panel and panel ~= M.NONE then
    local wid = panel_winid(buf, panel)
    if wid == -1 or not vim.fn.win_gotoid(wid) then
      return M.NONE
    end
  end
  return cur_panel
end

--- Open a single auxiliary panel (if not already open).
-- Returns the opened buffer number or 0.
local function open_single(panel, force)
  local buf       = vim.api.nvim_get_current_buf()
  local from      = get_cur_panel(buf)
  if from == M.NONE then return 0 end

  local panel_bufs = get_panel_bufs(buf)
  local pbuf       = panel_bufs[panel]
  if not pbuf then return 0 end

  if vim.fn.bufwinid(pbuf) ~= -1 then
    -- Already visible
    M.switch(from)
    return 0
  end

  local panel_open = (function()
    local ok, v = pcall(vim.api.nvim_buf_get_var, pbuf, "coqtail_panel_open")
    return ok and v or false
  end)()
  if not force and not panel_open then M.switch(from); return 0 end

  local layout = vim.g.coqtail_panel_layout or default_layout()
  local opened = 0

  for _, entry in ipairs(layout[panel] or {}) do
    local relative, dir = entry[1], entry[2]
    if M.switch(relative) ~= M.NONE then
      local split_cmd
      if dir == "above" then split_cmd = "leftabove"
      elseif dir == "below" then split_cmd = "rightbelow"
      elseif dir == "left"  then split_cmd = "vertical leftabove"
      elseif dir == "right" then split_cmd = "vertical rightbelow"
      end
      if split_cmd then
        vim.cmd(split_cmd .. " sbuffer " .. pbuf)
        vim.wo.number = false
        vim.wo.relativenumber = false
        vim.api.nvim_buf_set_var(pbuf, "coqtail_panel_open", true)
        opened = pbuf
        break
      end
    end
  end

  M.switch(from)
  return opened
end

--- Open auxiliary panels.
function M.open(force)
  local buf        = vim.api.nvim_get_current_buf()
  local panel_bufs = get_panel_bufs(buf)
  local opened     = {}

  for _, panel in ipairs(M.AUX) do
    if open_single(panel, force) ~= 0 then
      opened[#opened + 1] = panel
    end
  end

  -- Restore saved sizes
  for _, panel in ipairs(opened) do
    local pbuf  = panel_bufs[panel]
    local winnr = vim.fn.bufwinnr(pbuf)
    local ok, sz = pcall(vim.api.nvim_buf_get_var, pbuf, "coqtail_panel_size")
    if ok and sz and sz[1] ~= -1 then
      vim.cmd(("vertical %dresize %d"):format(winnr, sz[1]))
      vim.cmd(("%dresize %d"):format(winnr, sz[2]))
    end
  end
end

-- ============================================================
-- Panel initialization
-- ============================================================

--- Create a single auxiliary panel buffer.
local function init_panel(name)
  local bufname  = name:sub(1, 1):upper() .. name:sub(2)   -- capitalise
  local fullname = bufname .. counter

  -- Create a hidden scratch buffer
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(pbuf, fullname)
  vim.api.nvim_buf_set_option(pbuf, "buftype",   "nofile")
  vim.api.nvim_buf_set_option(pbuf, "swapfile",  false)
  vim.api.nvim_buf_set_option(pbuf, "buflisted", false)
  vim.api.nvim_buf_set_option(pbuf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(pbuf, "modifiable",false)
  vim.api.nvim_buf_set_option(pbuf, "undolevels",50)
  -- Set filetype: "coq-goals" or "coq-infos"
  vim.api.nvim_buf_set_option(pbuf, "filetype",  "coq-" .. name .. "s")

  vim.api.nvim_buf_set_var(pbuf, "coqtail_panel_open", true)
  vim.api.nvim_buf_set_var(pbuf, "coqtail_panel_size", { -1, -1 })

  return pbuf
end

--- Create Goal/Info panel buffers for the current buffer.
function M.init()
  local main_buf   = vim.api.nvim_get_current_buf()
  local panel_bufs = { [M.MAIN] = main_buf }

  for _, panel in ipairs(M.AUX) do
    panel_bufs[panel] = init_panel(panel)
  end

  -- Store on every panel buffer so each can locate its siblings
  for _, pbuf in pairs(panel_bufs) do
    set_panel_bufs(pbuf, panel_bufs)
  end

  counter = counter + 1
end

-- ============================================================
-- Main refresh entry point (called by session.lua)
-- ============================================================

--- Refresh highlights and panel text for buffer `buf`.
-- highlights: {checked=..., sent=..., error=..., omitted=...}
-- panels_data: {info={lines,richpp}, goal={lines,richpp}}
-- scroll: boolean
function M.refresh(buf, highlights, panels_data, scroll)
  -- Guard against concurrent refresh
  local ok_ref, refreshing = pcall(vim.api.nvim_buf_get_var, buf, "coqtail_refreshing")
  if ok_ref and refreshing then return end

  local winids = vim.fn.win_findbuf(buf)
  if #winids == 0 then return end

  local ok2, err = pcall(function()
    vim.api.nvim_buf_set_var(buf, "coqtail_refreshing", true)

    updatehl(buf, highlights)

    -- Update panel text
    local panel_bufs = get_panel_bufs(buf)
    for panel, pdata in pairs(panels_data) do
      local pbuf = panel_bufs[panel]
      if not pbuf then goto continue end
      local winid = vim.fn.bufwinid(pbuf)
      if winid == -1 then goto continue end

      local txt    = pdata[1] or {}
      local richpp = pdata[2] or {}
      vim.api.nvim_win_call(winid, function()
        replace(panel, txt, richpp, scroll)
      end)
      ::continue::
    end
  end)

  vim.api.nvim_buf_set_var(buf, "coqtail_refreshing", false)

  if not ok2 then
    -- Swallow Vim:Interrupt; re-raise anything else
    if type(err) ~= "string" or not err:match("Vim:Interrupt") then
      error(err, 0)
    end
  end
end

-- ============================================================
-- Hide / cleanup
-- ============================================================

--- Close auxiliary panels and clear highlights.
function M.hide()
  local buf = vim.api.nvim_get_current_buf()
  if M.switch(M.MAIN) == M.NONE then return end

  clearhl(buf)

  -- Hide aux panels
  local panel_bufs = get_panel_bufs(buf)
  for _, panel in ipairs(M.AUX) do
    local pbuf  = panel_bufs[panel]
    if not pbuf then break end
    local winid = vim.fn.bufwinid(pbuf)
    vim.api.nvim_buf_set_var(pbuf, "coqtail_panel_open",
      winid ~= -1)
    vim.api.nvim_buf_set_var(pbuf, "coqtail_panel_size",
      { vim.fn.winwidth(winid), vim.fn.winheight(winid) })
    if winid ~= -1 then
      vim.api.nvim_win_close(winid, false)
    end
  end
end

--- Wipe panel buffers and clean up buffer variables.
function M.cleanup(buf)
  local panel_bufs = get_panel_bufs(buf)
  for _, panel in ipairs(M.AUX) do
    local pbuf = panel_bufs[panel]
    if pbuf and vim.api.nvim_buf_is_valid(pbuf) then
      vim.api.nvim_buf_delete(pbuf, { force = true })
    end
  end
  pcall(vim.api.nvim_buf_del_var, buf, "coqtail_panel_bufs")
  clearhl(buf)
end

-- ============================================================
-- Main buffer accessors
-- ============================================================

--- Return the main buffer number for the current context.
function M.getmain()
  local buf  = vim.api.nvim_get_current_buf()
  local bufs = get_panel_bufs(buf)
  return bufs[M.MAIN] or buf
end

--- Get a buffer variable from the main buffer.
function M.getvar(var)
  local ok, v = pcall(vim.api.nvim_buf_get_var, M.getmain(), var)
  return ok and v or nil
end

--- Set a buffer variable on the main buffer.
function M.setvar(var, val)
  pcall(vim.api.nvim_buf_set_var, M.getmain(), var, val)
end

return M
