-- Copyright (C) 2015, 2017 Florian Wesch <fw@dividuum.de>
-- All Rights Reserved.
--
-- Unauthorized copying of this file, via any medium is
-- strictly prohibited. Proprietary and confidential.

util.no_globals()

local json = require "json"

local scissors = sys.get_ext "scissors"

local st
local movie_covers = {}
local loaded_images = {}
local rotation = 0
local bload_threshold = 3600
local bload_fallback = resource.load_image "empty.png"
local screen_idx, screen_cnt
local logo, logo_always
local background

local function mipmapped_image(filename)
    return resource.load_image{
        file = filename,
        mipmap = true,
    }
end
util.loaders.jpg = mipmapped_image
util.loaders.png = mipmapped_image

local res = util.resource_loader({
    "font.ttf";
    "threed.png";
    "showtime.png";
}, {})

local bgfill = resource.create_colored_texture(.5,.5,.5,1)
local fgfill = resource.create_colored_texture(.1,.1,.1,1)
local infofill = resource.create_colored_texture(1,1,1,1)

local strike_through = resource.create_colored_texture(1,1,1,1)
local strike_through_color = resource.create_shader[[
    uniform sampler2D Texture;
    varying vec2 TexCoord;
    uniform vec4 color;
    void main() {
        gl_FragColor = texture2D(Texture, TexCoord) * color;
    }
]]

local base_time = N.base_time or 0

local function current_offset()
    local time = base_time + sys.now()
    local offset = (time % 86400) / 60
    return offset
end

util.data_mapper{
    ["clock/set"] = function(time)
        print("time set to", time)
        base_time = tonumber(time) - sys.now()
        N.base_time = base_time
        print("CURRENT OFFSET is now", current_offset())
    end;
}

local bload = (function()
    local function strip(s)
        return s:match "^%s*(.-)%s*$"
    end

    -- Sometimes the name has another numerical suffix. Throw that away.
    local function strip_name(s)
        return strip(s:sub(1, 29))
    end

    local function hhmm(s)
        local hour, minute = s:match("(..)(..)")
        local hour, minute = tonumber(hour), tonumber(minute)
        local function mil2ampm(hour, minute)
            local suffix = hour < 12 and "am" or ""
            return ("%d:%02d%s"):format((hour-1) % 12 +1, minute, suffix)
        end
        return {
            hour = hour,
            minute = minute,
            offset = hour * 60 + minute,
            string = mil2ampm(hour, minute),
        }
    end
    local function tobool(str)
        return tonumber(str) == 1
    end

    local function convert(names, fixups, ...)
        local cols = {...}
        local out = {}
        for i = 1, #fixups do
            out[names[i]] = fixups[i](cols[i])
        end
        return out
    end

    local sorted_movies = {}
    local movies_on_screen = 1
    local bload, date

    local function parse_bload()
        if not date or not bload then
            print("cannot parse yet. no bload or no date")
            return
        end

        local movies = {}
        for line in bload:gmatch("[^\r\n]+") do
            -- "123456789012345678901234567890123456789012345678901234567890123456789012345"
            -- "1111111122 33 4444 555  6666 7777 8 9999AAAAAAAAAAAAAAAAAAAAAAAAAAAAA     B"
            -- "06/25/151  1  1320 94   10   231  0     Inside Out                        0"

            local single_day = #line ~= 71

            local row

            if single_day then 
                row = convert(
                    -- Example:
                    -- 9  1  1155 101  0    96   0 R   Longlegs AD, WC, CC, LD
                    -- 9  2  1440 101  0    96   0 R   Longlegs AD, WC, CC, LD
                    {"screen", "show",   "showtime", "runtime", "sold",   "seats",  "threed", "mpaa", "name"},
                    {strip,    tonumber, hhmm,       tonumber,  tonumber, tonumber, tobool,   strip,  strip},
                    line:match("(..) (..) (....) (...)  (....) (....) (.) (....)(.*)")
                )
            else
                row = convert(
                    -- Example:
                    -- 11 1  1130 101  0    76   0 PG  The Garfield Movie AD, WC, CC,08132024 
                    -- 11 2  1430 181  0    76   0 R   Horizon: An American Saga Chap07172024 
                    -- 9  4  1905 122  42   54   0 PG-1Twisters AD, WC, CC, LD       08232024
                    {"screen", "show",   "showtime", "runtime", "sold",   "seats",  "threed", "mpaa", "name", "date"},
                    {strip,    tonumber, hhmm,       tonumber,  tonumber, tonumber, tobool,   strip,  strip, strip},
                    line:match("(..) (..) (....) (...)  (....) (....) (.) (....)(..............................)(........)")
                )

                -- Old!?
                -- row = convert(
                --     {"date","screen", "show",   "showtime", "runtime", "sold",   "seats",  "threed", "mpaa", "name"},
                --     {strip, strip,    tonumber, hhmm,       tonumber,  tonumber, tonumber, tobool,   strip,  strip_name},
                --     line:match("(........)(..) (..) (....) (...)  (....) (....) (.) (....)(.*)")
                -- )
                if row.mpaa == "PG-1" then -- wtf?
                    row.mpaa = "PG-13"
                end
            end

            if single_day or row.date == date then
                if not movies[row.name] then
                    movies[row.name] = {}
                end

                local movie = movies[row.name]
                movie[#movie+1] = {
                    mpaa = row.mpaa,
                    threed = row.threed,
                    showtime = row.showtime,
                    seats = row.seats,
                    sold = row.sold,
                }
            end
        end

        local pre_sorted_movies = {}
        for name, shows in pairs(movies) do
            table.sort(shows, function(a, b)
                return a.showtime.offset < b.showtime.offset
            end)
            local mpaa = shows[1].mpaa
            local threed = shows[1].threed

            local movie_name = name:gsub('[^%w]', ''):lower()
            local cover_file
            for _, movie_cover in ipairs(movie_covers) do
                if string.find(movie_name, movie_cover.pattern) then
                    cover_file = movie_cover.file
                    break
                end
            end
            pre_sorted_movies[#pre_sorted_movies+1] = {
                name = name,
                cover_file = cover_file,
                mpaa = mpaa,
                threed = threed,
                shows = shows,
            }
        end
        table.sort(pre_sorted_movies, function(a, b)
            return a.name < b.name
        end)

        movies_on_screen = math.ceil(
            #pre_sorted_movies / screen_cnt
        )
        local split_start = movies_on_screen * (screen_idx - 1) + 1
        local split_end = split_start + movies_on_screen - 1
        print(#pre_sorted_movies, split_start, split_end)

        sorted_movies = {}
        for idx, movie in ipairs(pre_sorted_movies) do
            if idx >= split_start and idx <= split_end then
                sorted_movies[#sorted_movies+1] = movie
            end
        end

        -- pp(sorted_movies)
    end

    local function get_sorted_movies()
        return sorted_movies
    end

    local function set_bload(new_bload)
        if new_bload == bload then return end
        bload = new_bload
        return parse_bload()
    end

    local function set_date(new_date)
        if new_date == date then return end
        date = new_date
        return parse_bload()
    end

    local function get_movies_on_screen()
        return movies_on_screen
    end

    return {
        set_bload = set_bload;
        set_date = set_date;
        force_parse = parse_bload;

        get_sorted_movies = get_sorted_movies;
        get_movies_on_screen = get_movies_on_screen;
    }
end)()

util.json_watch("config.json", function(config)
    movie_covers = {}
    loaded_images = {}
    logo_always = config.logo_always
    background = config.background

    gl.setup(1920, 1080)

    rotation = config.rotation or 0
    local setup_rotation = config.__metadata.device_data.rotation
    if setup_rotation and setup_rotation ~= -1 then
        rotation = setup_rotation
    end

    st = util.screen_transform(rotation)

    for _, image in ipairs(config.images) do
        movie_covers[#movie_covers+1] = {
            pattern = '^' .. image.file.filename:lower():gsub('.jpg', ''):gsub('.*/', ''):gsub('[^%w%*]', ''):gsub('%*', '.*') .. '$',
            file = resource.open_file(image.file.asset_name),
        }
    end

    bload_threshold = config.bload_threshold
    bload_fallback = resource.load_image(config.bload_fallback.asset_name)

    local split = config.__metadata.device_data.split
    if split then
        screen_idx = split[1]
        screen_cnt = split[2]
    else
        screen_idx = 1
        screen_cnt = 1
    end

    logo = mipmapped_image(config.logo.asset_name)

    bload.force_parse()

    node.gc()
end)

util.file_watch("BLOAD.txt", bload.set_bload)

util.data_mapper{
    ["date/set"] = function(date)
        print("date set to", date)
        bload.set_date(date)
    end;
}

local function layouter(rotation, num_slots)
    if rotation == 90 or rotation == 270 then
        if num_slots <= 3 then
            return 1, 3
        elseif num_slots <= 8 then
            return 2, 4
        elseif num_slots <= 10 then
            return 2, 5
        elseif num_slots <= 15 then
            return 3, 5
        else
            return 3, 6
        end
    else
        if num_slots <= 4 then
            return 2, 2
        elseif num_slots <= 6 then
            return 3, 2
        elseif num_slots <= 9 then
            return 3, 3
        elseif num_slots <= 12 then
            return 4, 3
        elseif num_slots <= 16 then
            return 4, 4
        else
            return 5, 4
        end
    end
end

local load_in_progress
local skip_text_end = sys.now()

local function show_bload()
    if load_in_progress and load_in_progress:state() == "loaded" then
        load_in_progress = nil
    end

    local movies = bload.get_sorted_movies()

    local num_slots = bload.get_movies_on_screen()
    if logo_always then
        num_slots = num_slots + 1
    end
    local cols, rows = layouter(rotation, num_slots)

    local cell_w = WIDTH / cols
    local cell_h = HEIGHT / rows
    local now = current_offset()

    for idx = 1, #movies+1 do
        local x = (idx - 1)%cols * (cell_w)
        local y = math.floor((idx - 1)/cols) * cell_h
        local movie = movies[idx]
        if movie then
            bgfill:draw(x, y, x+cell_w, y+cell_h)
            local split = math.min(cell_h-150, cell_h/1.5)

            local image
            if movie.cover_file then
                image = loaded_images[movie.cover_file]
                if not image and not load_in_progress then
                    print("loading image", movie.cover_file)
                    load_in_progress = resource.load_image{
                        file = movie.cover_file:copy(),
                        -- mipmap = true,
                    }

                    loaded_images[movie.cover_file] = load_in_progress
                    -- don't write text for a short duration
                    skip_text_end = sys.now() + 0.5
                end
            end

            if image and image:state() == "loaded" then
                image:draw(x+1, y+1, x+cell_w-1, y+split)
            else
                local width = 99999
                local size = 60
                while width > cell_w -5 do
                    size = size - 5
                    width = res.font:width(movie.name, size)
                end
                local name_x = x + (cell_w-width) / 2
                res.font:write(name_x, y+(split-size)/2, movie.name, size, 0,0,0,1)
            end

            -- info line (rating + 3d logo)
            infofill:draw(x+1, y+split, x+cell_w-1, y+split+50)
            local width = res.font:width(movie.mpaa, 30)
            if movie.threed then
                width = width + 70
            end
            local info_x = x + (cell_w-width) / 2
            info_x = info_x + res.font:write(info_x, y+split+10, movie.mpaa, 30, 0,0,0,1)
            if movie.threed then
                res.threed:draw(info_x + 10, y+split+10, info_x+60, y + split+40)
            end

            -- showtime box
            fgfill:draw(x+1, y+split+51, x+cell_w-1, y+cell_h-1)
            local time_cols, time_rows, font_size
            if #movie.shows <= 1 then
                time_cols = 1
                time_rows = 1
            elseif #movie.shows <= 2 then
                time_cols = 2
                time_rows = 1
            elseif #movie.shows <= 4 then
                time_cols = 2
                time_rows = 2
            elseif #movie.shows <= 6 then
                time_cols = 3
                time_rows = 2
            elseif #movie.shows <= 9 then
                time_cols = 3
                time_rows = 3
            elseif #movie.shows <= 15 then
                time_cols = 5
                time_rows = 3
            elseif #movie.shows <= 18 then
                time_cols = 6
                time_rows = 3
            elseif #movie.shows <= 20 then
                time_cols = 5
                time_rows = 4
            elseif #movie.shows <= 24 then
                time_cols = 6
                time_rows = 4
            else -- 30 MAX
                time_cols = 6
                time_rows = 5
            end
            font_size = math.floor(math.min(
                cell_w / time_cols / 4.5,
                cell_h / time_rows / 4.5
            ))

            if sys.now() > skip_text_end then
                local show_w = math.floor(cell_w/time_cols)
                local show_h = math.floor((cell_h - (split+50))/time_rows)
                for si = 1, #movie.shows do
                    local show = movie.shows[si]
                    local show_x = math.floor(x+1 + (si-1)%time_cols * show_w)
                    local show_y = math.floor(
                        y+split+50+math.floor((si-1)/time_cols) * show_h + (show_h-font_size)/2 + font_size*0.1)

                    local showtime = show.showtime
                    local width = res.font:width(showtime.string, font_size)
                    local started = now > showtime.offset + 15
                    local time_x = math.floor(show_x + (show_w-width)/2)

                    local color = {1,1,1,1}

                    if show.seats == 0 then
                        color[1], color[2], color[3] = 1, .2, .2
                    elseif show.seats <= 20 then
                        color[1], color[2], color[3] = 1, .8, .2
                    end

                    if started then
                        color = {.5,.5,.5,1}
                    end

                    res.font:write(time_x, show_y, showtime.string, font_size, unpack(color))

                    if started then
                        strike_through_color:use{color = color}
                        strike_through:draw(time_x-10, show_y+font_size/2-font_size*0.05, time_x+width+10, show_y+font_size/2-font_size*0.05+2, 1)
                        strike_through_color:deactivate()
                    end
                end
            end
        else
            util.draw_correct(logo, x, y, x+cell_w, y+cell_h-1)
            -- util.draw_correct(logo, x, y, WIDTH, y+cell_h-1)
        end
    end
end

local bload_age = 0

util.data_mapper{
    ["age/set"] = function(age)
        bload_age = tonumber(age)
    end;
}

local function show_fallback()
    util.draw_correct(bload_fallback, 0, 0, WIDTH, HEIGHT)
end

function node.render()
    gl.clear(unpack(background.rgba))
    st()

    if bload_age > bload_threshold then
        show_fallback()
    else
        show_bload()
    end
end
