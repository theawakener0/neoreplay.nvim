local M = {}

M.platforms = {
    shorts = {
        name = "YouTube Shorts",
        aspect_ratio = "9:16",
        resolution = { width = 1080, height = 1920 },
        constraints = {
            max_duration = 60,  -- seconds
            max_file_size = 256 * 1024 * 1024,  -- 256MB
        },
        optimal = {
            speed = 30,
            font_size = 24,
            padding = 20,
        },
        features = {
            auto_zoom = true,           -- Zoom to active code area
            vertical_centering = true,  -- Center code vertically
            background_blur = true,     -- Blurred background of code
            captions = true,            -- Show edit descriptions
            progress_indicator = false, -- No progress bar (too small)
        },
    },
    
    reels = {
        name = "Instagram Reels",
        aspect_ratio = "9:16",
        resolution = { width = 1080, height = 1920 },
        constraints = {
            max_duration = 90,
            max_file_size = 4 * 1024 * 1024 * 1024,  -- 4GB
        },
        optimal = {
            speed = 25,
            font_size = 26,  -- Slightly larger for mobile
            padding = 30,
        },
        features = {
            auto_zoom = true,
            vertical_centering = true,
            background_gradient = true,  -- Instagram style gradient
            captions = true,
            progress_indicator = false,
            watermark = {
                enabled = false,  -- Instagram adds own
            },
        },
    },
    
    tiktok = {
        name = "TikTok",
        aspect_ratio = "9:16",
        resolution = { width = 1080, height = 1920 },
        constraints = {
            max_duration = 600,  -- 10 minutes for some accounts
            max_file_size = 287 * 1024 * 1024,  -- 287MB
        },
        optimal = {
            speed = 35,  -- TikTok users prefer fast
            font_size = 28,  -- Even larger
            padding = 40,
        },
        features = {
            auto_zoom = true,
            vertical_centering = true,
            background_gradient = true,
            captions = {
                enabled = true,
                style = "bouncing",  -- TikTok style text animation
            },
            progress_indicator = false,
            sound_suggestions = true,  -- Suggest trending sounds
        },
    },
    
    twitter = {
        name = "Twitter/X",
        aspect_ratio = "16:9",  -- Twitter prefers landscape
        resolution = { width = 1920, height = 1080 },
        constraints = {
            max_duration = 140,  -- 2:20
            max_file_size = 512 * 1024 * 1024,  -- 512MB
        },
        optimal = {
            speed = 20,
            font_size = 18,
            padding = 50,
        },
        features = {
            auto_zoom = false,  -- Keep full context
            captions = true,
            progress_indicator = true,
            chrome = true,  -- Show some UI
        },
    },
}

function M.get(platform_name)
    return M.platforms[platform_name] or M.platforms.shorts
end

function M.list()
  local list = {}
  for k, v in pairs(M.platforms) do
    table.insert(list, { id = k, name = v.name })
  end
  return list
end

return M
