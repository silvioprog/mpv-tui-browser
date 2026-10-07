local utils = require "mp.utils"
local msg = require "mp.msg"
local options = { online_covers = true }
require("mp.options").read_options(options, "mpv-tui-browser")

local function normalize(path)
    return mp.command_native({"normalize-path", path})
end

local function find_root()
    local first = mp.get_property_native("playlist", {})[1]
    if not first then
        return mp.get_property("working-directory")
    end
    local info = utils.file_info(first.filename)
    if info and info.is_dir then
        if mp.get_property("directory-mode") == "auto" then
            mp.set_property("directory-mode", "recursive")
        end
        return normalize(first.filename)
    end
    return normalize((utils.split_path(first.filename)))
end

mp.set_property("vo", "null")
mp.set_property("msg-level", "all=no")
local root = find_root()
local stack = { root }
local query = ""
local shown = {}
local focus = 1
local selecting = false
local first = 1
local walked = nil
local path_seen = false
local art_supported = os.getenv("TERM_PROGRAM") == "ghostty" or os.getenv("KITTY_WINDOW_ID") ~= nil
local art_ready_path = nil
local drawn_art_key = nil
local art_file = nil
local art_counter = 0
local base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local delete_art = "\027_Ga=d,d=I,i=1,q=2\027\\"
local drawn_second = nil
local curl_path = "/usr/bin/curl"
local curl_agent = "mpv-tui-browser/0.1 ( https://github.com/silvioprog/mpv-tui-browser )"
local min_cover_score = 90
local folder_cover_name = ".folder.jpg"
local cover_cache = {}
local cover_files = {}
local cover_counter = 0
local cover_running = false
local cover_loading_path = nil
local ffi_loaded, ffi = pcall(require, "ffi")
if ffi_loaded then
    ffi.cdef [[
        struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
        int ioctl(int fd, unsigned long request, ...);
    ]]
end
local collected_lines = {}
local audio_exts = {}
for _, ext in ipairs(mp.get_property_native("audio-exts", {})) do
    audio_exts[ext] = true
end

local function is_audio(name)
    local ext = name:match("%.([^.]+)$")
    return ext ~= nil and audio_exts[ext:lower()] == true
end

local function sorted_names(dir, kind, keep)
    local names = {}
    for _, name in ipairs(utils.readdir(dir, kind) or {}) do
        if name:sub(1, 1) ~= "." and (not keep or keep(name)) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

local function list_entries(dir)
    local entries = {}
    if dir ~= root then
        entries[#entries + 1] = { label = "../", up = true }
    end
    for _, name in ipairs(sorted_names(dir, "dirs")) do
        entries[#entries + 1] = { label = name .. "/", path = utils.join_path(dir, name), is_dir = true }
    end
    for _, name in ipairs(sorted_names(dir, "files", is_audio)) do
        entries[#entries + 1] = { label = name, path = utils.join_path(dir, name) }
    end
    return entries
end

local function walk(dir, prefix, out)
    for _, name in ipairs(sorted_names(dir, "dirs")) do
        local path = utils.join_path(dir, name)
        local label = prefix .. name .. "/"
        out[#out + 1] = { label = label, name = name:lower(), path = path, is_dir = true }
        walk(path, label, out)
    end
    for _, name in ipairs(sorted_names(dir, "files", is_audio)) do
        out[#out + 1] = { label = prefix .. name, name = name:lower(), path = utils.join_path(dir, name) }
    end
    return out
end

local function search_entries(dir)
    if not walked or walked.dir ~= dir then
        walked = { dir = dir, entries = walk(dir, "", {}) }
    end
    local needle = query:lower()
    local found = {}
    for _, entry in ipairs(walked.entries) do
        if entry.name:find(needle, 1, true) then
            found[#found + 1] = entry
        end
    end
    return found
end

local function playing_index(path)
    if not path then
        return nil
    end
    local target = normalize(path)
    for index, entry in ipairs(shown) do
        if entry.path == target then
            return index
        end
    end
    for index, entry in ipairs(shown) do
        if entry.is_dir and target:sub(1, #entry.path + 1) == entry.path .. "/" then
            return index
        end
    end
    return nil
end

local function relative_path(path)
    local target = normalize(path)
    local prefix = root .. "/"
    if target:sub(1, #prefix) == prefix then
        return target:sub(#prefix + 1)
    end
    return select(2, utils.split_path(target))
end

local function char_count(text)
    return select(2, text:gsub("[^\128-\191]", ""))
end

local function shorten(path, width)
    if char_count(path) <= width then
        return path
    end
    local parts = {}
    for part in path:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    local name = parts[#parts]
    if #parts >= 3 then
        local middle = parts[1] .. "/.../" .. name
        if char_count(middle) <= width then
            return middle
        end
    end
    return #parts > 1 and ".../" .. name or path
end

local function centered(text, width, style)
    local pad = math.max(0, math.floor((width - char_count(text)) / 2))
    return string.rep(" ", pad) .. style .. text .. "\027[0m"
end

local function folder_row(width)
    local current = stack[#stack]
    local name = select(2, utils.split_path(root))
    local label = name
    if current ~= root then
        local offset = root:sub(-1) == "/" and #root + 1 or #root + 2
        label = name .. "/" .. current:sub(offset)
    end
    return shorten(label, width - 1) .. "/"
end

local function format_time(seconds)
    local total = math.floor(seconds)
    local hours = math.floor(total / 3600)
    local minutes = math.floor(total % 3600 / 60)
    local secs = total % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%d:%02d", minutes, secs)
end

local function time_text()
    local position = mp.get_property_number("time-pos", 0)
    local duration = mp.get_property_number("duration")
    drawn_second = math.floor(position)
    if duration then
        return format_time(position) .. " / " .. format_time(duration)
    end
    return format_time(position)
end

local function base64(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local i1, i2, i3, i4 = math.floor(n / 262144), math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64
        out[#out + 1] = base64_alphabet:sub(i1 + 1, i1 + 1)
            .. base64_alphabet:sub(i2 + 1, i2 + 1)
            .. (b and base64_alphabet:sub(i3 + 1, i3 + 1) or "=")
            .. (c and base64_alphabet:sub(i4 + 1, i4 + 1) or "=")
    end
    return table.concat(out)
end

local function remove_art_file()
    if art_file then
        os.remove(art_file)
        art_file = nil
    end
end

local function cell_pixels()
    if not ffi_loaded then
        return nil
    end
    local size = ffi.new("struct winsize[1]")
    local request = ffi.os == "OSX" and 0x40087468 or 0x5413
    local stdout_fd = 1
    local winsize = size[0]
    if ffi.C.ioctl(stdout_fd, request, size) ~= 0 or winsize.ws_col == 0 or winsize.ws_row == 0 then
        return nil
    end
    return winsize.ws_xpixel / winsize.ws_col, winsize.ws_ypixel / winsize.ws_row
end

local function art_column(width, art_rows)
    local image_width = mp.get_property_number("video-params/dw")
    local image_height = mp.get_property_number("video-params/dh")
    local cell_width, cell_height = cell_pixels()
    if not cell_width or not image_width or not image_height or cell_width == 0 or image_height == 0 then
        return 1
    end
    local columns = math.ceil(image_width * (art_rows * cell_height / image_height) / cell_width)
    return math.max(1, math.floor((width - columns) / 2) + 1)
end

local function art_commands(key, top, left, art_rows)
    local commands = {}
    if drawn_art_key then
        commands[#commands + 1] = delete_art
    end
    drawn_art_key = key
    if not key then
        remove_art_file()
        return commands
    end
    art_counter = art_counter + 1
    local file = utils.join_path(
        os.getenv("TMPDIR") or "/tmp",
        string.format("mpv-tui-browser-tty-graphics-protocol-%d-%d.png", utils.getpid(), art_counter))
    mp.commandv("screenshot-to-file", file, "video")
    if utils.file_info(file) then
        commands[#commands + 1] = string.format(
            "\027[%d;%dH\027_Ga=T,t=t,f=100,i=1,r=%d,C=1,q=2;%s\027\\",
            top, left, art_rows, base64(file))
    end
    remove_art_file()
    art_file = file
    return commands
end

local function render()
    local path = mp.get_property("path")
    local playing = playing_index(path)
    local height = mp.get_property_native("term-size/h", 24)
    local art_rows = height - math.floor(height / 2)
    local list_rows = height - art_rows - 6
    local has_art = path ~= nil and art_ready_path == path and list_rows >= 1
        and mp.get_property_number("video-params/dw") ~= nil
    local width = mp.get_property_native("term-size/w", 80)
    local rows = math.max(1, has_art and list_rows or height - 5)
    if focus < first then
        first = focus
    elseif focus > first + rows - 1 then
        first = focus - rows + 1
    end
    first = math.max(1, math.min(first, #shown - rows + 1))
    local lines = {
        centered("mpv-tui-browser", width, "\027[1m"),
        centered("Lightweight terminal file browser for mpv", width, "\027[38;5;8m"),
        "\027[4m" .. folder_row(width) .. "\027[0m",
    }
    for index = first, math.min(#shown, first + rows - 1) do
        local style = ""
        if index == playing then
            style = style .. "\027[1m"
        end
        if index == focus and selecting then
            style = style .. "\027[7m"
        end
        lines[#lines + 1] = style .. shown[index].label .. "\027[0m"
    end
    local cursor = "\027[7m \027[0m"
    lines[#lines + 1] = query == "" and cursor .. "\027[38;5;8mSearch music...\027[0m" or query .. cursor
    if path then
        local time = time_text()
        local budget = width - 5 - #time
        lines[#lines + 1] = "▶ " .. shorten(relative_path(path), budget) .. "  " .. time
    end
    local art_top = #lines + 2
    local art_left = has_art and art_column(width, art_rows) or 1
    local art_key = has_art and string.format("%s:%d:%d:%d", path, height, art_top, art_left) or nil
    local art = art_key ~= drawn_art_key and table.concat(art_commands(art_key, art_top, art_left, art_rows)) or ""
    io.write("\027[H", table.concat(lines, "\027[K\r\n"), "\027[K\027[J", art)
    io.flush()
end

local function reload(path)
    shown = query == "" and list_entries(stack[#stack]) or search_entries(stack[#stack])
    focus = query == "" and playing_index(path or mp.get_property("path")) or 1
    first = 1
end

local function refresh(path)
    reload(path)
    render()
end

local function play(path)
    local target = normalize(path)
    for index, entry in ipairs(mp.get_property_native("playlist", {})) do
        if normalize(entry.filename) == target then
            mp.commandv("playlist-play-index", index - 1)
            return
        end
    end
    local pos = mp.get_property_number("playlist-current-pos", -1)
    mp.commandv("loadfile", path, "insert-next")
    mp.commandv("playlist-play-index", pos + 1)
end

local function back_step()
    if query ~= "" then
        query = ""
        selecting = false
    elseif selecting then
        selecting = false
    elseif #stack > 1 then
        table.remove(stack)
    end
end

local function on_space()
    local entry = shown[focus]
    if not selecting or not entry or playing_index(mp.get_property("path")) == focus then
        mp.command("cycle pause")
        return
    end
    local target
    if entry.is_dir then
        for _, item in ipairs(walk(entry.path, "", {})) do
            if not item.is_dir then
                target = item.path
                break
            end
        end
    elseif not entry.up then
        target = entry.path
    end
    if target then
        play(target)
        refresh(target)
    end
end

local function on_text(info)
    if query == "" and info.key_text == " " then
        if info.event ~= "repeat" then
            on_space()
        end
        return
    end
    if info.key_text and (info.event == "press" or info.event == "down" or info.event == "repeat") then
        query = query .. info.key_text
        selecting = true
        refresh()
    end
end

local function on_backspace()
    query = (query:gsub("[^\128-\191][\128-\191]*$", ""))
    refresh()
end

local function on_submit()
    local entry = shown[focus]
    if not selecting or not entry then
        return
    end
    local played
    if entry.up then
        table.remove(stack)
    elseif entry.is_dir then
        for component in entry.label:gmatch("[^/]+") do
            stack[#stack + 1] = utils.join_path(stack[#stack], component)
        end
    else
        played = entry.path
        play(played)
    end
    query = ""
    refresh(played)
end

local function move_focus(step)
    if not selecting then
        selecting = true
        render()
    elseif #shown > 0 then
        focus = (focus - 1 + step) % #shown + 1
        render()
    end
end

mp.add_forced_key_binding("any_unicode", "browser-text", on_text, { repeatable = true, complex = true })
mp.add_forced_key_binding("bs", "browser-backspace", on_backspace, { repeatable = true })
mp.add_forced_key_binding("enter", "browser-enter", on_submit)
mp.add_forced_key_binding("kp_enter", "browser-kp-enter", on_submit)
mp.add_forced_key_binding("esc", "browser-esc", function()
    back_step()
    refresh()
end)
mp.add_forced_key_binding("ctrl+alt+3", "browser-double-esc", function()
    back_step()
    back_step()
    refresh()
end)
mp.add_forced_key_binding("up", "browser-up", function() move_focus(-1) end, { repeatable = true })
mp.add_forced_key_binding("down", "browser-down", function() move_focus(1) end, { repeatable = true })

local function curl(args, callback)
    local command = { curl_path, "-sS", "-f", "--max-time", "15", "-A", curl_agent }
    for _, arg in ipairs(args) do
        command[#command + 1] = arg
    end
    mp.command_native_async({
        name = "subprocess",
        args = command,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, result)
        local failed = not success or result.status ~= 0
        if failed and not (result and result.status == 22) then
            msg.warn(string.format("curl failed (%s): %s", tostring(result and result.status), result and (result.error_string ~= "" and result.error_string or (result.stderr:gsub("%s+$", ""))) or ""))
        end
        callback(not failed, result)
    end)
end

local function quoted_phrase(text)
    return '"' .. text:gsub('[\\"]', "\\%0") .. '"'
end

local function fetch_cover(artist, album, done)
    local query_text = string.format("releasegroup:%s AND artist:%s", quoted_phrase(album), quoted_phrase(artist))
    curl({
        "-G", "https://musicbrainz.org/ws/2/release-group/",
        "--data-urlencode", "query=" .. query_text,
        "-d", "fmt=json", "-d", "limit=1",
    }, function(found, result)
        local response = found and utils.parse_json(result.stdout)
        local group = response and response["release-groups"] and response["release-groups"][1]
        if not group or not group.id or (tonumber(group.score) or 0) < min_cover_score then
            done(nil)
            return
        end
        cover_counter = cover_counter + 1
        local file = utils.join_path(
            os.getenv("TMPDIR") or "/tmp",
            string.format("mpv-tui-browser-cover-%d-%d.jpg", utils.getpid(), cover_counter))
        cover_files[#cover_files + 1] = file
        curl({
            "-L", "-o", file,
            "https://coverartarchive.org/release-group/" .. group.id .. "/front-500",
        }, function(downloaded)
            done(downloaded and file or nil)
        end)
    end)
end

local function folder_cover_path()
    local path = mp.get_property("path")
    return path and utils.join_path((utils.split_path(path)), folder_cover_name)
end

local function save_folder_cover(file, target)
    local source = io.open(file, "rb")
    local data = source and source:read("*a")
    if source then
        source:close()
    end
    local out = data and data ~= "" and io.open(target, "wb")
    if not out then
        return
    end
    local written = out:write(data)
    local closed = out:close()
    if not (written and closed) then
        os.remove(target)
    end
end

local function ensure_cover()
    if not options.online_covers or not art_supported or mp.get_property_native("current-tracks/video") then
        return
    end
    local folder_cover = folder_cover_path()
    local folder_cover_exists = folder_cover ~= nil and utils.file_info(folder_cover) ~= nil
    if folder_cover_exists then
        cover_loading_path = mp.get_property("path")
        mp.commandv("video-add", folder_cover, "select", "", "", "yes")
        return
    end
    local artist = mp.get_property("metadata/by-key/Artist")
    local album = mp.get_property("metadata/by-key/Album")
    if not artist or not album then
        return
    end
    local key = artist .. "\0" .. album
    local cached = cover_cache[key]
    if cached then
        if folder_cover then
            save_folder_cover(cached, folder_cover)
        end
        cover_loading_path = mp.get_property("path")
        mp.commandv("video-add", cached, "select", "", "", "yes")
    elseif cached == nil and not cover_running then
        cover_running = true
        fetch_cover(artist, album, function(file)
            cover_running = false
            cover_cache[key] = file or false
            ensure_cover()
        end)
    end
end

local function remove_cover_files()
    for _, file in ipairs(cover_files) do
        os.remove(file)
    end
    cover_files = {}
end

mp.observe_property("path", "string", function(_, path)
    if path then
        if not path_seen then
            local info = utils.file_info(path)
            path_seen = not (info and info.is_dir)
            reload(path)
        end
        render()
    end
end)

mp.observe_property("time-pos", "number", function(_, position)
    if position and math.floor(position) ~= drawn_second then
        render()
    end
end)

mp.register_event("playback-restart", function()
    local path = mp.get_property("path")
    art_ready_path = art_supported and mp.get_property_native("current-tracks/video") ~= nil and path or nil
    render()
    ensure_cover()
end)

mp.register_event("video-reconfig", function()
    local path = mp.get_property("path")
    if cover_loading_path == path and mp.get_property_number("video-params/dw") then
        cover_loading_path = nil
        art_ready_path = path
        render()
    end
end)

mp.observe_property("duration", "number", function()
    render()
end)

mp.enable_messages("warn")

mp.register_event("log-message", function(e)
    if e.prefix == "ao/coreaudio" then
        return
    end
    if e.prefix == "cplayer" then
        collected_lines[#collected_lines + 1] = e.text
    else
        collected_lines[#collected_lines + 1] = "[" .. e.prefix .. "] " .. e.text
    end
end)

mp.register_event("shutdown", function()
    remove_art_file()
    remove_cover_files()
    io.write(art_supported and delete_art or "", "\027[?7h\027[?25h\027[?1049l", table.concat(collected_lines))
    io.flush()
end)

io.write("\027[?1049h\027[?25l\027[?7l")
refresh()
