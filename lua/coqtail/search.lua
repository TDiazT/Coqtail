-- Author: Coqtail contributors
-- Searching for Rocq commands and proofs in the buffer.

local M = {}

local COMMAND_PATTERN =
  [[\C^\s*\zs\%(Axiom\|\%(Co\)\?Fixpoint\|Corollary\|Definition\|Example\|Goal\|Lemma\|Proposition\|Theorem\)\>]]
local PROOFSTART_PATTERN =
  [[\C\%(\<Fail\_s\+\)\@<!\<\%(Proof\|Next Obligation\|Final Obligation\|Obligation \d\+\)\>[^.]*\.]]
local PROOFEND_PATTERN =
  [[\C\<\%(Qed\|Defined\|Abort\|Admitted\|Save\)\>]]

local function search_count(pattern, flags, count, visual)
  vim.cmd("normal! m'")
  if visual then
    vim.cmd("normal! gv")
  end
  for _ = 1, count do
    if vim.fn.search(pattern, flags) == 0 then
      break
    end
  end
end

--- Jump to the next/previous Rocq command (Lemma, Definition, etc.).
-- @param flags  vim search flags string (e.g. "W", "Wb")
-- @param count  number of times to repeat
-- @param visual whether to restore visual selection first
function M.command(flags, count, visual)
  search_count(COMMAND_PATTERN, flags, count, visual)
end

--- Jump to the next/previous proof start or end.
-- Searches for proof start when flags contains 'b', end otherwise.
function M.proof(flags, count, visual)
  local pattern = flags:find("b") and PROOFSTART_PATTERN or PROOFEND_PATTERN
  search_count(pattern, flags, count, visual)
end

-- Find the proof block containing (or starting at) the cursor.
-- Returns {start_pos, end_pos} where each pos is a getpos('.') list.
local function find_proof_block()
  local block = vim.fn.searchpairpos(PROOFSTART_PATTERN, "", PROOFEND_PATTERN, "cW")
  local start_pos, end_pos
  if block[1] == 0 and block[2] == 0 then
    vim.fn.search(PROOFSTART_PATTERN, "cW")
    start_pos = vim.fn.getpos(".")
    vim.fn.search(PROOFEND_PATTERN, "W")
    end_pos = vim.fn.getpos(".")
  else
    end_pos = vim.fn.getpos(".")
    vim.fn.search(PROOFSTART_PATTERN, "bW")
    start_pos = vim.fn.getpos(".")
  end
  return start_pos, end_pos
end

--- Select the inner proof text object (between Proof. and Qed.).
function M.select_i()
  local start_pos, end_pos = find_proof_block()
  local start_max_col = vim.fn.match(vim.fn.getline(start_pos[2]), "^[^.]+%.%zs", start_pos[3]) + 1

  if start_pos[2] ~= end_pos[2]
      and start_pos[3] == 1 and end_pos[3] == 1
      and start_max_col == vim.fn.col({ start_pos[2], "$" }) then
    start_pos[2] = start_pos[2] + 1
    start_pos[3] = 0
    end_pos[2] = end_pos[2] - 1
    end_pos[3] = 0
    vim.fn.setpos(".", start_pos)
    vim.cmd("normal! V")
    vim.fn.setpos(".", end_pos)
  else
    if start_max_col == vim.fn.col({ start_pos[2], "$" }) then
      start_pos[2] = start_pos[2] + 1
      start_pos[3] = 0
    else
      start_pos[3] = start_max_col
    end
    if end_pos[3] == 1 then
      end_pos[2] = end_pos[2] - 1
      end_pos[3] = vim.fn.col({ end_pos[2], "$" })
    else
      end_pos[3] = end_pos[3] - 1
    end
    vim.fn.setpos(".", start_pos)
    vim.cmd("normal! v")
    vim.fn.setpos(".", end_pos)
  end
end

--- Select the outer proof text object (including Proof. and Qed.).
function M.select_a()
  local start_pos, end_pos = find_proof_block()
  local end_max_col = vim.fn.match(vim.fn.getline(end_pos[2]), "^[^.]+%.%zs", end_pos[3]) + 1

  vim.fn.setpos(".", start_pos)
  if start_pos[3] > 1 or end_pos[3] > 1
      or end_max_col ~= vim.fn.col({ end_pos[2], "$" }) then
    end_pos[3] = end_max_col
    vim.cmd("normal! v")
  else
    vim.cmd("normal! V")
  end
  vim.fn.setpos(".", end_pos)
end

return M
