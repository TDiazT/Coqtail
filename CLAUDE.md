# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Coqtail

Coqtail is a Vim/Neovim plugin for interactive Rocq (formerly Coq) proof development. It communicates with the Rocq process via an XML protocol, allowing users to step through proofs interactively.

## Common Commands

### Testing
```bash
tox -e unit-py310       # Python unit tests
tox -e coq-py310        # Rocq integration tests (requires Rocq installed)
tox -e vim              # Vim unit tests (runs tests/vim/run.sh)
```

### Linting and Formatting
```bash
tox -e check-all        # Run all checks (formatting, types, linting)
tox -e lint             # flake8 + pylint
tox -e format           # black + isort
tox -e mypy             # Type checking
```

### Running a Single Test
```bash
pytest tests/unit/test_xmlInterface.py -k "test_name"
```

## Architecture

There are two parallel backend implementations:

### Python Backend (Vim + Neovim, legacy)
- `python/coqtail.py` — Main class, TCP server (`CoqtailServer`), per-buffer handler (`CoqtailHandler`), session management (`Coqtail`)
- `python/coqtop.py` — Rocq subprocess wrapper, manages stdin/stdout communication
- `python/xmlInterface.py` — Version-specific XML protocol parser/serializer for Rocq 8.4–9.1+

The Python backend runs as a TCP server that Vim connects to via channels.

### Lua Backend (Neovim only, in progress)
- `lua/coqtail/init.lua` — Entry point, commands, mappings
- `lua/coqtail/session.lua` — Per-buffer session management
- `lua/coqtail/coqtop.lua` — Rocq subprocess via libuv async I/O
- `lua/coqtail/xml_interface.lua` — XML protocol layer
- `lua/coqtail/panels.lua` — Goal/Info window management
- `lua/coqtail/xml.lua` — XML parsing/serialization utilities

The Lua backend is a direct port of the Python backend, using Neovim's libuv for async subprocess communication instead of a TCP server.

### Vim Plugin Layer
- `ftplugin/coq.vim` (Vim) → `autoload/coqtail.vim` → Python TCP server
- `ftplugin/coq.lua` (Neovim) → `lua/coqtail/init.lua` → Lua backend directly
- `autoload/coqtail/` — Vim-side modules (channel, panels, search, project files)
- `syntax/coq*.vim` — Syntax highlighting; `indent/coq.vim` — Indentation

### XML Protocol
Both backends implement the same Rocq XML protocol. The protocol varies significantly across Rocq versions (8.4–9.1+), so `xmlInterface` contains version-dispatched serialization/deserialization. This is the most complex part of the codebase.

## Compatibility Matrix
- Rocq: 8.4 through 9.1 (and master)
- Vim: 7.4+ (non-blocking requires 8.0+)
- Neovim: 0.3+
- Python: 3.6+

## Code Quality
- Python uses black + isort formatting, mypy strict typing (`disallow_untyped_defs`), flake8 + pylint
- CI tests against many Rocq and Vim versions using Nix (see `ci/` directory)
