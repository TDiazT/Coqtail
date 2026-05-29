# Context: Coqtail

Coqtail is a Vim/Neovim plugin for interactive Rocq (formerly Coq) proof
development. It drives a Rocq toplevel process and lets the user step through
proofs, inspect goals, and query definitions.

## Glossary

### Flag
A *boolean* Rocq option, toggled with `Set`/`Unset` (e.g. `Printing
Universes`). Rocq's manual reserves "flag" specifically for the boolean subset.

### Option
A Rocq toplevel setting. May be a [[#Flag]] (boolean) or *valued* — taking a
string (`Diffs`) or integer (`Printing Depth`). Set with `Set <name> <value>`.

### Printing flags
The subset of flags that control how Rocq pretty-prints terms and goals
(`Printing Universes`, `Printing All`, `Printing Notations`, ...). The most
common reason a user wants to change a flag interactively.

### SetOptions / GetOptions
XML-protocol *side-channel* calls (distinct from `Add`-ing a sentence). They
change/read process-global option state without creating a document state id.
Rocq expects printing flags to be changed this way — sending `Set Printing X.`
as a document sentence triggers the "Set this option from the IDE menu instead"
message. Coqtail's backend already routes "scoldable" flags through these calls.

### Retroactivity (of a flag change)
Whether a flag set *after* some content was processed affects the display of
that already-processed content. In LSP-based tools (VsRocq) flag changes are
not retroactive because per-sentence output is cached. Coqtail's XML backend
does not cache: `Print`/`Check`/`About` are queries run at the current tip and
the goal panel is re-fetched on demand, so a flag set via `SetOptions` takes
effect on the next query/re-fetch without re-processing.

### State id / tip
Rocq's document model assigns a state id per processed sentence. The *tip* is
the latest processed state. Queries and goal fetches run against the tip.
