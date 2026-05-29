-- Floating-window checklist for toggling boolean Rocq printing flags.
-- open(items, get_state_fn, toggle_fn)
--   items       -- ordered list of flag name strings
--   get_state_fn(cb)       -- calls cb({[name] = bool}) with current flag states
--   toggle_fn(name, val, cb) -- called when user toggles a flag; cb(ok)

local M = {}

local CHECKED   = "[x]"
local UNCHECKED = "[ ]"
local function render_lines(items, state)
  local lines = {}
  for _, name in ipairs(items) do
    local mark = state[name] and CHECKED or UNCHECKED
    lines[#lines + 1] = mark .. " " .. name
  end
  return lines
end

local function open_float(lines)
  local width  = 0
  for _, l in ipairs(lines) do width = math.max(width, #l) end
  width = math.max(width, 30)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width    = width + 2,
    height   = #lines,
    row      = math.floor((vim.o.lines - #lines) / 2),
    col      = math.floor((vim.o.columns - width - 2) / 2),
    style    = "minimal",
    border   = "rounded",
    title    = " Rocq Flags ",
    title_pos = "center",
  })

  return buf, win
end

local function set_line(buf, row, text)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { text })
  vim.bo[buf].modifiable = false
end

--- Open the flag checklist.
-- items       - ordered list of flag name strings
-- get_state_fn(cb) - calls cb({[name]=bool}) with current states (via GetOptions)
-- toggle_fn(name, val, cb) - sets the flag; cb(ok) when done
function M.open(items, get_state_fn, toggle_fn)
  get_state_fn(function(state)
    if not state then
      vim.notify("Could not retrieve Rocq options.", vim.log.levels.WARN)
      return
    end

    local lines = render_lines(items, state)
    local buf, win = open_float(lines)

    local busy = false

    local function toggle_current()
      if busy then return end
      local row = vim.api.nvim_win_get_cursor(win)[1] - 1
      if row < 0 or row >= #items then return end
      local name    = items[row + 1]
      local new_val = not state[name]
      busy = true
      toggle_fn(name, new_val, function(ok)
        busy = false
        if ok then
          state[name] = new_val
          set_line(buf, row, (new_val and CHECKED or UNCHECKED) .. " " .. name)
        end
      end)
    end

    local function close()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end

    local map_opts = { noremap = true, silent = true, nowait = true, buffer = buf }
    vim.keymap.set("n", "<CR>", toggle_current, map_opts)
    vim.keymap.set("n", "q",    close,          map_opts)
    vim.keymap.set("n", "<Esc>", close,         map_opts)

  end)
end

return M
