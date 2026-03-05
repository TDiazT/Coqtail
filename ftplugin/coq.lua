-- Author: Coqtail contributors
-- Neovim ftplugin for Rocq (.v) files.

-- Guard: only source once per buffer.
if vim.b.did_ftplugin_coqtail_lua then return end
vim.b.did_ftplugin_coqtail_lua = true

local search = require("coqtail.search")

-- Register Coqtail commands and mappings for this buffer.
require("coqtail").register()

-- ---------------------------------------------------------------------------
-- Comments
-- ---------------------------------------------------------------------------
vim.opt_local.commentstring = "(*%s*)"
vim.opt_local.comments      = "srn:(*,mb:*,ex:*)"
-- Remove t/r/o flags; add c/q/l.
vim.opt_local.formatoptions:remove({ "t", "r", "o" })
vim.opt_local.formatoptions:append("cql")

-- ---------------------------------------------------------------------------
-- Follow imports
-- ---------------------------------------------------------------------------
vim.opt_local.includeexpr  = "v:lua.require('coqtail').findlib(v:fname)"
vim.opt_local.suffixesadd  = ".v"
vim.opt_local.include      = [[\<Require\>\(\_s*\(Import\|Export\)\>\)\?]]

-- ---------------------------------------------------------------------------
-- Tag function
-- ---------------------------------------------------------------------------
if vim.fn.exists("+tagfunc") ~= 0
    and (vim.g.coqtail_tagfunc == nil or vim.g.coqtail_tagfunc ~= 0) then
  vim.opt_local.tagfunc = "v:lua.require('coqtail').gettags"
end

-- ---------------------------------------------------------------------------
-- Navigation mappings ([[, ]], [], ][)
-- ---------------------------------------------------------------------------
if not (vim.g.coqtail_nomap) then
  local bmap = function(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = true, silent = true })
  end

  bmap({ "n" }, "[[", function()
    search.command("Wb", vim.v.count1, false)
  end)
  bmap({ "x" }, "[[", function()
    search.command("Wb", vim.v.count1, true)
  end)
  bmap({ "n" }, "]]", function()
    search.command("W",  vim.v.count1, false)
  end)
  bmap({ "x" }, "]]", function()
    search.command("W",  vim.v.count1, true)
  end)
  bmap({ "n" }, "[]", function()
    search.proof("Wb", vim.v.count1, false)
  end)
  bmap({ "x" }, "[]", function()
    search.proof("Wb", vim.v.count1, true)
  end)
  bmap({ "n" }, "][", function()
    search.proof("W",  vim.v.count1, false)
  end)
  bmap({ "x" }, "][", function()
    search.proof("W",  vim.v.count1, true)
  end)
end

-- ---------------------------------------------------------------------------
-- Proof text object
-- ---------------------------------------------------------------------------
vim.keymap.set({ "o", "x" }, "<Plug>(proof-text-object-inner)",
  function() search.select_i() end,
  { buffer = true, silent = true })
vim.keymap.set({ "o", "x" }, "<Plug>(proof-text-object-outer)",
  function() search.select_a() end,
  { buffer = true, silent = true })

if not (vim.g.coqtail_nomap) then
  vim.keymap.set({ "o", "x" }, "iP", "<Plug>(proof-text-object-inner)",
    { buffer = true, silent = true })
  vim.keymap.set({ "o", "x" }, "aP", "<Plug>(proof-text-object-outer)",
    { buffer = true, silent = true })
end

-- ---------------------------------------------------------------------------
-- matchit / matchup patterns
-- ---------------------------------------------------------------------------
if (vim.g.loaded_matchit or vim.g.loaded_matchup) and not vim.b.match_words then
  vim.b.match_ignorecase = false
  local proof_starts = {
    "Proof",
    [[Next\_s\+Obligation]],
    [[Final\_s\+Obligation]],
    [[Obligation\_s\+\d\+]],
  }
  local proof_ends = { "Qed", "Defined", "Admitted", "Abort", "Save" }

  local function word_alts(tbl)
    local parts = {}
    for _, w in ipairs(tbl) do
      parts[#parts + 1] = [[\<]] .. w .. [[\>]]
    end
    return [[\%(]] .. table.concat(parts, [[\|]]) .. [[\)]]
  end

  local proof_start = word_alts(proof_starts)
  local proof_end   = word_alts(proof_ends)
  vim.b.match_words = table.concat({
    [[\<if\>:\<then\>:\<else\>]],
    [[\<let\>:\<in\>]],
    [[\<\%(lazy\|multi\)\?match\>:\<with\>:\<end\>]],
    [[\%(\<Section\>\|\<Module\>\):\<End\>]],
    proof_start .. ":" .. proof_end,
  }, ",")
end

-- ---------------------------------------------------------------------------
-- endwise support
-- ---------------------------------------------------------------------------
if vim.g.loaded_endwise then
  vim.b.endwise_addition   = [[\=submatch(0) =~# "match" ? "end." : "End " . submatch(0) . "."]]
  vim.b.endwise_words      = [[Section,Module,\%(lazy\|multi\)\?match]]
  vim.b.endwise_pattern    = [[\%(\<\%(Section\|Module\)\_s\+\%(\<Type\>\_s\+\)\?\zs\S\+\ze\_s*\.\|\<\%(lazy\|multi\)\?match\>\)]]
  vim.b.endwise_syngroups  = "coqVernacCmd,coqKwd,coqLtac"
  vim.b.endwise_end_pattern = nil
end
