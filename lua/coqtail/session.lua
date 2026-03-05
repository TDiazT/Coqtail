-- Author: Coqtail contributors
-- Per-buffer Rocq session management.
-- Corresponds to python/coqtail.py (Coqtail class and helpers).

local Coqtop = require("coqtail.coqtop")

local M = {}

-- ============================================================
-- Sentinel error values (thrown via error(), caught via pcall)
-- ============================================================

local UnmatchedError = {}
UnmatchedError.__index = UnmatchedError

function UnmatchedError.new(token, loc)
  return setmetatable({
    type  = "UnmatchedError",
    token = token,
    loc   = loc,
    range = { loc, { loc[1], loc[2] + #token } },
    msg   = "Found unmatched " .. token .. ".",
  }, UnmatchedError)
end

local NoDotError = { type = "NoDotError" }

-- ============================================================
-- Proof pattern constants
-- ============================================================

local PROOF_END_KEYWORDS = { "Qed", "Admitted", "Defined", "Abort", "Save" }
local OPAQUE_PROOF_ENDS  = { Qed = true, Admitted = true }

-- ============================================================
-- String / buffer helpers
-- ============================================================

--- Replace every non-whitespace byte with a space.
local function blank_nonws(s)
  return s:gsub("[^ \t\n]", " ")
end

--- Extract text between start_pos and stop_pos (inclusive) from a buffer.
-- buf: {string,...} 1-indexed table of line strings (no trailing newlines)
-- start_pos, stop_pos: {line, col} 0-indexed
local function between(buf, start_pos, stop_pos)
  local sline, scol = start_pos[1], start_pos[2]
  local eline, ecol = stop_pos[1], stop_pos[2]
  local parts = {}
  for i = sline, eline do
    local line = buf[i + 1] or ""
    local from = (i == sline) and (scol + 1) or 1
    local to   = (i == eline) and (ecol + 1) or #line
    parts[#parts + 1] = line:sub(from, to)
  end
  return table.concat(parts, "\n")
end

--- Translate a byte offset within msg to a {line_delta, col} position.
-- col: the column of the first character of msg in the source (0-indexed)
-- offset: 0-indexed byte offset into msg
local function pos_from_offset(col, msg, offset)
  local prefix = msg:sub(1, offset)
  -- Split on newlines
  local line_count = 0
  local last_line_start = 1
  for i = 1, #prefix do
    if prefix:sub(i, i) == "\n" then
      line_count      = line_count + 1
      last_line_start = i + 1
    end
  end
  local last_len = #prefix - last_line_start + 1
  local new_col  = last_len + (line_count == 0 and col or 0)
  return { line_count, new_col }
end

--- Remove (* *) comments from msg, replacing comment text with spaces.
-- Returns: cleaned string, list of {offset, length} (0-indexed)
local function strip_comments(msg)
  local nocom   = {}
  local com_pos = {}
  local nesting = 0
  local pos = 1  -- 1-indexed current position in msg

  while pos <= #msg do
    local start = msg:find("(*", pos, true)
    local fin   = msg:find("*)", pos, true)

    if start == nil and (fin == nil or nesting == 0) then
      nocom[#nocom + 1] = msg:sub(pos)
      break
    elseif start ~= nil and (fin == nil or start < fin) then
      if nesting == 0 then
        nocom[#nocom + 1] = msg:sub(pos, start - 1)
        nocom[#nocom + 1] = "  "            -- replace '(*' with two spaces
        com_pos[#com_pos + 1] = { start - 1, 0 }
      else
        nocom[#nocom + 1] = blank_nonws(msg:sub(pos, start + 1))
      end
      pos     = start + 2
      nesting = nesting + 1
    else
      -- fin < start or start == nil: found a comment end
      nocom[#nocom + 1] = blank_nonws(msg:sub(pos, fin + 1))
      pos     = fin + 2
      nesting = nesting - 1
      if nesting == 0 then
        com_pos[#com_pos][2] = (pos - 1) - com_pos[#com_pos][1]
      end
    end
  end

  return table.concat(nocom), com_pos
end

--- Match "Proof" at the start of s (ignoring leading whitespace).
-- Returns (keyword, full_match_str, keyword_0indexed_offset) or (nil, nil, nil).
local function match_proof_start(s)
  local i, j = s:find("^%s*Proof%f[%W]")
  if not i then return nil, nil, nil end
  local ki = s:find("Proof", i, true)
  return "Proof", s:sub(i, j), ki - i
end

--- Match a proof-end keyword at the start of s (ignoring leading whitespace).
-- Returns (keyword, full_match_str, keyword_0indexed_offset) or (nil, nil, nil).
local function match_proof_end(s)
  for _, kw in ipairs(PROOF_END_KEYWORDS) do
    local i, j = s:find("^%s*" .. kw .. "%f[%W]")
    if i then
      local ki = s:find(kw, i, true)
      return kw, s:sub(i, j), ki - i
    end
  end
  return nil, nil, nil
end

--- Find the first index (0-indexed) where sequences a and b differ, up to limit.
local function find_diff_seq(a, b, limit)
  local n = limit or math.max(#a, #b)
  for i = 1, n do
    if a[i] ~= b[i] then return i - 1 end
  end
  return nil
end

--- Return first differing {line, col} (0-indexed) in old vs new, up to stop.
-- stop: {line, col} (0-indexed exclusive bound)
-- Returns {linediff, coldiff} or nil.
local function diff_lines(old, new, stop)
  local sline, scol = stop[1], stop[2]

  -- Find first differing line (0 .. sline inclusive)
  local linediff = nil
  for i = 0, sline do
    if old[i + 1] ~= new[i + 1] then
      linediff = i
      break
    end
  end
  -- One buffer might be shorter than sline+1
  if linediff == nil then
    local n_cmp = math.min(#old, #new)
    if n_cmp <= sline then
      if #old ~= #new then
        linediff = n_cmp  -- first line that one buffer lacks
      end
    end
  end
  if linediff == nil then return nil end

  local old_line = old[linediff + 1] or ""
  local new_line = new[linediff + 1] or ""
  local col_limit = (linediff == sline) and scol or nil

  -- Find first differing column
  local n = col_limit or math.max(#old_line, #new_line)
  local coldiff = nil
  for i = 1, n do
    if old_line:sub(i, i) ~= new_line:sub(i, i) then
      coldiff = i - 1; break
    end
  end
  if coldiff == nil then
    -- Lines match up to limit; check if they have different lengths
    if col_limit == nil and #old_line ~= #new_line then
      coldiff = math.min(#old_line, #new_line)
    else
      return nil
    end
  end

  return { linediff, coldiff }
end

-- ============================================================
-- Block skippers
-- ============================================================

--- Skip from sstr to estr (nesting if sstr ~= estr).
-- lines: 1-indexed; sline/scol: 0-indexed; must point at sstr.
-- skips: {string -> function} for nested patterns to skip inside.
-- Returns {line, col} (0-indexed) after closing estr, or nil if unmatched.
local function skip_block(lines, sline, scol, sstr, estr, skips)
  local check = (lines[sline + 1] or ""):sub(scol + 1, scol + #sstr)
  assert(check == sstr,
    ("skip_block: expected '%s' at (%d,%d), got '%s'"):format(sstr, sline, scol, check))

  local nesting = 1
  scol  = scol + #sstr
  skips = skips or {}

  while nesting > 0 do
    if sline + 1 > #lines then return nil end
    local line = lines[sline + 1]

    -- End of block
    local blk_end = nil
    do
      local p = line:find(estr, scol + 1, true)
      if p then blk_end = p - 1 end
    end

    -- New start (only when sstr ~= estr for nesting)
    local blk_start = nil
    if sstr ~= estr then
      local lim = blk_end and line:sub(1, blk_end) or line
      local p   = lim:find(sstr, scol + 1, true)
      if p then blk_start = p - 1 end
    end

    -- Find earliest skip pattern
    local skip_lim = blk_start or blk_end
    local best_sp, best_fn = nil, nil
    for ss, fn in pairs(skips) do
      local lim = skip_lim and line:sub(1, skip_lim) or line
      local p   = lim:find(ss, scol + 1, true)
      if p then
        p = p - 1
        if best_sp == nil or p < best_sp then best_sp, best_fn = p, fn end
      end
    end

    if best_sp ~= nil then
      local r = best_fn(lines, sline, best_sp)
      if r == nil then return nil end
      sline, scol = r[1], r[2]
    elseif blk_end ~= nil and blk_start == nil then
      scol    = blk_end + #estr
      nesting = nesting - 1
    elseif blk_start ~= nil then
      scol    = blk_start + #sstr
      nesting = nesting + 1
    else
      sline, scol = sline + 1, 0
    end
  end

  return { sline, scol }
end

local skip_str, skip_comment, skip_elpi, skip_br2, skip_attribute

skip_str = function(lines, sl, sc)
  return skip_block(lines, sl, sc, '"', '"')
end

skip_comment = function(lines, sl, sc)
  return skip_block(lines, sl, sc, "(*", "*)")
end

skip_elpi = function(lines, sl, sc)
  return skip_block(lines, sl, sc, "lp:{{", "}}", { ["{{"] = skip_br2 })
end

skip_br2 = function(lines, sl, sc)
  return skip_block(lines, sl, sc, "{{", "}}")
end

skip_attribute = function(lines, sl, sc)
  return skip_block(lines, sl, sc, "#[", "]", { ['"'] = skip_str })
end

-- ============================================================
-- Sentence parsing
-- ============================================================

--- Find the next sentence-terminating dot after (sline, scol).
-- Returns {line, col} (0-indexed) of the dot, or raises NoDotError/UnmatchedError.
local function find_dot_after(lines, sline, scol)
  local max_line = #lines
  while sline < max_line do
    local full_line = lines[sline + 1]
    local rest      = full_line:sub(scol + 1)   -- text from scol onwards

    local dot_p  = rest:find(".",    1, true)
    local com_p  = rest:find("(*",  1, true)
    local str_p  = rest:find('"',    1, true)
    local elpi_p = rest:find("lp:{{", 1, true)

    local first = nil
    for _, p in ipairs({ dot_p, com_p, str_p, elpi_p }) do
      if p ~= nil and (first == nil or p < first) then first = p end
    end

    if first == nil then
      -- Nothing interesting: advance to next line
      sline, scol = sline + 1, 0
    elseif first ~= dot_p then
      -- A comment/string/elpi comes before the dot
      local abs = scol + first - 1  -- 0-indexed absolute column
      local r
      if first == com_p then
        r = skip_comment(lines, sline, abs)
        if r == nil then error(UnmatchedError.new("(*", { sline, abs })) end
      elseif first == str_p then
        r = skip_str(lines, sline, abs)
        if r == nil then error(UnmatchedError.new('"', { sline, abs })) end
      else
        r = skip_elpi(lines, sline, abs)
        if r == nil then error(UnmatchedError.new("lp:{{", { sline, abs })) end
      end
      sline, scol = r[1], r[2]
    else
      -- Dot is first.  Determine what kind it is.
      local dot_col = scol + dot_p - 1   -- 0-indexed absolute column of dot
      -- Two chars starting at the dot (1-indexed in full_line)
      local from_dot = full_line:sub(dot_col + 1, dot_col + 2)

      -- Sentence terminator: '.' followed by whitespace or end of line
      if from_dot:match("^%.[%s]") or from_dot == "." then
        return { sline, dot_col }
      -- '...' → terminator at the third dot
      elseif full_line:sub(dot_col + 1, dot_col + 3) == "..." then
        return { sline, dot_col + 2 }
      -- '..' → qualified-name separator or range; skip both
      elseif from_dot:sub(2, 2) == "." then
        scol = dot_col + 2
      else
        -- Qualified name separator: skip
        scol = dot_col + 1
      end
    end
  end
  error(NoDotError)
end

--- Try to parse a bracketed goal selector starting at (line, col).
-- Returns {selline, selcol} of the '{' if successful, nil otherwise.
local function try_goal_selector(lines, line, col)
  local state = "start"
  local sl, sc = line, col

  local function is_digit(c) return c >= "0" and c <= "9" end
  local function is_space(c)
    return c == " " or c == "\t" or c == "\n" or c == "\r"
  end
  local function is_ident(c)
    return (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or
           is_digit(c) or c == "_" or c:byte() >= 128
  end

  while sl < #lines do
    local ln = lines[sl + 1]
    if sc >= #ln then sc = 0; sl = sl + 1; goto continue end
    local c = ln:sub(sc + 1, sc + 1)

    if     state == "start"       and is_digit(c) then state = "digit";      sc = sc + 1
    elseif state == "start"       and c == "["    then state = "beforename"; sc = sc + 1
    elseif state == "digit"       and is_digit(c) then                       sc = sc + 1
    elseif state == "digit"       and is_space(c) then state = "beforecolon";sc = sc + 1
    elseif state == "digit"       and c == ":"    then state = "aftercolon"; sc = sc + 1
    elseif state == "beforename"  and is_space(c) then                       sc = sc + 1
    elseif state == "beforename"  and is_ident(c) then state = "name";       sc = sc + 1
    elseif state == "name"        and is_ident(c) then                       sc = sc + 1
    elseif state == "name"        and is_space(c) then state = "aftername";  sc = sc + 1
    elseif state == "name"        and c == "]"    then state = "beforecolon";sc = sc + 1
    elseif state == "aftername"   and is_space(c) then                       sc = sc + 1
    elseif state == "aftername"   and c == "]"    then state = "beforecolon";sc = sc + 1
    elseif state == "beforecolon" and is_space(c) then                       sc = sc + 1
    elseif state == "beforecolon" and c == ":"    then state = "aftercolon"; sc = sc + 1
    elseif state == "aftercolon"  and is_space(c) then                       sc = sc + 1
    elseif state == "aftercolon"  and c == "{"    then return { sl, sc }
    else return nil
    end
    ::continue::
  end
  return nil
end

--- Find the next sentence after (sline, scol).
-- Returns {line, col} (0-indexed) of the sentence's last character (inclusive).
-- Raises NoDotError or UnmatchedError.
local function find_next_sentence(lines, sline, scol)
  local braces  = { ["{"] = true, ["}"] = true }
  local bullets = { ["-"] = true, ["+"] = true, ["*"] = true }

  local line, col = sline, scol
  local first_line = nil  -- declared outside while so it's visible after break

  while true do
    -- Skip leading whitespace across lines
    local found_line = nil
    first_line = nil
    for l = line, #lines - 1 do
      local rest     = lines[l + 1]:sub(col + 1)
      local stripped = rest:match("^%s*(.*)")
      if stripped:match("%S") then
        col        = col + (#rest - #stripped)
        first_line = stripped
        found_line = l
        break
      end
      col = 0
    end

    if first_line == nil then error(NoDotError) end
    line = found_line

    local fc2 = first_line:sub(1, 1)
    if fc2 == "(" and first_line:sub(1, 2) == "(*" then
      local r = skip_comment(lines, line, col)
      if r == nil then error(UnmatchedError.new("(*", { line, col })) end
      line, col = r[1], r[2]
    elseif fc2 == "#" and first_line:sub(1, 2) == "#[" then
      local r = skip_attribute(lines, line, col)
      if r == nil then error(UnmatchedError.new("#[", { line, col })) end
      line, col = r[1], r[2]
    else
      break
    end
  end

  local fc = first_line:sub(1, 1)

  -- Brace or bullet
  if braces[fc] then
    return { line, col }
  end
  if bullets[fc] then
    local end_col = col
    for c in first_line:sub(2):gmatch(".") do
      if c == fc then end_col = end_col + 1 else break end
    end
    return { line, end_col }
  end

  -- Goal selector
  if fc:match("%d") or fc == "[" then
    local sel = try_goal_selector(lines, line, col)
    if sel then return sel end
  end

  return find_dot_after(lines, line, col)
end

--- Return {start, stop} range of the next sentence after `after`.
local function get_message_range(lines, after)
  return { start = after, stop = find_next_sentence(lines, after[1], after[2]) }
end

-- ============================================================
-- Proof skipping helpers
-- ============================================================

--- Shrink a sentence range to begin at the keyword identified by (match_str, match_off).
-- range_: {start={l,c}, stop={l,c}}
-- match_str: text that was matched (including leading whitespace)
-- match_off: 0-indexed offset of the keyword within match_str
local function shrink_range_to_match(range_, match_str, match_off)
  local _, nlines = match_str:gsub("\n", "\n")
  local sline = range_.start[1] + nlines
  local scol
  if nlines == 0 then
    scol = match_off + range_.start[2]
  else
    -- 0-indexed offset of last '\n' in match_str
    local after_nl  = match_str:match(".*\n()") or 1
    local last_nl   = after_nl - 2
    scol = match_off - (last_nl + 1)
  end
  return { start = { sline, scol }, stop = range_.stop }
end

--- Scan send_queue from queue_start to find if the current proof is opaque.
-- Returns the {start,stop} range of the opaque end, or nil.
local function find_opaque_proof_end(buffer, send_queue, queue_start)
  queue_start = queue_start or 1
  local pdepth = 1
  for i = queue_start, #send_queue do
    local range_ = send_queue[i]
    local msg    = between(buffer, range_.start, range_.stop)
    local nocom  = strip_comments(msg)

    local ps_kw, _, _ = match_proof_start(nocom)
    local pe_kw, pe_full, pe_off = match_proof_end(nocom)
    if ps_kw then
      pdepth = pdepth + 1
    elseif pe_kw then
      pdepth = pdepth - 1
      if pdepth == 0 then
        if OPAQUE_PROOF_ENDS[pe_kw] then
          return shrink_range_to_match(range_, pe_full, pe_off)
        else
          return nil
        end
      end
    end
    if pdepth == 0 then break end
  end
  return nil
end

-- ============================================================
-- Vim highlight pattern generator (mirrors Python's Matcher class)
-- ============================================================

--- Build a vim regex that matches a 2-D region.
-- All indices 0-indexed; stops exclusive (Python slice convention); nil = unbounded.
local function make_match_pattern(row_s, row_e, col_s, col_e)
  local function sh(x) return x ~= nil and x + 1 or nil end
  local ls = sh(row_s) or 1
  local le = sh(row_e)
  local cs = sh(col_s) or 1
  local ce = sh(col_e)

  local function dim_int(n, t)   return ("\\%%%d%s"):format(n, t) end
  local function dim_sl(s, e, t)
    local p = ""
    if s ~= nil and s > 1 then p = p .. ("\\%%>%d%s"):format(s - 1, t) end
    if e ~= nil            then p = p .. ("\\%%<%d%s"):format(e,     t) end
    return p
  end

  if le ~= nil and ls == le - 1 then
    return dim_int(ls, "l") .. dim_sl(cs, ce, "c")
  end

  local parts = {}
  local first = dim_int(ls, "l") .. dim_sl(cs, nil, "c")
  if first ~= "" then parts[#parts + 1] = first end
  if le ~= nil and ls + 1 < le - 1 then
    parts[#parts + 1] = dim_sl(ls + 1, le - 1, "l")
  end
  if le ~= nil then
    local last = dim_int(le - 1, "l") .. dim_sl(nil, ce, "c")
    if last ~= "" then parts[#parts + 1] = last end
  end

  local nz = {}
  for _, p in ipairs(parts) do if p ~= "" then nz[#nz + 1] = p end end
  return table.concat(nz, "\\|")
end

-- ============================================================
-- Goal display helpers
-- ============================================================

--- Convert tagged tokens to {lines, highlights}.
-- tagged_tokens: string (old Rocq) or list of {text, tag|nil}
-- line_no: 0-indexed starting line (converted to 1-indexed internally)
local function lines_and_highlights(tagged_tokens, line_no)
  if type(tagged_tokens) == "string" then
    local ls = {}
    for l in (tagged_tokens .. "\n"):gmatch("([^\n]*)\n") do ls[#ls + 1] = l end
    return ls, {}
  end

  local lines, highlights = {}, {}
  line_no = line_no + 1
  local line, index = "", 1

  for _, pair in ipairs(tagged_tokens) do
    local token, tag = pair[1], pair[2]
    local s = 1
    while true do
      local nl = token:find("\n", s, true)
      local tok = nl and token:sub(s, nl - 1) or token:sub(s)
      local tok_len = #tok
      if tag ~= nil then
        highlights[#highlights + 1] = { line_no, index, tok_len, tag }
      end
      line  = line .. tok
      index = index + tok_len
      if nl then
        lines[#lines + 1] = line
        line_no = line_no + 1
        line, index = "", 1
        s = nl + 1
      else
        break
      end
    end
  end
  lines[#lines + 1] = line
  return lines, highlights
end

--- Construct vim search patterns for the definition of tgt_name with tgt_type.
local function get_searches(tgt_type, tgt_name)
  local auto_names = {
    { "Constructor", "Inductive", "^Build_(.*)",     1 },
    { "Constant",    "Inductive", "^(.-)_ind$",      1 },
    { "Constant",    "Inductive", "^(.-)_rect?$",    1 },
  }
  local type_to_vernac = {
    Inductive       = { "(Co)?Inductive", "Variant", "Class", "Record" },
    Constant        = {
      "Definition", "Let", "(Co)?Fixpoint", "Function", "Instance",
      "Theorem", "Lemma", "Remark", "Fact", "Corollary", "Proposition",
      "Example", "Parameters?", "Axioms?", "Conjectures?",
    },
    Notation        = { "Notation" },
    Variable        = { "Variables?", "Hypothes[ie]s", "Context" },
    Ltac            = { "Ltac" },
    Module          = { "Module" },
    ["Module Type"] = { "Module Type" },
  }

  local search_names = { tgt_name }
  local search_types = { tgt_type }
  for _, e in ipairs(auto_names) do
    if tgt_type == e[1] then
      local m = tgt_name:match(e[3])
      if m then search_names[#search_names + 1] = m; search_types[#search_types + 1] = e[2] end
    end
  end

  local vernacs = {}
  for _, st in ipairs(search_types) do
    for _, v in ipairs(type_to_vernac[st] or {}) do vernacs[#vernacs + 1] = v end
  end

  local sn = table.concat(search_names, "|")
  local sv = table.concat(vernacs, "|")
  return {
    ("<(%s)>\\s*\\zs<(%s)>"):format(sv, sn),
    ("<(%s)>"):format(sn),
  }
end

-- ============================================================
-- Session class
-- ============================================================

local Session = {}
Session.__index = Session

--- Create and fully initialize a Session for buffer `buf`.
function Session.create(buf)
  local self = setmetatable({
    buf           = buf,
    changedtick   = 0,
    buffer        = {},
    endpoints     = {},
    send_queue    = {},
    error_at      = nil,
    omitted_proofs = {},
    info_msg      = {},
    goal_msg      = { "No goals." },
    goal_hls      = {},
    _log          = "",
    coqtop        = nil,  -- set below
  }, Session)

  self.coqtop = Coqtop.new(function(msg)
    self:_add_info_callback(msg)
  end)

  return self
end

-- ============================================================
-- Buffer / changedtick accessors
-- ============================================================

function Session:_get_buffer()
  return vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
end

function Session:_get_changedtick()
  return vim.api.nvim_buf_get_changedtick(self.buf)
end

-- ============================================================
-- Panel state
-- ============================================================

function Session:_set_info(msg, reset)
  if msg == nil then return end
  local new_lines
  if type(msg) == "string" then
    new_lines = {}
    for l in (msg .. "\n"):gmatch("([^\n]*)\n") do new_lines[#new_lines + 1] = l end
  else
    new_lines = msg
  end

  if reset or #self.info_msg == 0 then
    self.info_msg = new_lines
  else
    self.info_msg[#self.info_msg + 1] = ""
    for _, l in ipairs(new_lines) do self.info_msg[#self.info_msg + 1] = l end
  end
  if #self.info_msg == 1 and self.info_msg[1] == "" then
    self.info_msg = {}
  end
end

function Session:_set_goal(msg, clear)
  if msg ~= nil then
    self.goal_msg = msg[1]
    self.goal_hls = msg[2]
  end
  if clear or table.concat(self.goal_msg or {}) == "" then
    self.goal_msg = { "No goals." }
    self.goal_hls = {}
  end
end

function Session:_add_info_callback(msg)
  self:_set_info(msg, false)
  local panels = require("coqtail.panels")
  panels.refresh(self.buf, self:_get_highlights(), self:_get_panels(false), false)
end

function Session:print_stderr(err)
  if err and err ~= "" then
    self:_set_info("From stderr:\n" .. err, false)
  end
end

-- ============================================================
-- Highlights and panels accessors
-- ============================================================

function Session:_get_highlights()
  local m = { checked = nil, sent = nil, error = nil, omitted = nil }

  if #self.endpoints > 0 then
    local ep = self.endpoints[#self.endpoints]
    m.checked = make_match_pattern(nil, ep[1] + 1, nil, ep[2])
  end

  if #self.send_queue > 0 then
    local sline, scol
    if #self.endpoints > 0 then
      local ep = self.endpoints[#self.endpoints]
      sline, scol = ep[1], ep[2]
    else
      sline, scol = 0, -1
    end
    local lq    = self.send_queue[#self.send_queue]
    m.sent = make_match_pattern(sline, lq.stop[1] + 1, scol, lq.stop[2])
  end

  if self.error_at ~= nil then
    local s, e = self.error_at[1], self.error_at[2]
    m.error = make_match_pattern(s[1], e[1] + 1, s[2], e[2])
  end

  if #self.omitted_proofs > 0 then
    local ranges = {}
    for _, pr in ipairs(self.omitted_proofs) do
      for _, range_ in ipairs({ pr.proof, pr.qed }) do
        local sl, sc = range_.start[1], range_.start[2]
        local el, ec = range_.stop[1],  range_.stop[2]
        for l = sl, el do
          local c        = (l == sl) and sc or 0
          local line_str = self.buffer[l + 1] or ""
          local span     = (l == el) and (ec - c) or (#line_str - c)
          ranges[#ranges + 1] = { l + 1, c + 1, span }
        end
      end
    end
    m.omitted = ranges
  end

  return m
end

function Session:_get_panels(goals)
  local p = { info = { self.info_msg, {} } }
  if goals then p.goal = { self.goal_msg, self.goal_hls } end
  return p
end

-- ============================================================
-- UI refresh
-- ============================================================

--- Immediately refresh the panels (no goals fetch).
function Session:_do_refresh(goals, _force, scroll)
  local panels = require("coqtail.panels")
  panels.refresh(self.buf, self:_get_highlights(),
    self:_get_panels(goals or false), scroll or false)
end

--- Async refresh: fetch goals if requested, then update panels, then call cb().
function Session:refresh(opts, goals, _force, scroll, cb)
  goals  = (goals  == nil) and true  or goals
  scroll = scroll or false

  if not goals then
    self:_do_refresh(false, true, scroll)
    if cb then cb() end
    return
  end

  self.coqtop:goals(opts, function(_ok, msg, goals_val, stderr)
    self:print_stderr(stderr)
    if goals_val ~= nil then
      self:_pp_goals_async(goals_val, opts, function(formatted)
        self:_set_goal(formatted)
        if msg and msg ~= "" then self:_set_info(msg, false) end
        self:_do_refresh(true, true, scroll)
        if cb then cb() end
      end)
    else
      self:_set_goal(nil, true)
      if msg and msg ~= "" then self:_set_info(msg, false) end
      self:_do_refresh(true, true, scroll)
      if cb then cb() end
    end
  end)
end

-- ============================================================
-- Goal pretty-printing
-- ============================================================

function Session:_pp_goals_async(goals, opts, cb)
  local lines, highlights = {}, {}
  local ngoals   = #goals.fg
  local nhidden  = (goals.bg and goals.bg[1]) and #goals.bg[1] or 0
  local nshelved = #goals.shelved
  local nadmit   = #goals.given_up

  lines[#lines + 1] = ngoals == 1 and "1 subgoal" or (ngoals .. " subgoals")
  if nhidden  > 0 then lines[#lines + 1] = "(" .. nhidden .. " unfocused at this level)" end
  if nshelved > 0 or nadmit > 0 then
    local ps = {}
    if nshelved > 0 then ps[#ps + 1] = nshelved .. " shelved"  end
    if nadmit   > 0 then ps[#ps + 1] = nadmit   .. " admitted" end
    lines[#lines + 1] = table.concat(ps, " ")
  end
  lines[#lines + 1] = ""

  local function add_content(tagged)
    local ls, hls = lines_and_highlights(tagged, #lines)
    for _, l in ipairs(ls)  do lines[#lines + 1]      = l  end
    for _, h in ipairs(hls) do highlights[#highlights + 1] = h end
  end

  if ngoals == 0 then
    local next_goal = nil
    for _, bgs in ipairs(goals.bg or {}) do
      if bgs and bgs[1] then next_goal = bgs[1]; break end
    end

    if next_goal ~= nil then
      -- Need bullet hint: async query
      self:_do_query("Show.", opts, function(ok, show, _)
        local bullet = nil
        if ok then
          bullet = show:match("bullet ([-+*}]+)") or
                   show:match('unfocusing with "([-+*}]+)"')
        end

        local binfo = ""
        if bullet == "}" then
          binfo = "end this goal with '}'"
        elseif bullet then
          binfo = "use bullet '" .. bullet .. "'"
        end

        local ni = "Next goal"
        if next_goal.name then ni = ni .. " [" .. next_goal.name .. "]" end
        if binfo ~= ""    then ni = ni .. " (" .. binfo .. ")"          end
        ni = ni .. ":"

        lines[#lines + 1] = ni
        lines[#lines + 1] = ""
        add_content(next_goal.ccl)
        cb({ lines, highlights })
      end)
    else
      lines[#lines + 1] = "All goals completed."
      cb({ lines, highlights })
    end
    return
  end

  for idx, goal in ipairs(goals.fg) do
    if idx == 1 then
      for _, hyp in ipairs(goal.hyp) do add_content(hyp) end
    end
    local hbar = ("="):rep(25) .. (" (%d / %d)"):format(idx, ngoals)
    if goal.name then hbar = hbar .. " [" .. goal.name .. "]" end
    lines[#lines + 1] = ""
    lines[#lines + 1] = hbar
    lines[#lines + 1] = ""
    add_content(goal.ccl)
  end

  cb({ lines, highlights })
end

-- ============================================================
-- Sync
-- ============================================================

function Session:sync(opts, cb)
  local newtick = self:_get_changedtick()
  if newtick == self.changedtick then
    if cb then cb(nil) end; return
  end

  local newbuf = self:_get_buffer()
  if #self.endpoints > 0 then
    local diff = diff_lines(self.buffer, newbuf, self.endpoints[#self.endpoints])
    if diff ~= nil then
      self.changedtick = newtick
      self.buffer      = newbuf
      self:rewind_to(diff[1], diff[2] + 1, opts, cb)
      return
    end
  end

  self.changedtick = newtick
  self.buffer      = newbuf
  if cb then cb(nil) end
end

-- ============================================================
-- Public Rocq commands
-- ============================================================

--- Start a new Rocq instance.  cb(err_or_nil, stderr_string)
function Session:start(coqproject_args, opts, cb)
  -- Must call find_rocq first to initialize the XML interface.
  local coq_path = opts.coq_path or ""
  local coq_prog = opts.coq_prog or ""
  local info_or_err = self.coqtop:find_rocq(coq_path, coq_prog)
  if type(info_or_err) == "string" then
    -- find_rocq returns a string on error
    cb(false, info_or_err, "")
    return
  end
  -- info_or_err is the version info table
  local info = info_or_err

  self.coqtop:start(opts.filename, coqproject_args, opts, function(err, stderr)
    self:print_stderr(stderr)
    if err then
      cb(false, err, stderr or "")
    else
      cb(true, nil, stderr or "")
    end
  end)
end

function Session:stop()
  self.coqtop:stop()
end

--- Advance by `steps` sentences.  cb(err_or_nil)
function Session:step(steps, opts, cb)
  self:sync(opts, function()
    if steps < 1 then cb(nil); return end

    local line, col = 0, 0
    if #self.endpoints > 0 then
      line, col = self.endpoints[#self.endpoints][1], self.endpoints[#self.endpoints][2]
    end

    local unmatched = nil
    for _ = 1, steps do
      local ok, res = pcall(get_message_range, self.buffer, { line, col })
      if not ok then
        if type(res) == "table" and res.type == "UnmatchedError" then unmatched = res end
        break
      end
      line = res.stop[1]; col = res.stop[2] + 1
      self.send_queue[#self.send_queue + 1] = res
    end

    self:_send_until_fail(self.buffer, opts, false, function(failed_at, err)
      if unmatched ~= nil and failed_at == nil then
        self:_set_info(unmatched.msg, false)
        self.error_at = unmatched.range
        self:_do_refresh(false, true, false)
      end
      cb(err)
    end)
  end)
end

--- Rewind by `steps` sentences.  cb(err_or_nil)
function Session:rewind(steps, opts, cb)
  if steps < 1 or #self.endpoints == 0 then cb(nil); return end

  self.coqtop:rewind(steps, opts, function(ok, msg, extra_steps, stderr)
    self:print_stderr(stderr)
    if not ok or extra_steps == nil then cb(msg); return end

    local total = steps + (extra_steps or 0)
    for _ = 1, total do table.remove(self.endpoints) end

    -- Keep only omitted proofs whose qed is at or before the new endpoint
    local new_ep = self.endpoints[#self.endpoints]
    local new_om = {}
    for _, pr in ipairs(self.omitted_proofs) do
      local qs = pr.qed.stop
      if new_ep and (qs[1] < new_ep[1] or (qs[1] == new_ep[1] and qs[2] <= new_ep[2])) then
        new_om[#new_om + 1] = pr
      end
    end
    self.omitted_proofs = new_om
    self.error_at       = nil

    self:refresh(opts, true, true, false, function() cb(nil) end)
  end)
end

--- Advance/rewind to (line, col) (0-indexed).  cb(err_or_nil)
function Session:to_line(line, col, admit, opts, cb)
  self:sync(opts, function()
    local eline, ecol = 0, 0
    if #self.endpoints > 0 then
      eline, ecol = self.endpoints[#self.endpoints][1], self.endpoints[#self.endpoints][2]
    end

    if line < eline or (line == eline and col < ecol) then
      self:rewind_to(line, col + 2, opts, cb); return
    end

    local unmatched = nil
    while true do
      local ok, res = pcall(get_message_range, self.buffer, { eline, ecol })
      if not ok then
        if type(res) == "table" and res.type == "UnmatchedError" then
          if res.range[1][1] < line or
             (res.range[1][1] == line and res.range[1][2] <= col) then
            unmatched = res
          end
        end
        break
      end
      if line < res.stop[1] or (line == res.stop[1] and col < res.stop[2]) then break end
      eline = res.stop[1]; ecol = res.stop[2] + 1
      self.send_queue[#self.send_queue + 1] = res
    end

    self:_send_until_fail(self.buffer, opts, admit, function(failed_at, err)
      if unmatched ~= nil and failed_at == nil then
        self:_set_info(unmatched.msg, false)
        self.error_at = unmatched.range
        self:_do_refresh(false, true, false)
      end
      cb(err)
    end)
  end)
end

--- Rewind to the beginning.  cb(err_or_nil)
function Session:to_top(opts, cb)
  self:rewind_to(0, 1, opts, cb)
end

--- Run a query and display results.  cb()
function Session:query(args, opts, silent, cb)
  local q = table.concat(args, " ")
  self:_do_query(q, opts, function(ok, msg, _stderr)
    if not ok or not silent then self:_set_info(msg, true) end
    self:print_stderr(_stderr)
    self:_do_refresh(false, true, false)
    if cb then cb() end
  end)
end

--- 1-indexed (line, col) of the current Rocq endpoint.
function Session:endpoint()
  if #self.endpoints > 0 then
    local ep = self.endpoints[#self.endpoints]
    return { ep[1] + 1, ep[2] - 1 + 1 }
  end
  return { 1, 0 }
end

--- 1-indexed (line, col) of the start of the error region, or nil.
function Session:errorpoint()
  if self.error_at ~= nil then
    local s = self.error_at[1]
    return { s[1] + 1, s[2] + 1 }
  end
  return nil
end

-- ============================================================
-- Internal helpers
-- ============================================================

--- Send all sentences in send_queue until an error.  cb(failed_at_or_nil, err_or_nil)
function Session:_send_until_fail(buffer, opts, admit, on_done)
  local empty   = #self.send_queue == 0
  local scroll  = #self.send_queue > 1
  local no_msgs = true
  self.error_at  = nil

  local admit_up_to = nil

  local function finish(failed_at, err)
    if no_msgs and not empty then self:_set_info("", true) end
    self:refresh(opts, true, true, scroll, function() on_done(failed_at, err) end)
  end

  local function send_next()
    if #self.send_queue == 0 then finish(nil, nil); return end

    -- Non-forced intermediate refresh (no goals)
    self:_do_refresh(false, false, scroll)

    local to_send   = table.remove(self.send_queue, 1)
    local message   = between(buffer, to_send.start, to_send.stop)
    local nocom     = strip_comments(message)

    -- Admit mode: skip opaque proofs
    if admit then
      if admit_up_to == nil then
        local ps_kw, ps_full, ps_off = match_proof_start(nocom)
        if ps_kw ~= nil then
          local pend = find_opaque_proof_end(buffer, self.send_queue, 1)
          if pend ~= nil then
            admit_up_to = pend
            local admit_from = shrink_range_to_match(to_send, ps_full, ps_off)
            self.omitted_proofs[#self.omitted_proofs + 1] = {
              proof = admit_from, qed = pend,
            }
          end
        end
      else
        local at_end = to_send.stop[1] == admit_up_to.stop[1] and
                       to_send.stop[2] == admit_up_to.stop[2]
        if at_end then
          message = "Admitted."
          nocom   = message
          admit_up_to = nil
        else
          -- Inside opaque proof: skip
          send_next(); return
        end
      end
    end

    self.coqtop:dispatch(message, nocom, true, opts,
      function(ok, msg, err_loc, stderr)
        if stderr and stderr ~= "" then
          self:print_stderr(stderr); no_msgs = false
        end
        if msg and msg ~= "" then
          self:_set_info(msg, no_msgs); no_msgs = false
        end

        if ok then
          local ln, col = to_send.stop[1], to_send.stop[2]
          self.endpoints[#self.endpoints + 1] = { ln, col + 1 }
          send_next()
        else
          self.send_queue = {}
          local failed_at = to_send.start

          if err_loc ~= nil then
            local ls, le = err_loc[1], err_loc[2]
            if ls == -1 and le == -1 then
              self.error_at = { to_send.start, to_send.stop }
            else
              local sln, sc = to_send.start[1], to_send.start[2]
              local es = pos_from_offset(sc, message, ls)
              local ee = pos_from_offset(sc, message, le)
              self.error_at = {
                { sln + es[1], es[2] },
                { sln + ee[1], ee[2] },
              }
            end
          else
            self.error_at = { to_send.start, to_send.stop }
          end

          finish(failed_at, nil)
        end
      end)
  end

  send_next()
end

--- Rewind to the point where all endpoints are strictly before (line, col).
function Session:rewind_to(line, col, opts, cb)
  local n = 0
  for _, ep in ipairs(self.endpoints) do
    if ep[1] > line or (ep[1] == line and ep[2] >= col) then n = n + 1 end
  end
  self:rewind(n, opts, cb)
end

--- Execute a query and return (ok, msg, stderr) via callback.
function Session:_do_query(query, opts, cb)
  if not query:match("%.$") then query = query .. "." end
  self.coqtop:dispatch(query, nil, false, opts, function(ok, msg, _loc, stderr)
    cb(ok, msg or "", stderr or "")
  end)
end

-- ============================================================
-- Go-to-definition
-- ============================================================

--- Find the FQN of `target` via Locate.  cb(qual_tgt, tgt_type) or cb(nil).
function Session:qual_name(target, opts, cb)
  self:_do_query("Locate " .. target .. ".", opts, function(ok, locate, _)
    if not ok then cb(nil); return end
    locate = locate:gsub("\n +", " ")
    local first = locate:match("([^\n]*)")
    if first:match("No object of basename") then cb(nil); return end

    local alias = first:match("%(alias of (.-)%)")
    if alias then self:qual_name(alias, opts, cb); return end

    local parts = {}
    for w in first:gmatch("%S+") do parts[#parts + 1] = w end

    local tgt_type, qual_tgt
    if parts[1] == "Module" and parts[2] == "Type" then
      tgt_type, qual_tgt = "Module Type", parts[3]
    else
      tgt_type, qual_tgt = parts[1], parts[2]
    end
    cb(qual_tgt, tgt_type)
  end)
end

--- Find the file for library `lib`.  cb(path_no_ext) or cb(nil).
function Session:find_lib(lib, opts, cb)
  self:_do_query("Locate Library " .. lib .. ".", opts, function(ok, locate, _)
    if not ok then cb(nil); return end
    cb(locate:match("file%s+(.-)%.vo"))
  end)
end

--- Find the file containing `qual_tgt`.  cb(filepath, base_name) or cb(nil).
function Session:find_qual(qual_tgt, tgt_type, opts, cb)
  local comps = {}
  for c in qual_tgt:gmatch("[^%.]+") do comps[#comps + 1] = c end
  local base = comps[#comps]

  if comps[1] == "Top" or tgt_type == "Variable" then
    cb(opts.filename, base); return
  end

  local idx = #comps - 1
  local function try()
    if idx <= 0 then cb(nil); return end
    local prefix = {}
    for i = 1, idx do prefix[#prefix + 1] = comps[i] end
    self:find_lib(table.concat(prefix, "."), opts, function(path)
      if path then cb(path .. ".v", base)
      else idx = idx - 1; try()
      end
    end)
  end
  try()
end

--- Find the definition of `target`.  cb(filepath, searches) or cb(nil).
function Session:find_def(target, opts, cb)
  self:qual_name(target, opts, function(qual_tgt, tgt_type)
    if qual_tgt == nil then cb(nil); return end
    self:find_qual(qual_tgt, tgt_type, opts, function(tgt_file, tgt_name)
      if tgt_file == nil then cb(nil); return end
      cb(tgt_file, get_searches(tgt_type, tgt_name))
    end)
  end)
end

-- ============================================================
-- Splash and debug
-- ============================================================

function Session:splash(version, width, _height, opts)
  local ver_str    = "Rocq " .. version
  local center_w   = 15
  local pad        = math.max(0, center_w - #ver_str)
  local lpad       = math.floor(pad / 2)
  local rpad       = pad - lpad
  local ver_line   = "   λ" .. (" "):rep(lpad) .. ver_str .. (" "):rep(rpad) .. "/    "

  local msg = {
    "~~~~~~~~~~~~~~~~~~~~~~~",
    "λ                     /",
    " λ      Coqtail      / ",
    "  λ                 /  ",
    ver_line,
    "    λ             /    ",
    "     λ           /     ",
    "      λ         /      ",
    "       λ       /       ",
    "        λ     /        ",
    "         λ   /         ",
    "          λ /          ",
    "           ‖           ",
    "           ‖           ",
    "           ‖           ",
    "          / λ          ",
    "         /___λ         ",
  }

  local maxw = 0
  for _, l in ipairs(msg) do if #l > maxw then maxw = #l end end
  local hpad = math.max(0, math.floor((width - maxw) / 2))

  local out = {}
  for _, l in ipairs(msg) do
    out[#out + 1] = (" "):rep(hpad) .. l:gsub("%s+$", "")
  end

  self:_set_info(out, false)
  self:_do_refresh(false, true, false)
  _ = opts  -- suppress unused warning
end

function Session:toggle_debug(_opts)
  local log = self.coqtop:toggle_debug()
  if log == nil then
    self:_set_info("Debugging disabled.", true)
    self._log = ""
  else
    self:_set_info("Debugging enabled. Log: " .. log .. ".", true)
    self._log = log
  end
  self:_do_refresh(false, true, false)
end

-- ============================================================
-- Module-level session registry
-- ============================================================

local sessions = {}

function M.get(buf)
  if not sessions[buf] then sessions[buf] = Session.create(buf) end
  return sessions[buf]
end

function M.remove(buf)
  if sessions[buf] then sessions[buf]:stop(); sessions[buf] = nil end
end

function M.exists(buf)
  return sessions[buf] ~= nil
end

M.Session              = Session
M.get_searches         = get_searches
M.lines_and_highlights = lines_and_highlights

return M
