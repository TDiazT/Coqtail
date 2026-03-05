-- Author: Coqtail contributors
-- Parse and compare Rocq version strings.

local M = {}

-- Pad list xs with x on the right up to length n.
local function rpad(xs, x, n)
  while #xs < n do
    xs[#xs + 1] = x
  end
  return xs
end

-- Split a version string into a list of 3 numeric component strings.
-- Version format: \d+.\d+((.|pl)\d+|+(alpha|beta|rc)\d+)?
local function parse(version)
  -- Strip pre-release suffix (+alpha1, +beta2, etc.)
  local base = version:match("^(.-)%+") or version
  local parts = {}
  for p in base:gmatch("[^%.pl]+") do
    parts[#parts + 1] = p
  end
  return rpad(parts, "0", 3)
end

--- Check if `version` matches `pattern` (where '*' is a wildcard).
function M.match(version, pattern)
  local vp = parse(version)
  local pp = parse(pattern)
  for i = 1, 3 do
    local v = vp[i] or "0"
    local p = pp[i] or "0"
    if p ~= "*" and p ~= v then
      return false
    end
  end
  return true
end

--- Check if `version` is at least `pattern`.
function M.atleast(version, pattern)
  local vp = parse(version)
  local pp = parse(pattern)
  for i = 1, 3 do
    local v = tonumber(vp[i] or "0") or 0
    local p = tonumber(pp[i] or "0") or 0
    if pp[i] == "*" or p == v then
      -- continue
    elseif v > p then
      return true
    else
      return false
    end
  end
  return true
end

return M
