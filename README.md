# neoreplay.nvim

**Timelapse replay for Neovim.**

Stop re-reading finished code. Replay how it was built, one semantic step at a time. This isn't a keystroke recorder; it's an edit-event engine that captures the evolution of your buffer.

## 10-Second Usage

1. Start recording a session:
   `:NeoReplayStart`
2. Write some code, refactor, edit.
3. Stop recording:
   `:NeoReplayStop`
4. Replay the session in a floating window:
   `:NeoReplayPlay`

## Chronos: The Time Traveler

Forgot to start NeoReplay? No problem. **Chronos mode** excavates your Neovim undo tree, reconstructs the timeline of your edits, and replays them as if you had been recording the whole time.

- **Command**: `:NeoReplayChronos`
- **Flex Mode**: `:NeoReplayFlexChronos` (100x speed archeology)

## GIF Placeholder
![NeoReplay Demo](https://via.placeholder.com/800x450.gif?text=NeoReplay+Demo+Coming+Soon)

## Features

- **Semantic Recording**: Captures buffer diffs via `nvim_buf_attach`, ignoring cursor movements and noise.
- **Intelligent Compression**: Merges identical line-range edits happening in short bursts into single semantic steps.
- **Chronos (Undo Replay)**: Forgot to record? Excavate your buffer's undo tree to reconstruct history.
- **Fidelity Guarantee**: The replay engine ensures the final state of the replay buffer perfectly matches the original session.
- **Minimal UI**: Simple floating window with speed controls.

## Non-Goals

- **No video encoding** (MP4/GIF). This is purely inside Neovim.
- No multi-buffer session synchronization.
- No keystroke visualization (use `screenkey.nvim` for that).
- No external dependencies (keeps it light and fast).

## How it Works (Why no Native GIF/Video?)

One minor detail: Neovim is a text editor, not a video encoder. To keep the plugin light and fast, we don't include a heavy MP4 encoder. Instead, we use a **scripting bridge**:

1. **Recording**: We capture semantic buffer events.
2. **Export**: `:NeoReplayExportGIF` or `:NeoReplayExportMP4` generates a `.tape` file for [VHS](https://github.com/charmbracelet/vhs).
3. **Generation**: VHS opens a headless terminal, runs the replay, and saves it as a high-quality GIF or MP4.

### Video/GIF Export Commands

| Command | Usage | Description |
|---------|-------|-------------|
| `:NeoReplayExportGIF` | `:NeoReplayExportGIF speed=20` | Generate a high-quality GIF tape via VHS. |
| `:NeoReplayExportMP4` | `:NeoReplayExportMP4 quality=90` | Generate an MP4 tape via VHS. |
| `:NeoReplayRecordFFmpeg`| `:NeoReplayRecordFFmpeg` | **Wild Mode**: Direct screen capture via FFmpeg. |

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
| `playback_speed` | `number` | `20.0` | Default speed for replay and exports. |
| `vhs_theme` | `string` | `nil` | Override the VHS theme (e.g., "Nord"). |
| `vhs_mappings` | `table` | `{}` | Key-value pairs of Neovim colorschemes to VHS themes. |
| `keymaps` | `table` | `{}` | Optional keymaps for commands (`start`, `stop`, `play`, `chronos`). |

### Copy-Paste Config (Full)

```lua
require("neoreplay").setup({
  ignore_whitespace = false,
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
    record_ffmpeg = "<leader>rr",
  }
})
```

## Controls (During Replay)

When the replay window is open, use these keys:
- `Space`: Pause / Resume
- `=`: Speed up
- `-`: Slow down
- `q` / `Esc`: Close replay

## Testing

Run tests via headless Neovim:

```bash
nvim --headless -c "set runtimepath+=." -c "luafile tests/compression_spec.lua" -c "qall"
```

## License

MIT - See [LICENSE](LICENSE) for details.
