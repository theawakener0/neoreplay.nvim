# neoreplay.nvim

**Timelapse replay for Neovim.**

Stop re-reading finished code. Replay how it was built, one semantic step at a time. This isn't a keystroke recorder; it's an edit-event engine that captures the evolution of your buffer.

## 10-Second Usage

1. Start recording a session:
  `:NeoReplayStart` (or `:NeoReplayStart all_buffers=true`)
2. Write some code, refactor, edit.
3. Stop recording:
   `:NeoReplayStop`
4. Replay the session in a floating window:
   `:NeoReplayPlay`

## Chronos: The Time Traveler

Forgot to start NeoReplay? No problem. **Chronos mode** excavates your Neovim undo tree, reconstructs the timeline of your edits, and replays them as if you had been recording the whole time.

> **Recommended:** Keep your undo history persistent for best Chronos results:
> `vim.opt.undofile = true`

- **Command**: `:NeoReplayChronos`
- **Flex Mode**: `:NeoReplayFlexChronos` (100x speed archeology)

## GIF Placeholder
![NeoReplay Demo](https://via.placeholder.com/800x450.gif?text=NeoReplay+Demo+Coming+Soon)

## Features

- **Semantic Recording**: Captures buffer diffs via `nvim_buf_attach`, ignoring cursor movements and noise.
- **Intelligent Compression**: Merges identical line-range edits happening in short bursts into single semantic steps.
- **Chronos (Undo Replay)**: Forgot to record? Excavate your buffer's undo tree to reconstruct history.
- **Scene Tracks**: Multi-buffer capture and replay in a synchronized scene.
- **Semantic Overlays**: During replay, labels like *insert / delete / replace* with cadence indicators.
- **Fidelity Guarantee**: The replay engine ensures the final state of the replay buffer perfectly matches the original session.
- **Minimal UI**: Simple floating window with speed controls.

## Core Principles

- **No heavy dependencies inside Neovim** → Optional capability packs (VHS, FFmpeg, asciinema).
- **No native video encoding** → Export pipelines (VHS/FFmpeg/frames/asciinema).
- **No keystroke visualization** → Semantic overlays and cadence instead of raw keys.
- **No multi-buffer sync** → Scene tracks with focus buffer support.

## How it Works (Why no Native GIF/Video?)

One minor detail: Neovim is a text editor, not a video encoder. To keep the plugin light and fast, we don't include a heavy MP4 encoder. Instead, we use a **scripting bridge**:

1. **Recording**: We capture semantic buffer events.
2. **Export**: `:NeoReplayExportGIF` or `:NeoReplayExportMP4` generates a `.tape` file for [VHS](https://github.com/charmbracelet/vhs).
3. **Generation**: VHS opens a headless terminal, runs the replay, and saves it as a high-quality GIF or MP4.

## Export Output Locations (Defaults)

- **Base export directory**: `~/.neoreplay`
- **VHS**: `~/.neoreplay/neoreplay.tape` (tape) + output file in current working directory unless `filename=...`
- **Frames**: `~/.neoreplay/frames/`
- **Asciinema**: `~/.neoreplay/neoreplay_asciinema.sh` (script) and `~/.neoreplay/neoreplay.cast`
- **FFmpeg**: `~/.neoreplay/neoreplay_capture.mp4`
- **Raw session export**: `~/.neoreplay/neoreplay_session.json`

All exporters accept overrides (e.g. `filename=...`, `dir=...`, `json_path=...`, `tape_path=...`).

### Video/GIF Export Commands

| Command | Usage | Description |
|---------|-------|-------------|
| `:NeoReplayExportGIF` | `:NeoReplayExportGIF speed=20` | Generate a high-quality GIF tape via VHS. |
| `:NeoReplayExportMP4` | `:NeoReplayExportMP4 quality=90` | Generate an MP4 tape via VHS. |
| `:NeoReplayRecordFFmpeg`| `:NeoReplayRecordFFmpeg` | **Wild Mode**: Direct screen capture via FFmpeg. |
| `:NeoReplayExportFrames` | `:NeoReplayExportFrames dir=~/frames` | Export per-event JSON frames for external renderers. |
| `:NeoReplayExportAsciinema` | `:NeoReplayExportAsciinema speed=20` | Generate an asciinema capture script. |

*Configurable parameters for VHS:* `speed` (multiplier), `quality` (1-100), `filename`.

> **Note on FFmpeg Record**: The `:NeoReplayRecordFFmpeg` command captures your actual Neovim window live using `x11grab`. It requires `ffmpeg` and `xwininfo` (on Linux).

This gives you perfectly crisp, pixel-perfect clips without bloating your Neovim installation.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "theawakener0/neoreplay.nvim",
  opts = {
    ignore_whitespace = false,
  }
}
```

## Configuration

NeoReplay works out of the box, but you can tune the experience:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ignore_whitespace` | `boolean` | `false` | If true, edits that only change whitespace will not be recorded. |
| `record_all_buffers` | `boolean` | `false` | If true, record all loaded file buffers (scene tracks). |
| `playback_speed` | `number` | `20.0` | Default speed for replay and exports. |
| `vhs_theme` | `string` | `nil` | Override the VHS theme (e.g., "Nord"). |
| `vhs_mappings` | `table` | `{}` | Key-value pairs of Neovim colorschemes to VHS themes. |
| `keymaps` | `table` | `{}` | Optional keymaps for commands (`start`, `stop`, `play`, `chronos`). |
| `controls` | `table` | `{}` | Override replay control keys (`quit`, `quit_alt`, `pause`, `faster`, `slower`). |

### Copy-Paste Config (Full)

```lua
require("neoreplay").setup({
  ignore_whitespace = false,
  record_all_buffers = false,
  playback_speed = 20.0,
  -- Map your custom colorscheme to a VHS theme
  vhs_mappings = {
    ["rose-pine"] = "Rose Pine",
  },
  keymaps = {
    start = "<leader>rs",
    stop = "<leader>rt",
    play = "<leader>rp",
    flex = "<leader>rf",
    chronos = "<leader>rc",
    clear = "<leader>rx",
    export_gif = "<leader>rg",
    export_mp4 = "<leader>rm",
    export_frames = "<leader>rF",
    export_asciinema = "<leader>ra",
    record_ffmpeg = "<leader>rr",
  }
  ,controls = {
    quit = "q",
    quit_alt = "<Esc>",
    pause = "<space>",
    faster = "=",
    slower = "-",
  }
})
```

## Controls (During Replay)

When the replay window is open, use these keys:
- `Space`: Pause / Resume
- `=`: Speed up
- `-`: Slow down
- `q` / `Esc`: Close replay

## VHS Themes

All available VHS themes are bundled. Use `:NeoReplayVHSThemes` to open the full list in a scratch buffer, or set `vhs_theme` directly to any theme name.

## License

MIT - See [LICENSE](LICENSE) for details.
