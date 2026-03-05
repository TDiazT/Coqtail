-- Author: Coqtail contributors
-- Port of python/xmlInterface.py to Lua.
--
-- Provides XML protocol support for the Rocq IDE slave interface
-- (coqidetop -ideslave).  Handles version differences from 8.4 through 9.1+.
--
-- Reference: https://github.com/coq/coq/blob/master/dev/doc/xml-protocol.md

local xml = require("coqtail.xml")

-- Lua 5.1 / LuaJIT compat: table.unpack may not exist.
local unpack = table.unpack or unpack  -- luacheck: ignore 143

local M = {}

-- ============================================================
-- Result types
-- ============================================================

local Ok = {}
Ok.__index = Ok

function Ok.new(val, msg)
  return setmetatable({ val = val, msg = msg or "" }, Ok)
end

function Ok:is_ok() return true end

local Err = {}
Err.__index = Err

function Err.new(msg, loc)
  return setmetatable({ msg = msg, loc = loc or { -1, -1 } }, Err)
end

function Err:is_ok() return false end

M.Ok  = Ok
M.Err = Err

M.TIMEOUT_ERR = Err.new(
  "Rocq timed out. You can change the timeout with <leader>ct and try again."
)

M.STDERR_ERR = Err.new(
  "Coqtail received an unexpected error message on stderr. "
  .. "Please report at https://github.com/whonore/Coqtail/issues.\n\n"
  .. "This can sometimes happen if the message is actually a warning, but is not "
  .. "formatted in a way that Coqtail recognizes. "
  .. "If you wish to ignore this error and try to proceed past it, set "
  .. "g:coqtail_treat_stderr_as_warning = 1."
)

-- ============================================================
-- XML generation helpers
-- ============================================================

local function esc(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  return s
end

local function x_unit()        return "<unit/>" end
local function x_bool(v)       return ('<bool val="%s"/>'):format(v and "true" or "false") end
local function x_int(v)        return ("<int>%d</int>"):format(v) end
local function x_string(v)     return ("<string>%s</string>"):format(esc(v)) end
local function x_state_id(id)  return ('<state_id val="%d"/>'):format(id) end
local function x_route_id(id)  return ('<route_id val="%d"/>'):format(id) end

local function x_list(items)
  return "<list>" .. table.concat(items, "") .. "</list>"
end

local function x_pair(a, b)
  return "<pair>" .. a .. b .. "</pair>"
end

local function x_option_some(v)
  return '<option val="some">' .. v .. '</option>'
end

local function x_option_none()
  return '<option val="none"/>'
end

local function make_call(val, content)
  return ('<call val="%s">%s</call>'):format(val, content or "")
end

-- Serialize a list of strings (e.g. option name split by space).
local function x_string_list(parts)
  local items = {}
  for _, s in ipairs(parts) do
    items[#items + 1] = x_string(s)
  end
  return x_list(items)
end

-- Serialize an option_value element.
-- kind: "bool" | "int" | "str" | "str_opt"
-- val:  the Lua value
local function split_words(s)
  local parts = {}
  for w in s:gmatch("%S+") do parts[#parts + 1] = w end
  return parts
end

local function x_option_value(kind, val)
  if kind == "bool" then
    return ('<option_value val="boolvalue">%s</option_value>'):format(x_bool(val))
  elseif kind == "int" then
    local inner
    if val == nil then
      inner = x_option_none()
    else
      inner = x_option_some(x_int(val))
    end
    return ('<option_value val="intvalue">%s</option_value>'):format(inner)
  elseif kind == "str" then
    return ('<option_value val="stringvalue">%s</option_value>'):format(x_string(val))
  elseif kind == "str_opt" then
    local inner
    if val == nil then
      inner = x_option_none()
    else
      inner = x_option_some(x_string(val))
    end
    return ('<option_value val="stringoptvalue">%s</option_value>'):format(inner)
  end
  error("Unknown option value kind: " .. tostring(kind))
end

-- ============================================================
-- Tagged token / richpp parsing
-- ============================================================
-- Mirrors Python's parse_tagged_tokens / join_tagged_tokens.
-- Returns a list of {text, tag_or_nil} pairs.

local function _parse_tagged_tokens_inner(tags_set, node, stack, inner)
  local result = {}
  local pop_after = nil

  local tag = node.tag
  if tag:sub(1, 6) == "start." then
    local t = tag:sub(7)
    if tags_set[t] then
      table.insert(stack, 1, t)
    end
  elseif tag:sub(1, 4) == "end." then
    local t = tag:sub(5)
    if tags_set[t] then
      pop_after = t
    end
  elseif tags_set[tag] then
    table.insert(stack, 1, tag)
    pop_after = tag
  end

  -- Text before first child
  if node.text ~= "" then
    result[#result + 1] = { node.text, { unpack(stack) } }
  end

  -- Recurse into children
  for _, child in ipairs(node.children) do
    local child_tokens = _parse_tagged_tokens_inner(tags_set, child, stack, true)
    for _, t in ipairs(child_tokens) do
      result[#result + 1] = t
    end
  end

  if pop_after then
    for i, v in ipairs(stack) do
      if v == pop_after then
        table.remove(stack, i)
        break
      end
    end
  end

  -- Tail text (text after this element's closing tag)
  if inner and node.tail ~= "" then
    result[#result + 1] = { node.tail, { unpack(stack) } }
  end

  return result
end

-- Convert a stream of (text, stack) pairs into (text, top_tag_or_nil) pairs,
-- merging adjacent tokens that share the same top tag.
local function parse_tagged_tokens(tags, node)
  local tags_set = {}
  for _, t in ipairs(tags) do
    tags_set[t] = true
  end

  local raw = _parse_tagged_tokens_inner(tags_set, node, {}, false)
  local result = {}
  local acc_text, last_tag = "", nil

  for _, item in ipairs(raw) do
    local text, stack = item[1], item[2]
    local top_tag = stack[1]  -- may be nil

    if top_tag == last_tag then
      acc_text = acc_text .. text
    else
      result[#result + 1] = { acc_text, last_tag }
      acc_text, last_tag = text, top_tag
    end
  end
  result[#result + 1] = { acc_text, last_tag }
  return result
end

local function join_tagged_tokens(tokens)
  local parts = {}
  for _, t in ipairs(tokens) do
    parts[#parts + 1] = t[1]
  end
  return table.concat(parts)
end

M.parse_tagged_tokens  = parse_tagged_tokens
M.join_tagged_tokens   = join_tagged_tokens

-- ============================================================
-- Utility: partition stderr into warnings and errors
-- ============================================================

local WARNING_RE = "Warning:[^\n]*%[.*%]"

function M.partition_warnings(stderr)
  local warns = {}
  local errs  = {}

  -- Split on warning headers, keeping the headers
  local rest = stderr
  while true do
    local ws, we = rest:find("Warning:[^%]]*%]", 1)
    if not ws then
      local trimmed = rest:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        errs[#errs + 1] = trimmed
      end
      break
    end
    -- Text before this warning
    if ws > 1 then
      local before = rest:sub(1, ws - 1):match("^%s*(.-)%s*$")
      if before ~= "" then
        errs[#errs + 1] = before
      end
    end
    warns[#warns + 1] = rest:sub(ws, we)
    rest = rest:sub(we + 1)
  end

  return table.concat(warns, "\n"), table.concat(errs, "\n")
end

-- ============================================================
-- Version utilities
-- ============================================================

--- Parse "8.16.0" or "8.16+beta1" → {8, 16, 0}
function M.parse_version(ver_str)
  local major, minor, patch = ver_str:match("^(%d+)%.(%d+)%.(%d+)")
  if major then
    return { tonumber(major), tonumber(minor), tonumber(patch) }
  end
  major, minor = ver_str:match("^(%d+)%.(%d+)")
  if major then
    return { tonumber(major), tonumber(minor), 0 }
  end
  error("Invalid version string: " .. ver_str)
end

--- Compare two version tables. Returns -1, 0, or 1.
local function vcmp(a, b)
  for i = 1, 3 do
    local ai = a[i] or 0
    local bi = b[i] or 0
    if ai < bi then return -1
    elseif ai > bi then return 1
    end
  end
  return 0
end

--- Return true if version a >= version b.
local function vge(a, b) return vcmp(a, b) >= 0 end
--- Return true if version a < version b.
local function vlt(a, b) return vcmp(a, b) <  0 end

M.vcmp = vcmp
M.vge  = vge
M.vlt  = vlt

-- ============================================================
-- Base XML interface
-- ============================================================

local XMLInterfaceBase = {}
XMLInterfaceBase.__index = XMLInterfaceBase

function XMLInterfaceBase.new(version, str_version, coq_path, coq_prog)
  assert(coq_prog ~= nil, "coq_prog must not be nil")
  local self = setmetatable({}, XMLInterfaceBase)

  self.version      = version      -- {major, minor, patch}
  self.str_version  = str_version  -- e.g. "8.16.0"
  self.coq_path     = coq_path
  self.coq_prog     = coq_prog

  self.launch_args  = { "-ideslave" }
  self.noop         = "Check Prop."
  self.warnings_wf  = false

  -- Valid query commands (first word of a command)
  self.queries = {
    "Search", "SearchAbout", "SearchPattern", "SearchRewrite",
    "Check", "Print", "About", "Locate", "Show",
  }

  -- Dispatch table: XML tag → parser function(self, node) → Lua value
  self._to_py_funcs = {
    unit   = function(_s, _n)  return {}  end,
    bool   = function(_s, n)   return XMLInterfaceBase._to_bool(_s, n)   end,
    int    = function(_s, n)   return XMLInterfaceBase._to_int(_s, n)    end,
    string = function(_s, n)   return XMLInterfaceBase._to_string(_s, n) end,
    list   = function(_s, n)   return XMLInterfaceBase._to_list(_s, n)   end,
    pair   = function(_s, n)   return XMLInterfaceBase._to_pair(_s, n)   end,
    option = function(_s, n)   return XMLInterfaceBase._to_option(_s, n) end,
    union  = function(_s, n)   return XMLInterfaceBase._to_union(_s, n)  end,
  }

  -- Dispatch table: command name → standardize function(self, res) → res
  self._standardize_funcs = {}

  return self
end

-- -- Type parsers -------------------------------------------------------

function XMLInterfaceBase:_to_bool(node)
  local v = node.attrs.val
  if v == "true"  then return true  end
  if v == "false" then return false end
  error("Expected true or false, got: " .. tostring(v))
end

function XMLInterfaceBase:_to_int(node)
  local t = node.text
  assert(t and t ~= "", "Expected integer text content")
  return tonumber(t)
end

function XMLInterfaceBase:_to_string(node)
  return xml.text_content(node)
end

function XMLInterfaceBase:_to_list(node)
  local result = {}
  for _, child in ipairs(node.children) do
    result[#result + 1] = self:_to_py(child)
  end
  return result
end

function XMLInterfaceBase:_to_pair(node)
  return { self:_to_py(node.children[1]), self:_to_py(node.children[2]) }
end

--- Returns nil for "none", or {val = parsed_value} for "some".
function XMLInterfaceBase:_to_option(node)
  local v = node.attrs.val
  if v == "none" then return nil end
  if v == "some" then return { val = self:_to_py(node.children[1]) } end
  error("Expected none or some, got: " .. tostring(v))
end

--- Returns {inl = value} or {inr = value}.
function XMLInterfaceBase:_to_union(node)
  local v = node.attrs.val
  if v == "in_l" then return { inl = self:_to_py(node.children[1]) } end
  if v == "in_r" then return { inr = self:_to_py(node.children[1]) } end
  error("Expected in_l or in_r, got: " .. tostring(v))
end

function XMLInterfaceBase:_to_py(node)
  local fn = self._to_py_funcs[node.tag]
  if fn then return fn(self, node) end
  error("Unknown XML tag: " .. tostring(node.tag))
end

-- -- Response parsing ---------------------------------------------------

function XMLInterfaceBase:_to_response(node)
  local v = node.attrs.val
  if v == "good" then
    return Ok.new(self:_to_py(node.children[1]))
  elseif v == "fail" then
    local loc_s = tonumber(node.attrs.loc_s or "-1") or -1
    local loc_e = tonumber(node.attrs.loc_e or "-1") or -1
    local msg   = xml.text_content(node)
    return Err.new(msg, { loc_s, loc_e })
  end
  error("Expected good or fail, got: " .. tostring(v))
end

--- Quick check: does data contain a complete value response?
function M.worth_parsing(data)
  return data:find("</value>", 1, true) ~= nil
end

--- Parse raw bytes from Rocq into Ok or Err. Returns nil if incomplete.
function XMLInterfaceBase:raw_response(data)
  -- Pre-process Rocq's non-standard entities
  local cleaned = xml.rocq_unescape(data)

  local root = xml.parse_multi(cleaned)
  if not root then return nil end

  local res  = nil
  local msgs = {}

  for _, child in ipairs(root.children) do
    local tag = child.tag
    if tag == "value" then
      res = self:_to_response(child)
    elseif tag == "message" or tag == "feedback" then
      local ok, msg_val = pcall(function() return self:_to_py(child) end)
      if ok then
        local msg
        if type(msg_val) == "table" and msg_val[1] and type(msg_val[1]) == "table" then
          -- tagged tokens list
          msg = join_tagged_tokens(msg_val)
        elseif type(msg_val) == "string" then
          msg = msg_val
        else
          msg = ""
        end
        msg = msg:match("^%s*(.-)%s*$")
        if msg ~= "" then
          msgs[#msgs + 1] = msg
        end
      end
    end
    -- Other tags (e.g. coqtoproot wrapper children) are silently ignored.
  end

  if res == nil then return nil end

  -- Deduplicate: the error text may appear in both <value val="fail"> and
  -- <feedback>.  See:
  -- https://coq.discourse.group/t/avoiding-duplicate-error-messages-with-the-xml-protocol/411
  local res_msg = res.msg:match("^%s*(.-)%s*$")
  local found = false
  for _, m in ipairs(msgs) do
    if m == res_msg then found = true; break end
  end
  if not found and res_msg ~= "" then
    table.insert(msgs, 1, res_msg)
  end
  res.msg = table.concat(msgs, "\n\n")

  return res
end

--- Apply any version-specific post-processing to a response.
function XMLInterfaceBase:standardize(cmd, res)
  local fn = self._standardize_funcs[cmd]
  if fn then return fn(self, res) end
  return res
end

-- -- Abstract command methods (raise error if not overridden) -----------

local function not_implemented(name)
  return function() error(name .. " not implemented for this version") end
end

XMLInterfaceBase.init        = not_implemented("init")
XMLInterfaceBase.add         = not_implemented("add")
XMLInterfaceBase.edit_at     = not_implemented("edit_at")
XMLInterfaceBase.query       = not_implemented("query")
XMLInterfaceBase.goal        = not_implemented("goal")
XMLInterfaceBase.status      = not_implemented("status")
XMLInterfaceBase.get_options = not_implemented("get_options")
XMLInterfaceBase.set_options = not_implemented("set_options")

-- -- Launch command ------------------------------------------------------

--- Return the list of arguments to launch the Rocq IDE process.
function XMLInterfaceBase:launch(filename, extra_args)
  -- Locate the executable
  local candidates = {
    self.coq_prog,
    self.coq_prog .. ".opt",
    "coq-prover." .. self.coq_prog,
    "coq-prover." .. self.coq_prog .. ".opt",
  }

  local coq_bin = nil
  for _, prog in ipairs(candidates) do
    local path = self.coq_path and (self.coq_path .. "/" .. prog) or prog
    -- Use vim.fn.exepath if available (Neovim environment)
    if vim and vim.fn then
      local found = vim.fn.exepath(path)
      if found and found ~= "" then
        coq_bin = found
        break
      end
    else
      -- Fallback: trust the path string directly
      coq_bin = path
      break
    end
  end

  if not coq_bin then
    error(
      ("Could not find %s%s. Perhaps you need to set rocq_path or rocq_prog."):format(
        self.coq_prog,
        self.coq_path and (" in " .. self.coq_path) or " in $PATH"
      )
    )
  end

  local args = { coq_bin }
  for _, a in ipairs(self.launch_args) do
    args[#args + 1] = a
  end
  for _, a in ipairs(self:topfile(filename, extra_args)) do
    args[#args + 1] = a
  end
  for _, a in ipairs(extra_args) do
    args[#args + 1] = a
  end
  return args
end

--- Return extra arguments to set the top-level module name (overridden in 8.10+).
function XMLInterfaceBase:topfile(_filename, _args)
  return {}
end

--- Check if a filename stem is a valid Rocq module name.
function XMLInterfaceBase.valid_module(filename)
  local stem = filename:match("([^/\\%.]+)%.[^%.]*$") or filename
  -- Any word-character sequence not starting with a digit
  return stem:match("^%D%w*$") ~= nil
end

-- -- Option / query helpers ---------------------------------------------

local OPTION_RE  = "^[SU][a-z]+"  -- matches Set / Unset / Test (first word)

function XMLInterfaceBase.is_option(cmd)
  local first = cmd:match("^%S+")
  return first == "Set" or first == "Unset" or first == "Test"
end

function XMLInterfaceBase:is_query(cmd)
  local first = cmd:match("^(%S+)%.?$") or cmd:match("^%S+")
  if not first then return false end
  first = first:gsub("%.$", "")
  for _, q in ipairs(self.queries) do
    if first == q then return true end
  end
  return false
end

--- Parse a Set/Unset/Test command into (vals_or_nil, option_name).
-- vals_or_nil:
--   nil         for Test
--   {val, ...}  for Set  (one value: bool, int, or string)
--   {false, {nil,"int"}, {nil,"str"}}  for Unset
function XMLInterfaceBase.parse_option(cmd)
  -- Strip trailing '.'
  cmd = cmd:gsub("%.$", "")
  local parts = {}
  for w in cmd:gmatch("%S+") do parts[#parts + 1] = w end

  local ty = parts[1]  -- "Set", "Unset", or "Test"

  if ty == "Test" then
    local opt_name = table.concat(parts, " ", 2)
    return nil, opt_name
  elseif ty == "Set" then
    local val
    local last = parts[#parts]

    if last:match("^%d") then
      -- Integer value
      val  = tonumber(last)
      table.remove(parts)
    elseif last:sub(-1) == '"' then
      -- String value (may be multi-word)
      local str_parts = {}
      for i = 2, #parts do
        if parts[i]:sub(1, 1) == '"' then
          -- Start of quoted string; collect from here to end
          for j = i, #parts do
            str_parts[#str_parts + 1] = parts[j]
          end
          -- Remove string parts from opt name
          for _ = i, #parts do table.remove(parts) end
          break
        end
      end
      val = table.concat(str_parts, " "):gsub('^"', ""):gsub('"$', "")
    else
      val = true
    end

    local opt_name = table.concat(parts, " ", 2)
    return { val }, opt_name
  elseif ty == "Unset" then
    local opt_name = table.concat(parts, " ", 2)
    return { false, { nil, "int" }, { nil, "str" } }, opt_name
  end

  error("Expected Set, Unset, or Test, got: " .. tostring(ty))
end

--- Unwrap a Coq option ({val=x} or nil) to x or nil.
function XMLInterfaceBase.unwrap_option(opt)
  if opt == nil then return nil end
  return opt.val
end

-- ============================================================
-- Version 8.4
-- ============================================================
-- NOTE: 8.4 does not inherit from 8.5; it is a separate lineage.

local function make_v84(version, str_version, coq_path, coq_prog)
  local iface = XMLInterfaceBase.new(
    version, str_version, coq_path, coq_prog or "coqtop"
  )

  -- 8.4-specific type parsers
  local function to_goal(n)
    -- <goal>string (list string) string</goal>
    local ch  = n.children
    local id  = iface:_to_py(ch[1])   -- string
    local hyp = iface:_to_py(ch[2])   -- list of strings
    local ccl = iface:_to_py(ch[3])   -- string
    return { id = id, hyp = hyp, ccl = ccl }
  end

  local function to_goals(n)
    local ch = n.children
    return {
      fg = iface:_to_py(ch[1]),
      bg = iface:_to_py(ch[2]),
    }
  end

  local function to_option_value(n)
    local ty = n.attrs.val
    if ty then
      if ty:sub(1, 3) == "int" then ty = "int"
      elseif ty:sub(1, 3) == "str" then ty = "str"
      else ty = "bool"
      end
    end
    return { val = iface:_to_py(n.children[1]), type = ty }
  end

  local function to_option_state(n)
    local ch = n.children
    return {
      sync  = iface:_to_py(ch[1]),
      depr  = iface:_to_py(ch[2]),
      name  = iface:_to_py(ch[3]),
      value = iface:_to_py(ch[4]),
    }
  end

  local function to_status(n)
    local ch = n.children
    return {
      path      = iface:_to_py(ch[1]),
      proofname = iface:_to_py(ch[2]),
      allproofs = iface:_to_py(ch[3]),
      statenum  = iface:_to_py(ch[4]),
      proofnum  = iface:_to_py(ch[5]),
    }
  end

  local function to_message(n)
    return xml.text_content(n.children[2])
  end

  local function to_feedback(n)
    local content = n.children[1]
    if content.attrs.val == "errormsg" then
      return xml.text_content(content.children[2])
    end
    return ""
  end

  iface._to_py_funcs["goal"]         = function(s, n) return to_goal(n) end
  iface._to_py_funcs["goals"]        = function(s, n) return to_goals(n) end
  iface._to_py_funcs["evar"]         = function(s, n) return { info = s:_to_py(n.children[1]) } end
  iface._to_py_funcs["option_value"] = function(s, n) return to_option_value(n) end
  iface._to_py_funcs["option_state"] = function(s, n) return to_option_state(n) end
  iface._to_py_funcs["status"]       = function(s, n) return to_status(n) end
  iface._to_py_funcs["coq_info"]     = function(s, n)
    local ch = n.children
    return {
      coq_version      = s:_to_py(ch[1]),
      protocol_version = s:_to_py(ch[2]),
      release_data     = s:_to_py(ch[3]),
      compile_data     = s:_to_py(ch[4]),
    }
  end
  iface._to_py_funcs["message"]  = function(s, n) return to_message(n) end
  iface._to_py_funcs["feedback"] = function(s, n) return to_feedback(n) end

  -- Standardize helpers
  local function std_init(_s, _res)
    return Ok.new(0)  -- 8.4 has no real state ids
  end

  local function std_add(_s, res)
    if res:is_ok() then
      res.val = { res_msg = res.val, state_id = 0 }
    end
    return res
  end

  local function std_query(_s, res)
    if res:is_ok() then
      res.msg = res.val
    end
    return res
  end

  local function std_goal(_s, res)
    if res:is_ok() then
      local goals_raw = XMLInterfaceBase.unwrap_option(res.val)
      if goals_raw then
        local fg = {}
        for _, g in ipairs(goals_raw.fg) do
          fg[#fg + 1] = { hyp = g.hyp, ccl = g.ccl, name = nil }
        end
        local bg = {}
        for _, pair in ipairs(goals_raw.bg) do
          local row = {}
          local pre, post = pair[1], pair[2]
          for _, g in ipairs(pre)  do row[#row + 1] = { hyp = g.hyp, ccl = g.ccl, name = nil } end
          for _, g in ipairs(post) do row[#row + 1] = { hyp = g.hyp, ccl = g.ccl, name = nil } end
          bg[#bg + 1] = row
        end
        res.val = { fg = fg, bg = bg, shelved = {}, given_up = {} }
      end
    end
    return res
  end

  local function std_get_options(_s, res)
    if res:is_ok() then
      local opts = {}
      for _, item in ipairs(res.val) do
        local name, state = item[1], item[2]
        opts[#opts + 1] = { table.concat(name, " "), state.name, state.value.val }
      end
      res.val = opts
    end
    return res
  end

  iface._standardize_funcs["Init"]       = std_init
  iface._standardize_funcs["Add"]        = std_add
  iface._standardize_funcs["Query"]      = std_query
  iface._standardize_funcs["Goal"]       = std_goal
  iface._standardize_funcs["GetOptions"] = std_get_options

  -- Commands

  function iface:init()
    -- No Init call in 8.4; return a dummy command that will be standardized.
    return "Init", nil
  end

  -- 8.4 uses <call val="interp" id="N" verbose="true"> with text body
  function iface:add(cmd, state)
    local xml_str = ('<call val="interp" id="%d" verbose="true">%s</call>'):format(
      state, esc(cmd)
    )
    return "Add", xml_str
  end

  function iface:edit_at(_state, steps)
    local xml_str = ('<call val="rewind" steps="%d"></call>'):format(steps)
    return "Edit_at", xml_str
  end

  function iface:query(q, state)
    local xml_str = ('<call val="interp" raw="true" verbose="true" id="%d">%s</call>'):format(
      state, esc(q)
    )
    return "Query", xml_str
  end

  function iface:goal()
    return "Goal", make_call("goal", x_unit())
  end

  function iface:status()
    return "Status", make_call("status", x_unit())
  end

  function iface:get_options()
    return "GetOptions", make_call("getoptions", x_unit())
  end

  function iface:set_options(option, val)
    -- Determine option value XML
    local optval_xml
    if type(val) == "number" then
      -- int option
      optval_xml = ('<option_value val="intvalue">%s</option_value>'):format(
        x_option_some(x_int(val))
      )
    elseif type(val) == "table" and val[1] == nil then
      -- {nil, "int"} or {nil, "str"} → unset
      if val[2] == "int" then
        optval_xml = '<option_value val="intvalue"><option val="none"/></option_value>'
      else
        optval_xml = '<option_value val="stringvalue"><option val="none"/></option_value>'
      end
    elseif type(val) == "string" then
      optval_xml = ('<option_value val="stringvalue">%s</option_value>'):format(x_string(val))
    elseif type(val) == "boolean" then
      optval_xml = ('<option_value val="boolvalue">%s</option_value>'):format(x_bool(val))
    else
      optval_xml = '<option_value val="boolvalue"><bool val="true"/></option_value>'
    end

    -- 8.4: single element (not a list)
    local content = x_pair(x_string_list(split_words(option)), optval_xml)
    return "SetOptions", make_call("setoptions", content)
  end

  return iface
end

-- ============================================================
-- Version 8.5
-- ============================================================
-- NOTE: 8.5 is a fresh lineage (does NOT inherit from 8.4).

local function make_v85(version, str_version, coq_path, coq_prog)
  local iface = XMLInterfaceBase.new(
    version, str_version, coq_path, coq_prog or "coqtop"
  )

  -- Additional launch args
  iface.launch_args = { "-ideslave", "-main-channel", "stdfds", "-async-proofs", "on" }

  iface.queries[#iface.queries + 1] = "SearchHead"

  -- Type parsers

  local function to_state_id(n)
    return { id = tonumber(n.attrs.val) }
  end

  local function to_goal(n)
    local ch  = n.children
    local id  = iface:_to_py(ch[1])
    local hyp = iface:_to_py(ch[2])
    local ccl = iface:_to_py(ch[3])
    return { id = id, hyp = hyp, ccl = ccl }
  end

  local function to_goals(n)
    local ch = n.children
    return {
      fg       = iface:_to_py(ch[1]),
      bg       = iface:_to_py(ch[2]),
      shelved  = iface:_to_py(ch[3]),
      given_up = iface:_to_py(ch[4]),
    }
  end

  local function to_option_value(n)
    local ty = n.attrs.val
    if ty then
      if ty:sub(1, 3) == "int" then ty = "int"
      elseif ty:sub(1, 3) == "str" then ty = "str"
      else ty = "bool"
      end
    end
    return { val = iface:_to_py(n.children[1]), type = ty }
  end

  local function to_option_state(n)
    local ch = n.children
    return {
      sync  = iface:_to_py(ch[1]),
      depr  = iface:_to_py(ch[2]),
      name  = iface:_to_py(ch[3]),
      value = iface:_to_py(ch[4]),
    }
  end

  local function to_message(n)
    -- <message>message_level string</message> — xml[1] is level, xml[2] is string
    return xml.text_content(n.children[2])
  end

  local function to_feedback(n)
    local content = n.children[1]
    if content.attrs.val == "errormsg" then
      return xml.text_content(content.children[2])
    end
    return ""
  end

  iface._to_py_funcs["state_id"]     = function(s, n) return to_state_id(n) end
  iface._to_py_funcs["goal"]         = function(s, n) return to_goal(n) end
  iface._to_py_funcs["goals"]        = function(s, n) return to_goals(n) end
  iface._to_py_funcs["evar"]         = function(s, n) return { info = s:_to_py(n.children[1]) } end
  iface._to_py_funcs["option_value"] = function(s, n) return to_option_value(n) end
  iface._to_py_funcs["option_state"] = function(s, n) return to_option_state(n) end
  iface._to_py_funcs["status"]       = function(s, n)
    local ch = n.children
    return {
      path      = s:_to_py(ch[1]),
      proofname = s:_to_py(ch[2]),
      allproofs = s:_to_py(ch[3]),
      proofnum  = s:_to_py(ch[4]),
    }
  end
  iface._to_py_funcs["coq_info"] = function(s, n)
    local ch = n.children
    return {
      coq_version      = s:_to_py(ch[1]),
      protocol_version = s:_to_py(ch[2]),
      release_data     = s:_to_py(ch[3]),
      compile_data     = s:_to_py(ch[4]),
    }
  end
  iface._to_py_funcs["message"]  = function(s, n) return to_message(n) end
  iface._to_py_funcs["feedback"] = function(s, n) return to_feedback(n) end

  -- Standardize helpers

  local function std_init(_s, res)
    if res:is_ok() then
      res.val = res.val.id  -- CoqStateId → int
    end
    return res
  end

  local function std_add(_s, res)
    if res:is_ok() then
      -- val is ((CoqStateId, (any, string)), ...)
      -- val[1] = CoqStateId of new state
      -- val[2][2] = res_msg string (pair snd)
      local v = res.val
      res.val = { res_msg = v[2][2], state_id = v[1].id }
    end
    return res
  end

  local function std_edit_at(_s, res)
    if res:is_ok() then res.val = 0 end
    return res
  end

  local function std_goal(_s, res)
    if res:is_ok() then
      local goals_raw = XMLInterfaceBase.unwrap_option(res.val)
      if goals_raw then
        local function convert(g)
          return { hyp = g.hyp, ccl = g.ccl, name = nil }
        end
        local fg = {}
        for _, g in ipairs(goals_raw.fg) do fg[#fg + 1] = convert(g) end
        local bg = {}
        for _, pair in ipairs(goals_raw.bg) do
          local row = {}
          local pre, post = pair[1], pair[2]
          for _, g in ipairs(pre)  do row[#row + 1] = convert(g) end
          for _, g in ipairs(post) do row[#row + 1] = convert(g) end
          bg[#bg + 1] = row
        end
        local shelved  = {}
        for _, g in ipairs(goals_raw.shelved)  do shelved[#shelved + 1]  = convert(g) end
        local given_up = {}
        for _, g in ipairs(goals_raw.given_up) do given_up[#given_up + 1] = convert(g) end
        res.val = { fg = fg, bg = bg, shelved = shelved, given_up = given_up }
      end
    end
    return res
  end

  local function std_get_options(_s, res)
    if res:is_ok() then
      local opts = {}
      for _, item in ipairs(res.val) do
        local name, state = item[1], item[2]
        opts[#opts + 1] = { table.concat(name, " "), state.name, state.value.val }
      end
      res.val = opts
    end
    return res
  end

  iface._standardize_funcs["Init"]       = std_init
  iface._standardize_funcs["Add"]        = std_add
  iface._standardize_funcs["Edit_at"]    = std_edit_at
  iface._standardize_funcs["Goal"]       = std_goal
  iface._standardize_funcs["GetOptions"] = std_get_options

  -- Commands

  function iface:init()
    return "Init", make_call("Init", x_option_none())
  end

  function iface:add(cmd, state)
    -- <call val="Add"><pair><pair><string>cmd</string><int>-1</int></pair>
    --   <pair><state_id val="N"/><bool val="true"/></pair></pair></call>
    local inner = x_pair(
      x_pair(x_string(cmd), x_int(-1)),
      x_pair(x_state_id(state), x_bool(true))
    )
    return "Add", make_call("Add", inner)
  end

  function iface:edit_at(state, _steps)
    return "Edit_at", make_call("Edit_at", x_state_id(state))
  end

  function iface:query(q, state)
    local inner = x_pair(x_string(q), x_state_id(state))
    return "Query", make_call("Query", inner)
  end

  function iface:goal()
    return "Goal", make_call("Goal", x_unit())
  end

  function iface:status()
    return "Status", make_call("Status", x_bool(true))
  end

  function iface:get_options()
    return "GetOptions", make_call("GetOptions", x_unit())
  end

  function iface:set_options(option, val)
    -- Determine kind and build option_value XML
    local optval_xml
    if type(val) == "number" then
      optval_xml = x_option_value("int", val)
    elseif type(val) == "table" then
      -- {nil, "int"} or {nil, "str"} from Unset
      if val[2] == "int" then
        optval_xml = x_option_value("int", nil)
      elseif val[2] == "str" then
        optval_xml = x_option_value("str_opt", nil)
      else
        optval_xml = x_option_value("bool", false)
      end
    elseif type(val) == "string" then
      optval_xml = x_option_value("str", val)
    elseif type(val) == "boolean" then
      optval_xml = x_option_value("bool", val)
    else
      optval_xml = x_option_value("bool", true)
    end

    local name_list  = x_string_list(split_words(option))
    local pair_xml   = x_pair(name_list, optval_xml)
    local inner_list = x_list({ pair_xml })
    local outer_list = x_list({ inner_list })
    return "SetOptions", make_call("SetOptions", outer_list)
  end

  return iface
end

-- ============================================================
-- Version 8.6  (adds richpp, warning format, extra launch args)
-- ============================================================

local RICHPP_TAGS_86 = {
  "diff.added", "diff.removed", "diff.added.bg", "diff.removed.bg",
}

local function make_v86(version, str_version, coq_path, coq_prog)
  local iface = make_v85(version, str_version, coq_path, coq_prog)

  -- Extra launch args for async proof error resilience
  local extra = {
    "-async-proofs-command-error-resilience", "off",
    "-async-proofs-tactic-error-resilience",  "off",
  }
  for _, a in ipairs(extra) do
    iface.launch_args[#iface.launch_args + 1] = a
  end

  iface.warnings_wf = true

  -- richpp parser
  iface._to_py_funcs["richpp"] = function(_s, n)
    return parse_tagged_tokens(RICHPP_TAGS_86, n)
  end

  -- 8.6 message: <message>message_level (option ?) richpp</message>
  iface._to_py_funcs["message"] = function(s, n)
    -- n.children[3] is a richpp
    local rich = s:_to_py(n.children[3])
    return join_tagged_tokens(rich)
  end

  -- 8.6 feedback: <feedback object="?" route="int">state_id feedback_content</feedback>
  --   feedback_content val="message" → message (first child is the message)
  iface._to_py_funcs["feedback"] = function(s, n)
    local content = n.children[2]  -- second child (first is state_id)
    if content.attrs.val == "message" then
      local msg = s:_to_py(content.children[1])
      if type(msg) == "table" then
        return join_tagged_tokens(msg)
      end
      return tostring(msg)
    end
    return ""
  end

  return iface
end

-- ============================================================
-- Version 8.7  (adds route_id to Query)
-- ============================================================

local function make_v87(version, str_version, coq_path, coq_prog)
  local iface = make_v86(version, str_version, coq_path, coq_prog)

  iface._to_py_funcs["route_id"] = function(_s, n)
    return { id = tonumber(n.attrs.val) }
  end

  -- Override query: adds route_id as first arg
  function iface:query(q, state)
    local inner = x_pair(
      x_route_id(0),
      x_pair(x_string(q), x_state_id(state))
    )
    return "Query", make_call("Query", inner)
  end

  return iface
end

-- ============================================================
-- Versions 8.8  (no changes)
-- ============================================================

local function make_v88(version, str_version, coq_path, coq_prog)
  return make_v87(version, str_version, coq_path, coq_prog)
end

-- ============================================================
-- Version 8.9  (coqidetop binary, no -ideslave)
-- ============================================================

local function make_v89(version, str_version, coq_path, coq_prog)
  local iface = make_v88(version, str_version, coq_path, coq_prog)

  -- 8.9 split coqtop -ideslave into a separate coqidetop binary
  if coq_prog == nil then
    iface.coq_prog = "coqidetop"
  end

  -- Remove -ideslave from launch args
  local new_args = {}
  for _, a in ipairs(iface.launch_args) do
    if a ~= "-ideslave" then new_args[#new_args + 1] = a end
  end
  iface.launch_args = new_args

  -- 8.9 includes extra text in stderr so warnings aren't cleanly parseable
  iface.warnings_wf = false

  return iface
end

-- ============================================================
-- Version 8.10  (warnings parseable again, adds -topfile)
-- ============================================================

local function make_v810(version, str_version, coq_path, coq_prog)
  local iface = make_v89(version, str_version, coq_path, coq_prog)

  iface.warnings_wf = true

  function iface:topfile(filename, args)
    -- Only add -topfile if -top or -topfile not already in args, and the file
    -- name is a valid module identifier.
    for _, a in ipairs(args) do
      if a == "-top" or a == "-topfile" then return {} end
    end
    if not XMLInterfaceBase.valid_module(filename) then return {} end
    return { "-topfile", filename }
  end

  return iface
end

-- ============================================================
-- Version 8.11  (no changes)
-- ============================================================

local function make_v811(version, str_version, coq_path, coq_prog)
  return make_v810(version, str_version, coq_path, coq_prog)
end

-- ============================================================
-- Version 8.12  (CoqOptionState loses 'name' field)
-- ============================================================

local function make_v812(version, str_version, coq_path, coq_prog)
  local iface = make_v811(version, str_version, coq_path, coq_prog)

  -- 8.12: option_state has only (bool bool option_value) — no 'name'
  iface._to_py_funcs["option_state"] = function(s, n)
    local ch = n.children
    return {
      sync  = s:_to_py(ch[1]),
      depr  = s:_to_py(ch[2]),
      value = s:_to_py(ch[3]),
    }
  end

  -- Updated standardize: option 'name' was removed, use key as name
  iface._standardize_funcs["GetOptions"] = function(_s, res)
    if res:is_ok() then
      local opts = {}
      for _, item in ipairs(res.val) do
        local name, state = item[1], item[2]
        local name_str = table.concat(name, " ")
        opts[#opts + 1] = { name_str, name_str, state.value.val }
      end
      res.val = opts
    end
    return res
  end

  return iface
end

-- ============================================================
-- Version 8.13  (no changes)
-- ============================================================

local function make_v813(version, str_version, coq_path, coq_prog)
  return make_v812(version, str_version, coq_path, coq_prog)
end

-- ============================================================
-- Version 8.14  (CoqGoal gains optional name field)
-- ============================================================

local function make_v814(version, str_version, coq_path, coq_prog)
  local iface = make_v813(version, str_version, coq_path, coq_prog)

  local function to_goal(s, n)
    -- <goal>string (list Pp) Pp (option string)</goal>
    local ch = n.children
    return {
      id   = s:_to_py(ch[1]),
      hyp  = s:_to_py(ch[2]),
      ccl  = s:_to_py(ch[3]),
      name = s:_to_py(ch[4]),  -- option string
    }
  end

  iface._to_py_funcs["goal"] = function(s, n) return to_goal(s, n) end

  iface._to_py_funcs["goals"] = function(s, n)
    local ch = n.children
    return {
      fg       = s:_to_py(ch[1]),
      bg       = s:_to_py(ch[2]),
      shelved  = s:_to_py(ch[3]),
      given_up = s:_to_py(ch[4]),
    }
  end

  iface._standardize_funcs["Goal"] = function(_s, res)
    if res:is_ok() then
      local goals_raw = XMLInterfaceBase.unwrap_option(res.val)
      if goals_raw then
        local function convert(g)
          return {
            hyp  = g.hyp,
            ccl  = g.ccl,
            name = XMLInterfaceBase.unwrap_option(g.name),
          }
        end
        local fg = {}
        for _, g in ipairs(goals_raw.fg) do fg[#fg + 1] = convert(g) end
        local bg = {}
        for _, pair in ipairs(goals_raw.bg) do
          local row = {}
          for _, g in ipairs(pair[1]) do row[#row + 1] = convert(g) end
          for _, g in ipairs(pair[2]) do row[#row + 1] = convert(g) end
          bg[#bg + 1] = row
        end
        local shelved  = {}
        for _, g in ipairs(goals_raw.shelved)  do shelved[#shelved + 1]  = convert(g) end
        local given_up = {}
        for _, g in ipairs(goals_raw.given_up) do given_up[#given_up + 1] = convert(g) end
        res.val = { fg = fg, bg = bg, shelved = shelved, given_up = given_up }
      end
    end
    return res
  end

  return iface
end

-- ============================================================
-- Version 8.15  (Add command changed — new position fields)
-- ============================================================

local function make_v815(version, str_version, coq_path, coq_prog)
  local iface = make_v814(version, str_version, coq_path, coq_prog)

  -- 8.15: Add takes an extra pair of position args
  -- <call val="Add"><pair><pair><pair><pair>
  --   <string>cmd</string><int>-1</int></pair>
  --   <pair><state_id val="N"/><bool val="true"/></pair></pair>
  --   <int>0</int></pair><pair><int>0</int><int>0</int></pair></call>
  function iface:add(cmd, state)
    local inner_cmd = x_pair(
      x_pair(
        x_pair(x_string(cmd), x_int(-1)),
        x_pair(x_state_id(state), x_bool(true))
      ),
      x_int(0)
    )
    local outer = x_pair(inner_cmd, x_pair(x_int(0), x_int(0)))
    return "Add", make_call("Add", outer)
  end

  iface._standardize_funcs["Add"] = function(_s, res)
    if res:is_ok() then
      -- val[1] = CoqStateId, rest ignored
      local v = res.val
      res.val = { res_msg = "", state_id = v[1].id }
    end
    return res
  end

  return iface
end

-- ============================================================
-- Version 8.16  (adds Subgoals command)
-- ============================================================

local function make_v816(version, str_version, coq_path, coq_prog)
  local iface = make_v815(version, str_version, coq_path, coq_prog)

  iface._standardize_funcs["Subgoals"] = iface._standardize_funcs["Goal"]

  -- CoqGoalFlags serializer
  local function x_goal_flags(mode, fg, bg, shelved, given_up)
    return ("<goal_flags>%s%s%s%s%s</goal_flags>"):format(
      x_string(mode),
      x_bool(fg),
      x_bool(bg),
      x_bool(shelved),
      x_bool(given_up)
    )
  end

  function iface:subgoal(mode, fg, bg, shelved, given_up)
    local flags = x_goal_flags(mode, fg, bg, shelved, given_up)
    return "Subgoals", make_call("Subgoals", flags)
  end

  return iface
end

-- ============================================================
-- Versions 8.17, 8.18, 8.19  (no changes)
-- ============================================================

local function make_v817(version, str_version, coq_path, coq_prog)
  return make_v816(version, str_version, coq_path, coq_prog)
end

local function make_v818(version, str_version, coq_path, coq_prog)
  return make_v817(version, str_version, coq_path, coq_prog)
end

local function make_v819(version, str_version, coq_path, coq_prog)
  return make_v818(version, str_version, coq_path, coq_prog)
end

-- ============================================================
-- Version 8.20  (richer fail response with loc element)
-- ============================================================

local function make_v820(version, str_version, coq_path, coq_prog)
  local iface = make_v819(version, str_version, coq_path, coq_prog)

  -- 8.20: <value val="fail">state_id (option loc) msg_text</value>
  -- where loc is <loc start="N" stop="M" line_nb="L" bol_pos="B"
  --                   line_nb_last="LL" bol_pos_last="BL"/>
  iface._to_py_funcs["loc"] = function(_s, n)
    return {
      start        = tonumber(n.attrs.start),
      stop         = tonumber(n.attrs.stop),
      line_nb      = tonumber(n.attrs.line_nb),
      bol_pos      = tonumber(n.attrs.bol_pos),
      line_nb_last = tonumber(n.attrs.line_nb_last),
      bol_pos_last = tonumber(n.attrs.bol_pos_last),
    }
  end

  function iface:_to_response(node)
    local v = node.attrs.val
    if v == "good" then
      return Ok.new(self:_to_py(node.children[1]))
    elseif v == "fail" then
      -- children: [state_id, option(loc), ...]
      local loc_opt = self:_to_py(node.children[2])
      local loc_s, loc_e
      if loc_opt ~= nil then
        loc_s = loc_opt.val.start
        loc_e = loc_opt.val.stop
      else
        loc_s, loc_e = -1, -1
      end
      local msg = xml.text_content(node)
      return Err.new(msg, { loc_s, loc_e })
    end
    error("Expected good or fail, got: " .. tostring(v))
  end

  return iface
end

-- ============================================================
-- Version 9.0  (adds more queries)
-- ============================================================

local function make_v90(version, str_version, coq_path, coq_prog)
  local iface = make_v820(version, str_version, coq_path, coq_prog)

  iface.queries[#iface.queries + 1] = "Guarded"
  iface.queries[#iface.queries + 1] = "Validate Proof"

  return iface
end

-- ============================================================
-- Version 9.1  (no changes)
-- ============================================================

local function make_v91(version, str_version, coq_path, coq_prog)
  return make_v90(version, str_version, coq_path, coq_prog)
end

-- ============================================================
-- Version dispatch table
-- ============================================================
-- Each entry: { min_version, max_version_exclusive, factory }
-- Versions are {major, minor, patch} tables.

local XML_INTERFACES = {
  { { 8,  4, 0 }, { 8,  5, 0 }, make_v84  },
  { { 8,  5, 0 }, { 8,  6, 0 }, make_v85  },
  { { 8,  6, 0 }, { 8,  7, 0 }, make_v86  },
  { { 8,  7, 0 }, { 8,  8, 0 }, make_v87  },
  { { 8,  8, 0 }, { 8,  9, 0 }, make_v88  },
  { { 8,  9, 0 }, { 8, 10, 0 }, make_v89  },
  { { 8, 10, 0 }, { 8, 11, 0 }, make_v810 },
  { { 8, 11, 0 }, { 8, 12, 0 }, make_v811 },
  { { 8, 12, 0 }, { 8, 13, 0 }, make_v812 },
  { { 8, 13, 0 }, { 8, 14, 0 }, make_v813 },
  { { 8, 14, 0 }, { 8, 15, 0 }, make_v814 },
  { { 8, 15, 0 }, { 8, 16, 0 }, make_v815 },
  { { 8, 16, 0 }, { 8, 17, 0 }, make_v816 },
  { { 8, 17, 0 }, { 8, 18, 0 }, make_v817 },
  { { 8, 18, 0 }, { 8, 19, 0 }, make_v818 },
  { { 8, 19, 0 }, { 8, 20, 0 }, make_v819 },
  { { 8, 20, 0 }, { 8, 21, 0 }, make_v820 },
  { { 9,  0, 0 }, { 9,  1, 0 }, make_v90  },
  { { 9,  1, 0 }, { 9,  2, 0 }, make_v91  },
}

local LATEST_FACTORY = XML_INTERFACES[#XML_INTERFACES][3]
M.XML_INTERFACES     = XML_INTERFACES

--- Create the appropriate interface for the given version.
-- Returns iface, latest_version_hint_or_nil
function M.make_interface(version, str_version, coq_path, coq_prog)
  for _, entry in ipairs(XML_INTERFACES) do
    local lo, hi, factory = entry[1], entry[2], entry[3]
    if vge(version, lo) and vlt(version, hi) then
      return factory(version, str_version, coq_path, coq_prog), nil
    end
  end
  -- Version is newer than we know about — use the latest and warn
  local latest_lo = XML_INTERFACES[#XML_INTERFACES][1]
  local latest_hint = ("%d.%d"):format(latest_lo[1], latest_lo[2])
  return LATEST_FACTORY(version, str_version, coq_path, coq_prog), latest_hint
end

-- ============================================================
-- Executable discovery
-- ============================================================

--- Find the Rocq compiler/prover binary.
-- Returns path (string) or raises an error.
-- coq_path: directory to search (or nil for $PATH)
-- coq_prog: binary name hint (or nil to try "rocq" and "coqc")
function M.find_rocq(coq_path, coq_prog)
  local candidates
  if coq_prog and coq_prog ~= "" then
    candidates = { coq_prog }
  else
    candidates = { "rocq", "coqc" }
  end
  if coq_path == "" then coq_path = nil end

  for _, prog in ipairs(candidates) do
    local found
    if vim and vim.fn then
      local path = coq_path and (coq_path .. "/" .. prog) or prog
      found = vim.fn.exepath(path)
      if found == "" then found = nil end
    end
    if found then return found end
  end

  local path_desc = coq_path and coq_path or "$PATH"
  error(
    ("Could not find %s in %s. Perhaps you need to set rocq_path or rocq_prog."):format(
      table.concat(candidates, " or "), path_desc
    )
  )
end

--- Run `prog --version` and return the version string.
function M.extract_version(prog)
  local result = vim.system({ prog, "--version" }, { text = true }):wait()
  if result.code ~= 0 then
    error(("Executing '%s --version' failed."):format(prog))
  end
  local match = result.stdout:match("version (%S+)")
  if not match then
    error(("Failed to parse '%s --version' output."):format(prog))
  end
  return match
end

--- High-level factory: find Rocq, detect version, return interface.
-- Returns iface, version_info_table
-- version_info_table: { version={M,m,p}, str_version=string, latest=string_or_nil }
function M.XMLInterface(coq_path, coq_prog)
  local rocq = M.find_rocq(coq_path, coq_prog)
  local rocq_dir  = rocq:match("^(.*)/[^/]+$") or "."
  -- Only pass coq_prog to make_interface when the user explicitly set it.
  -- When nil, version-specific constructors (e.g. make_v89) will substitute
  -- the correct IDE binary name (e.g. "coqidetop").
  local user_prog = (coq_prog and coq_prog ~= "") and coq_prog or nil
  local str_ver  = M.extract_version(rocq)
  local version  = M.parse_version(str_ver)

  local iface, latest = M.make_interface(version, str_ver, rocq_dir, user_prog)
  local info = {
    version     = version,
    str_version = str_ver,
    latest      = latest,
  }
  return iface, info
end

return M
