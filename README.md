# neoreplay.nvim

**Semantic timelapse replay for Neovim.**

Stop re-reading finished code. Replay how it was built, one semantic step at a time. This isn't a keystroke recorder; it's an edit-event engine that captures the evolution of your buffer.

## 🚀 10-Second Usage

1. Start recording a session:
   `:NeoReplayStart`
2. Write some code, refactor, edit.
3. Stop recording:
   `:NeoReplayStop`
4. Replay the session in a floating window:
   `:NeoReplayPlay`

## 🎥 GIF Placeholder
![NeoReplay Demo](https://via.placeholder.com/800x450.gif?text=NeoReplay+Demo+Coming+Soon)

## 🛠 Features

- **Semantic Recording**: Captures buffer diffs via `nvim_buf_attach`, ignoring cursor movements and noise.
- **Intelligent Compression**: Merges identical line-range edits happening in short bursts into single semantic steps.
- **Fidelity Guarantee**: The replay engine ensures the final state of the replay buffer perfectly matches the original session.
- **Minimal UI**: Simple floating window with speed controls.

## 🚫 Non-Goals

- No video encoding (MP4/GIF). This is purely inside Neovim.
- No multi-buffer session synchronization.
- No keystroke visualization (use `screenkey.nvim` for that).
- No external dependencies (keeps it light and fast).

## 🔧 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-username/neoreplay.nvim",
  config = function()
    require("neoreplay").setup({})
  end
}
```

## 🧪 Testing

Run tests via headless Neovim:

```bash
nvim --headless -c "set runtimepath+=." -c "luafile tests/compression_spec.lua" -c "qall"
```

## 📜 License
MIT
