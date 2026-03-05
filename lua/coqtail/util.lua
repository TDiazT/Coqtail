-- Author: Coqtail contributors
-- Utility functions.

local M = {}

-- Prefix for silently switching buffers.
M.bufchangepre = "silent keepjumps keepalt"

-- Print a message with a given highlight group.
local function echom(msg, hl)
  vim.cmd("echohl " .. hl)
  for _, line in ipairs(vim.split(msg, "\n")) do
    vim.cmd("unsilent echom " .. vim.fn.string(line))
  end
  vim.cmd("echohl None")
end

--- Print a warning message.
function M.warn(msg)
  echom(msg, "WarningMsg")
end

--- Print an error message.
function M.err(msg)
  echom(msg, "ErrorMsg")
end

--- Get the word under the cursor, temporarily adding '.' to iskeyword.
-- Strips trailing dots.
function M.getcurword()
  local old_keywd = vim.bo.iskeyword
  vim.cmd("setlocal iskeyword+=.")
  local cword = vim.fn.expand("<cword>")
  -- Strip trailing dots
  local dotidx = cword:match("()%.*$")
  if dotidx and dotidx > 1 then
    cword = cword:sub(1, dotidx - 1)
  end
  vim.bo.iskeyword = old_keywd
  return cword
end

--- Get the text selected in Visual mode.
function M.getvisual()
  local v_old = vim.fn.getreg("v")
  vim.cmd("noautocmd normal! gv\"vy")
  local text = vim.fn.getreg("v"):gsub("\n", " ")
  vim.fn.setreg("v", v_old)
  return text
end

-- Remove duplicate entries from the quickfix list (same lnum+col).
local function dedup_qflist()
  local qfl = vim.fn.getqflist()
  local seen = {}
  local uniq = {}
  for _, entry in ipairs(qfl) do
    local pos = entry.lnum .. "," .. entry.col
    if not seen[pos] then
      seen[pos] = true
      uniq[#uniq + 1] = entry
    end
  end
  vim.fn.setqflist(uniq)
end

-- Find all matches of `search` pattern in a list of lines.
-- Returns a list of {text, lnum (0-indexed), col (0-indexed)} tables.
local function searchall(lines, search)
  local matches = {}
  for lnum, line in ipairs(lines) do
    local s = 1
    while true do
      local col_s, col_e = line:find(search, s)
      if not col_s then break end
      matches[#matches + 1] = { line:sub(col_s, col_e), lnum - 1, col_s - 1 }
      s = col_e + 1
    end
  end
  return matches
end

--- Perform a sequence of searches and populate the quickfix list.
-- @param buf     buffer number (used when path == "")
-- @param path    file path for vimgrep (or "" to search in-buffer)
-- @param searches list of Vim \v\C patterns
-- @return true if any match was found
function M.qflist_search(buf, path, searches)
  -- Mirror the VimL: temporarily set global iskeyword to buffer-local value.
  local g_isk = vim.go.iskeyword
  vim.go.iskeyword = vim.bo[buf].iskeyword

  local found_match = false
  local has_file = path ~= ""
  local lines, buf_matches
  if not has_file then
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    buf_matches = {}
  end

  for _, search in ipairs(searches) do
    local pat = [[\v\C]] .. search
    if not has_file then
      local ms = searchall(lines, pat)
      for _, m in ipairs(ms) do
        buf_matches[#buf_matches + 1] = {
          bufnr = buf,
          text  = m[1],
          lnum  = m[2] + 1,
          col   = m[3] + 1,
        }
      end
    elseif not found_match then
      local ok = pcall(vim.cmd, "vimgrep /" .. pat .. "/j " .. path)
      if ok then found_match = true end
    else
      pcall(vim.cmd, "vimgrepadd /" .. pat .. "/j " .. path)
    end
  end

  if not has_file then
    found_match = #buf_matches > 0
    if found_match then
      vim.fn.setqflist(buf_matches)
    end
  end

  if found_match then
    dedup_qflist()
  end

  vim.go.iskeyword = g_isk
  return found_match
end

--- Get `var` from the first scope in `scopes` that defines it.
-- @param scopes list of tables (checked in order)
-- @param var    key to look up
-- @param default value if not found in any scope
function M.getvar(scopes, var, default)
  if #scopes == 0 then
    return default
  end
  local v = scopes[1][var]
  if v ~= nil then
    return v
  end
  local rest = {}
  for i = 2, #scopes do rest[#rest + 1] = scopes[i] end
  return M.getvar(rest, var, default)
end

--- Create a tagstack item for the current cursor position.
-- Returns nil if tagstack updates are disabled.
function M.preparetagstack()
  if vim.g.coqtail_update_tagstack then
    local pos = { vim.fn.bufnr("%") }
    local curpos = vim.fn.getcurpos()
    for i = 2, #curpos do pos[#pos + 1] = curpos[i] end
    local tag = vim.fn.expand("<cword>")
    return { bufnr = pos[1], from = pos, tagname = tag }
  end
  return nil
end

--- Push a tagstack item returned by preparetagstack().
function M.pushtagstack(item)
  if item ~= nil and vim.g.coqtail_update_tagstack then
    local winid = vim.fn.win_getid()
    local tagstack = vim.fn.gettagstack(winid)
    -- Truncate everything after current index (native CTRL-] behaviour).
    local items = tagstack.items
    local curidx = tagstack.curidx or #items + 1
    -- curidx is 1-based; remove items from curidx onwards.
    while #items >= curidx do
      table.remove(items)
    end
    items[#items + 1] = item
    tagstack.items = items
    tagstack.curidx = curidx + 1
    vim.fn.settagstack(winid, tagstack, "r")
  end
end

return M
