-- Author: Coqtail contributors
-- Minimal XML tree parser for the Rocq XML protocol.
--
-- Returns tree nodes of the form:
--   { tag=string, attrs={k=v,...}, text=string, tail=string, children={...} }
--
--   tag:      element name
--   attrs:    attribute map (string → string)
--   text:     text content before the first child element
--   tail:     text content after this element's closing tag (before the next sibling)
--   children: ordered list of child element nodes
--
-- This mirrors the structure of Python's xml.etree.ElementTree, which the
-- xml_interface module depends on.

local M = {}

-- Standard XML entity unescaping (including numeric character references).
local ENTITIES = {
  ["&lt;"]   = "<",
  ["&gt;"]   = ">",
  ["&amp;"]  = "&",
  ["&quot;"] = '"',
  ["&apos;"] = "'",
  -- Rocq-specific non-standard entities (handled before parsing)
  ["&nbsp;"] = " ",
  ["&#40;"]  = "(",
  ["&#41;"]  = ")",
}

local function unescape(s)
  return (s:gsub("&#?%w+;", function(e)
    if ENTITIES[e] then
      return ENTITIES[e]
    end
    -- Numeric character reference &#NNN;
    local n = e:match("^&#(%d+);$")
    if n then
      return utf8 and utf8.char(tonumber(n)) or string.char(tonumber(n))
    end
    return e
  end))
end

-- Pre-processing step: replace Rocq's non-standard escapes that would choke a
-- standards-compliant parser.  This is equivalent to Python's _unescape().
function M.rocq_unescape(data)
  data = data:gsub("&nbsp;",  " ")
  data = data:gsub("&apos;",  "'")
  data = data:gsub("&#40;",   "(")
  data = data:gsub("&#41;",   ")")
  return data
end

-- ---------------------------------------------------------------------------
-- Attribute parser
-- ---------------------------------------------------------------------------

-- Parse one attribute starting at position pos in string s.
-- Returns name, value, next_pos, or nil on failure.
local function parse_attr(s, pos)
  -- Skip leading whitespace
  local p = s:match("^%s*()", pos)
  if not p or p > #s then return nil end

  -- Attribute name: XML NameChar allows letters, digits, '.', '-', '_', ':'
  local name, after_name = s:match("^([%w_:.-]+)()", p)
  if not name then return nil end

  -- '='
  local eq_pos = s:match("^%s*=()", after_name)
  if not eq_pos then return nil end

  -- Quoted value
  local quote = s:sub(eq_pos, eq_pos)
  local val, after_val
  if quote == '"' then
    val, after_val = s:match('^"([^"]*)"()', eq_pos)
  elseif quote == "'" then
    val, after_val = s:match("^'([^']*)'()", eq_pos)
  end
  if not val then return nil end

  return name, unescape(val), after_val
end

-- ---------------------------------------------------------------------------
-- Core recursive parser
-- ---------------------------------------------------------------------------

-- Parse a single element whose opening '<' has just been consumed.
-- pos points to the first character after '<'.
-- Returns the element node and the position after the element's closing '>'.
local function parse_element(s, pos)
  -- Closing tag </tag>  →  not our job, signal upward
  if s:sub(pos, pos) == "/" then
    local tag, endpos = s:match("^/([%w_:.-]+)%s*>()", pos)
    if tag then
      return { _closing = true, tag = tag }, endpos
    end
    return nil, pos
  end

  -- Processing instruction or DOCTYPE: skip to '>'
  if s:sub(pos, pos) == "?" or s:sub(pos, pos) == "!" then
    local endpos = s:find(">", pos, true)
    return nil, endpos and endpos + 1 or pos + 1
  end

  -- Tag name
  local tag, p = s:match("^([%w_:.-]+)()", pos)
  if not tag then return nil, pos end

  -- Attributes
  local attrs = {}
  while true do
    -- Skip whitespace
    p = s:match("^%s*()", p) or p

    local c = s:sub(p, p)
    if c == ">" then
      p = p + 1
      break
    elseif s:sub(p, p + 1) == "/>" then
      p = p + 2
      return { tag = tag, attrs = attrs, text = "", tail = "", children = {} }, p
    end

    local name, val, next_p = parse_attr(s, p)
    if name then
      attrs[name] = val
      p = next_p
    else
      -- Malformed: skip one character and keep going
      p = p + 1
    end
  end

  -- Children and text
  local node = { tag = tag, attrs = attrs, text = "", tail = "", children = {} }

  while p <= #s do
    local lt = s:find("<", p, true)
    if lt == nil then
      -- Remaining text belongs to node
      local text = unescape(s:sub(p))
      if #node.children == 0 then
        node.text = node.text .. text
      else
        local last = node.children[#node.children]
        last.tail = last.tail .. text
      end
      p = #s + 1
      break
    end

    -- Text between p and lt
    if lt > p then
      local text = unescape(s:sub(p, lt - 1))
      if #node.children == 0 then
        node.text = node.text .. text
      else
        local last = node.children[#node.children]
        last.tail = last.tail .. text
      end
    end

    p = lt + 1  -- skip '<'

    -- Comment <!-- ... -->
    if s:sub(p, p + 2) == "!--" then
      local endpos = s:find("-->", p + 3, true)
      p = endpos and endpos + 3 or p + 3

    -- PI <? ... ?>
    elseif s:sub(p, p) == "?" then
      local endpos = s:find("?>", p + 1, true)
      p = endpos and endpos + 2 or p + 1

    else
      local child, new_p = parse_element(s, p)
      if child then
        if child._closing then
          -- Our own closing tag
          p = new_p
          break
        else
          node.children[#node.children + 1] = child
          p = new_p
        end
      else
        p = p + 1
      end
    end
  end

  return node, p
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Parse an XML string and return the root element node, or nil on failure.
function M.parse(s)
  local p = 1
  while p <= #s do
    local lt = s:find("<", p, true)
    if not lt then return nil end

    local next_char = s:sub(lt + 1, lt + 1)
    -- Skip PIs and comments at the top level
    if next_char ~= "?" and next_char ~= "!" then
      local node, _ = parse_element(s, lt + 1)
      if node and not node._closing then
        return node
      end
    end
    p = lt + 1
  end
  return nil
end

--- Parse a fragment that may contain multiple sibling elements.
-- Wraps them in a virtual <root> and returns that root node.
function M.parse_multi(s)
  return M.parse("<coqtoproot>" .. s .. "</coqtoproot>")
end

--- Collect all text content recursively, like Python's Element.itertext().
-- Returns a list of strings; concatenate them for the full text.
function M.itertext(node)
  local parts = {}
  if node.text ~= "" then
    parts[#parts + 1] = node.text
  end
  for _, child in ipairs(node.children) do
    for _, t in ipairs(M.itertext(child)) do
      parts[#parts + 1] = t
    end
    if child.tail ~= "" then
      parts[#parts + 1] = child.tail
    end
  end
  return parts
end

--- Join all text content of a node into a single string.
function M.text_content(node)
  return table.concat(M.itertext(node))
end

return M
