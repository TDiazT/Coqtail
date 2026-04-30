-- Standalone Lua unit tests for coqtail session parsing functions.
-- Run from the project root: lua tests/unit/test_session.lua

-- Set up package path so that require("coqtail.session") resolves.
package.path = package.path .. ";lua/?.lua;lua/?/init.lua"

-- Stub Neovim-specific globals so session.lua loads outside nvim.
_G.vim = {
  api = {
    nvim_buf_get_lines       = function() return {} end,
    nvim_buf_get_changedtick = function() return 0  end,
  },
  log = { levels = { ERROR = 1, WARN = 2, INFO = 3 } },
  fn  = {},
}
-- Stub coqtail.coqtop — the session module requires it at load time.
package.preload["coqtail.coqtop"] = function()
  return { Coqtop = {} }
end

-- Signal test-export mode before loading.
_G._COQTAIL_TESTING = true

local ok, session = pcall(require, "coqtail.session")
assert(ok, "Failed to load coqtail.session: " .. tostring(session))
local T = session._test
assert(T, "session._test not populated — did _COQTAIL_TESTING fire?")

-- ============================================================
-- Minimal test harness
-- ============================================================

local passed = 0
local failed = 0

local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) == "table" then
    for k, v in pairs(a) do
      if not deep_eq(v, b[k]) then return false end
    end
    for k, v in pairs(b) do
      if not deep_eq(v, a[k]) then return false end
    end
    return true
  end
  return a == b
end

local function check(name, got, expected)
  if deep_eq(got, expected) then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(("FAIL: %s\n  expected: %s\n  got:      %s\n"):format(
      name, tostring(expected), tostring(got)))
  end
end

local function check_error(name, fn, expected_type)
  local ok2, err = pcall(fn)
  if ok2 then
    failed = failed + 1
    io.stderr:write(("FAIL: %s  (expected error, got success)\n"):format(name))
  elseif type(err) == "table" and err.type == expected_type then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(("FAIL: %s  (wrong error: %s)\n"):format(name, tostring(err)))
  end
end

-- ============================================================
-- strip_comments tests
-- ============================================================

-- Helper: return only the cleaned string (discard com_pos).
local function sc(s) return (T.strip_comments(s)) end

check("sc no comment",          sc("abc"),                "abc")
check("sc pre comment",         sc("(*abc*)def"),         "       def")
check("sc mid comment",         sc("ab(* c *)de"),        "ab       de")
check("sc nested comment",      sc("(*(*c*)*)x"),         "         x")
check("sc stray star paren",    sc("abc *)"),             "abc *)")
check("sc str shields comment", sc('"(*)"'),              '"(*)"')
check("sc str shields nested",  sc('"(* (* *) *)"'),      '"(* (* *) *)"')
check("sc str then comment",    sc('"x" (* c *)'),        '"x"        ')
-- """  is: open-", then "" escape, then close-". The (*) inside is shielded.
check("sc str escaped quote",   sc('"""(*)"" x'),         '"""(*)"" x')
check("sc real comment after str with newline",
  sc('"s\nt" (* c *)'), '"s\nt"        ')

-- Verify com_pos is returned correctly for a simple case.
local _, cpos = T.strip_comments("ab(* c *)de")
check("sc com_pos offset", cpos[1][1], 2)   -- 0-indexed offset of '(*'
check("sc com_pos length", cpos[1][2], 7)   -- length of '(* c *)'

-- ============================================================
-- find_dot_after tests
-- ============================================================

-- Helper: call find_dot_after and return {line, col} result.
local function dot(lines, sl, sc_)
  return T.find_dot_after(lines, sl, sc_)
end

check("dot simple",            dot({"A."},                   0, 0), {0, 1})
check("dot word",              dot({"A B."},                 0, 0), {0, 3})
check("dot qualified name",    dot({"A.B."},                 0, 0), {0, 3})
check("dot extra words",       dot({"A. B."},                0, 0), {0, 1})
check("dot comment mid",       dot({"A (* c. *) B."},        0, 0), {0, 12})
check("dot comment pre",       dot({"(* c. *) A."},          0, 0), {0, 10})
check("dot str",               dot({'A "B.".'},              0, 0), {0, 6})
check("dot str with dot",      dot({'Check "hello. world".'}, 0, 0), {0, 20})
check("dot str shields comment", dot({'A "(*foo*)".'},       0, 0), {0, 11})
check("dot multiline",         dot({"A", "B."},              0, 0), {1, 1})
check("dot multiline comment", dot({"A (*", ". *) B."},      0, 0), {1, 6})
check("dot multiline str",     dot({'A "', '." B.'},         0, 0), {1, 4})
check("dot multiline comment 3 lines",
  dot({"(** line1", "line2", "line3. *) X."}, 0, 0), {2, 11})
check("dot dot3",              dot({"A..."},                  0, 0), {0, 3})

check_error("dot no dot",      function() dot({"A"}, 0, 0) end,    "NoDotError")
check_error("dot unclosed str",function() dot({'A " .'}, 0, 0) end, "UnmatchedError")
check_error("dot unclosed com",function() dot({"A (* ."}, 0, 0) end, "UnmatchedError")

-- ============================================================
-- find_next_sentence tests
-- ============================================================

local function ns(lines, sl, sc_)
  return T.find_next_sentence(lines, sl, sc_)
end

check("ns simple",            ns({"A."},              0, 0), {0, 1})
check("ns comment pre",       ns({"(* c. *) A."},     0, 0), {0, 10})
check("ns str",               ns({'A "B.".'},         0, 0), {0, 6})
check("ns str dot",           ns({'Check "a.b".'},    0, 0), {0, 11})

check("ns str shields comment", ns({'A "(*foo*)".'}, 0, 0), {0, 11})

-- ============================================================
-- Summary
-- ============================================================

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed > 0 and 1 or 0)
