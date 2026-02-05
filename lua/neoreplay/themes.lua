local M = {}

M.active_theme = "default"

-- Theme definitions with both visual and behavioral presets
M.themes = {
    minimal = {
        description = "Clean, distraction-free code view",
        visual = {
            font_size = 14,
            padding = 10,
            chrome = false,
            border = "none",
            theme = "Builtin Dark",
        },
        behavior = {
            speed = 25,
            progress_bar = false,
            heatmap = false,
            dashboard = false,
            pause_on_segments = false,
            show_edit_labels = false,
        },
        export = {
            quality = 90,
            fullscreen = false,
        },
    },
    
    presentation = {
        description = "Large, readable format for talks",
        visual = {
            font_size = 20,
            padding = 40,
            chrome = true,
            border = "rounded",
            theme = "Catppuccin Mocha",
        },
        behavior = {
            speed = 15,
            progress_bar = true,
            heatmap = false,
            dashboard = true,
            pause_on_segments = true,
            pause_duration = 2.0,
            show_edit_labels = true,
        },
        export = {
            quality = 100,
            fullscreen = true,
        },
    },
    
    tutorial = {
        description = "Educational format with explanations",
        visual = {
            font_size = 18,
            padding = 30,
            chrome = true,
            border = "rounded",
            theme = "GitHub Dark",
            captions = {
                enabled = true,
                position = "bottom",
                duration = 3.0,
            },
        },
        behavior = {
            speed = 8,
            progress_bar = true,
            heatmap = true,
            dashboard = true,
            pause_on_segments = true,
            pause_duration = 3.0,
            show_edit_labels = true,
            typewriter_sound = false,
        },
        export = {
            quality = 100,
            fullscreen = true,
        },
    },
    
    cinematic = {
        description = "Movie-style dramatic presentation",
        visual = {
            font_size = 22,
            padding = 60,
            chrome = true,
            border = "double",
            theme = "Dracula",
            captions = {
                enabled = true,
                position = "center",
                style = "fade",
            },
            effects = {
                fade_transitions = true,
                zoom_on_change = true,
                highlight_duration = 1.5,
            },
        },
        behavior = {
            speed = 5,
            progress_bar = false,
            heatmap = false,
            dashboard = false,
            pause_on_segments = true,
            pause_duration = 2.0,
            show_edit_labels = false,
            smooth_scroll = true,
        },
        export = {
            quality = 100,
            fullscreen = true,
            framerate = 60,
        },
    },
}

function M.get(name)
    local theme = M.themes[name] or M.themes.minimal
    -- Return deep copy to prevent mutation
    return vim.deepcopy(theme)
end

function M.list()
    local list = {}
    for name, theme in pairs(M.themes) do
        table.insert(list, {
            name = name,
            description = theme.description,
        })
    end
    return list
end

return M
