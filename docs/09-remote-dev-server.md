# Using the board as an always-on development server

The devkit draws a few watts, is silent most of the time and can stay on behind a UPS, so it also works as the machine where long-running terminal work lives: `ssh` in from anywhere, attach to `tmux`, continue. This page covers what it took to move an existing workspace (several dozen git repositories and a Claude Code project with its memory and conversations) from a laptop to the board.

Access from outside the LAN is described in [04-headless-and-tuning.md](04-headless-and-tuning.md#reaching-the-board-from-outside-the-lan).

## Tools without touching the system Python

The system Python 3.8 carries the NVIDIA builds of PyTorch, OpenCV and the rest ([03-software-stack.md](03-software-stack.md)). Everything else was installed per user, under `~/.local`, so that stack is not disturbed:

| Tool | How | Where |
|---|---|---|
| Node.js 24 | Official `linux-arm64` tarball, checksum verified against `SHASUMS256.txt` | `~/.local/share/node24`, with `node`, `npm`, `npx` linked into `~/.local/bin` |
| uv / uvx 0.13 | `uv-aarch64-unknown-linux-gnu.tar.gz` from the GitHub release, checksum verified | `~/.local/bin` |
| Python 3.12 | `uv python install 3.12` | `~/.local/share/uv/python`; `python3` is still 3.8 |
| git-lfs | `sudo apt install git-lfs` (2.9.2), then `git lfs install --skip-repo` | system package |

Node 24 runs on Ubuntu 20.04's glibc 2.31. For a project that needs a newer Python: `uv venv --python 3.12` inside it. Afterwards `python3 -c "import torch; print(torch.cuda.is_available())"` still printed `True`.

## Copying the repositories from macOS

```bash
rsync -a --exclude node_modules --exclude __pycache__ ./ jetson:workspace/
```

Leave out `node_modules` and Python virtual environments: they hold macOS binaries and have to be re-created on Linux. Then compare `git status` on both sides for every repository. It was identical for 17 of 32; the other 15 differed for three reasons, none of them a copy error:

| Symptom on Linux | Cause | Fix |
|---|---|---|
| `?? .claude/` in several repositories | macOS had a global ignore file, `~/.config/git/ignore` | Copy that file |
| Files shown as deleted | They were excluded from the copy but are tracked in git (a committed virtualenv, a committed `.DS_Store`) | Copy them after all |
| A file with an accent in its name shown as deleted, and the same name as untracked | Unicode normalisation. macOS treats the composed and decomposed spellings of `ó` as the same file; Linux does not, and git on Linux compares bytes | Rename the file to the spelling stored in the index |

For the last one, do not normalise everything to NFC: some repositories had the decomposed spelling committed, and one had **both** spellings committed as two entries, which on macOS are satisfied by a single file. Match each file to what `git ls-files --deleted` reports:

```python
import os, subprocess, unicodedata
N = lambda s: unicodedata.normalize("NFC", s)
def ls(repo, *a):
    out = subprocess.run(["git", "-C", repo, "ls-files", "-z", *a], capture_output=True).stdout
    return [p for p in out.decode().split("\0") if p]
def fix(repo):
    others = {N(p): p for p in ls(repo, "--others")}
    for d in ls(repo, "--deleted"):
        o = others.get(N(d))
        if o and o != d:
            os.rename(os.path.join(repo, o), os.path.join(repo, d))
```

## Moving a Claude Code project between machines

Claude Code keeps a project's conversations and its automatic memory outside the project, in a folder named after the project's absolute path with every `/` replaced by `-`:

```
~/.claude/projects/-Users-me-Documents-work/          # macOS, project at /Users/me/Documents/work
~/.claude/projects/-home-me-work/                     # Linux, project at /home/me/work
    <session-id>.jsonl          conversations
    <session-id>/               sub-agent transcripts and saved tool results
    memory/                     MEMORY.md and the memory files
```

So moving a project is three steps:

1. Copy the project folder itself.
2. Copy the contents of the old `~/.claude/projects/<old-name>/` into `~/.claude/projects/<new-name>/`.
3. Rewrite the old absolute path to the new one inside the copied `.jsonl`, `.md` and `.json` files, and the old folder name too. Guard the pattern so that a sibling folder with a longer name is not rewritten:

```bash
cd ~/.claude/projects/-home-me-work
find . -name .git -prune -o -type f \( -name '*.jsonl' -o -name '*.md' -o -name '*.json' -o -name '*.txt' \) -print0 |
  xargs -0 perl -pi -e 's{/Users/me/Documents/work(?![0-9A-Za-z])}{/home/me/work}g;
                        s{-Users-me-Documents-work(?![0-9A-Za-z])}{-home-me-work}g'
```

What was checked afterwards, with Claude Code 2.1.325 on the board and 2.1.319 on the laptop:

- Every line of the largest transcript (91 MB, 31 877 lines) still parsed as JSON.
- A new session started in the project loaded `CLAUDE.md` and the memory index.
- `claude --resume <session-id>` continued the main conversation and knew what it had last done. `claude -p --no-session-persistence --resume <id> "..."` asks a resumed session a question without adding the question to its history, which is a clean way to test.

Things that do not travel with those folders:

- **MCP servers** defined for the project live in `~/.claude.json`, keyed by the project path. Re-create them with `claude mcp add-json <name> '<json>'` from inside the new project folder. A server started over SSH (`"command": "ssh"`) needs the new machine's key authorised on the target.
- **Credentials** kept elsewhere in the home directory (git credential helpers, OAuth tokens of MCP servers).
- **Project instructions** that describe the machine ("this is a laptop that sleeps") are now wrong and need an edit.
- Before copying, ask the running session on the old machine to save what it has not saved yet and to write a handoff note. It knows which work is half done; the files do not say.

If the project root changes again later, repeat steps 2 and 3 with the new name. It was done twice here and resuming still worked.

## tmux and Shift+Enter

Inside `tmux` on the board, Shift+Enter in Claude Code submitted the prompt instead of inserting a line break. Ubuntu 20.04 ships tmux 3.0a, which cannot pass Shift+Enter through as a distinct key (the `extended-keys` option arrived in 3.2).

- Works with no changes: `Ctrl+J`, or a backslash followed by Enter.
- To make Shift+Enter itself work, map it in the terminal emulator to the bytes `0x1b 0x0d` (Escape, Return: the same thing Option+Enter sends). In iTerm2: Settings, Profiles, Keys, Key Mappings, add Shift+Enter with the action "Send Hex Codes" and `0x1b 0x0d`. tmux passes that through, and it also works in local sessions.

## Time zone

The flashed image came up in `America/Chicago`. Logs from two machines an hour apart are confusing when correlating events (it showed up while reading UPS logs): `sudo timedatectl set-timezone <Area/City>`.
