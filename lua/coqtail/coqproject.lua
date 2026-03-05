-- Author: Coqtail contributors
-- Locate and parse _CoqProject files.
-- Parser adapted from https://github.com/coq/coq/blob/v8.19/lib/coqProject_file.ml

local M = {}

-- Skip to end of comment line (after '#'), return remaining string.
local function parse_skip_comment(s)
  local i = s:find("\n", 1, true)
  return i and s:sub(i + 1) or ""
end

-- Parse a double-quoted string (opening '"' already consumed).
-- Returns (remaining, collected_string).
local function parse_string2(s)
  local buf = {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    i = i + 1
    if c == '"' then
      break
    else
      buf[#buf + 1] = c
    end
  end
  return s:sub(i), table.concat(buf)
end

-- Parse an unquoted token (terminated by whitespace or '#').
-- Returns (remaining, collected_string).
local function parse_string(s)
  local buf = {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    i = i + 1
    if c == " " or c == "\r" or c == "\n" or c == "\t" then
      break
    elseif c == "#" then
      s = parse_skip_comment(s:sub(i))
      i = #s + 1  -- restart from new s (we replaced it)
      -- Actually need to return here since s changed
      return s, table.concat(buf)
    else
      buf[#buf + 1] = c
    end
  end
  return s:sub(i), table.concat(buf)
end

-- Parse all whitespace/comment-separated tokens from s.
-- Returns a list of strings.
local function parse_args(s)
  local accu = {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    i = i + 1
    if c == " " or c == "\r" or c == "\n" or c == "\t" then
      -- skip
    elseif c == "#" then
      -- skip comment
      local nl = s:find("\n", i, true)
      i = nl and nl + 1 or #s + 1
    elseif c == '"' then
      local rest, str = parse_string2(s:sub(i))
      accu[#accu + 1] = str
      s = rest
      i = 1
    else
      local rest, str = parse_string(s:sub(i))
      accu[#accu + 1] = c .. str
      s = rest
      i = 1
    end
  end
  return accu
end

-- Process the value of a '-arg' option, splitting on spaces while
-- respecting single-quoted groups.
local function process_extra_args(arg)
  local out = {}
  local buf = {}
  local inside_quotes = false
  local has_leftovers = false
  local i = 1
  while i <= #arg do
    local c = arg:sub(i, i)
    i = i + 1
    if c == "'" then
      inside_quotes = not inside_quotes
      has_leftovers = true
    elseif c == " " then
      if inside_quotes then
        has_leftovers = true
        buf[#buf + 1] = " "
      elseif has_leftovers then
        out[#out + 1] = table.concat(buf)
        buf = {}
        has_leftovers = false
      end
    else
      has_leftovers = true
      buf[#buf + 1] = c
    end
  end
  if has_leftovers then
    out[#out + 1] = table.concat(buf)
  end
  return out
end

--- Parse a _CoqProject file and return a list of arguments for Rocq.
-- Relative paths for -R, -Q, -I are made absolute relative to the file's dir.
-- @param file  absolute or relative path to the _CoqProject file
-- @return list of string arguments
function M.parse(file)
  local dir = vim.fn.fnamemodify(file, ":p:h")
  local dir_opts = { ["-R"] = 2, ["-Q"] = 2, ["-I"] = 1, ["-include"] = 1 }

  local lines = vim.fn.readfile(file)
  local txt = table.concat(lines, "\n")
  local raw_args = parse_args(txt)

  local proj_args = {}
  local idx = 1
  while idx <= #raw_args do
    local arg = raw_args[idx]

    if dir_opts[arg] then
      -- Make the path argument absolute.
      local absdir = raw_args[idx + 1] or ""
      if absdir:sub(1, 1) ~= "/" then
        absdir = dir .. "/" .. absdir
      end
      absdir = vim.fn.fnamemodify(absdir, ":p")
      raw_args[idx + 1] = absdir

      -- Determine end index (handle '-as' suffix for 8.4 compat).
      local endidx = idx + dir_opts[arg]
      if raw_args[endidx] == "-as" or raw_args[endidx + 1] == "-as" then
        endidx = idx + 3
      end
      for i = idx, endidx do
        if raw_args[i] then
          proj_args[#proj_args + 1] = raw_args[i]
        end
      end
      idx = endidx
    end

    if raw_args[idx] == "-arg" then
      local extra = process_extra_args(raw_args[idx + 1] or "")
      for _, v in ipairs(extra) do
        proj_args[#proj_args + 1] = v
      end
      idx = idx + 1
    end

    idx = idx + 1
  end

  return proj_args
end

--- Find _CoqProject files by searching upwards from the current directory.
-- Uses the names in `g:coqtail_project_names`.
-- @return {files=list, args=list}
function M.locate()
  local files = {}
  local args = {}
  for _, proj in ipairs(vim.g.coqtail_project_names or { "_CoqProject" }) do
    local file = vim.fn.findfile(proj, ".;")
    if file ~= "" then
      files[#files + 1] = file
      local proj_args = M.parse(file)
      for _, a in ipairs(proj_args) do
        args[#args + 1] = a
      end
    end
  end
  return files, args
end

return M
