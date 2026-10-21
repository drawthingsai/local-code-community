# init

Scaffolding commands. Use these instead of creating files by hand — they set up the right file structure.

## init

```bash
hyperframes init my-video                                    # centered blank (TTY: wizard)
hyperframes init my-video --resolution portrait
hyperframes init my-video --non-interactive                  # CI — flag-only, same blank
```

**Default depends on TTY**: in a terminal, the CLI prompts for example/options (default: centered blank). Outside a TTY (CI, agents, piped output) it auto-switches to non-interactive and scaffolds that blank. Use `--example=blank` for the centered blank. Pass `--non-interactive` to force flag-only mode on a TTY.

Other useful flags:

- `--resolution` — preset: `landscape` (1920×1080), `portrait` (1080×1920), `landscape-4k`, `portrait-4k`, `square` (1080×1080), `square-4k`. Aliases: `1080p`, `4k`, `uhd`, `1080p-square`, `4k-square`.
