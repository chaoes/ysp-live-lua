-- Minimal pure Lua JSON parser / encoder (Public Domain / MIT)
local json = {}

local function kind_of(obj)
    if type(obj) ~= "table" then return type(obj) end
    local i = 1
    for _ in pairs(obj) do
        if obj[i] ~= nil then i = i + 1 else return "table" end
    end
    if i == 1 then return "table" else return "array" end
end

local function escape_str(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    s = s:gsub('\b', '\\b')
    s = s:gsub('\f', '\\f')
    return s
end

function json.encode(val)
    local kind = kind_of(val)
    if kind == "array" then
        local parts = {}
        for _, v in ipairs(val) do table.insert(parts, json.encode(v)) end
        return "[" .. table.concat(parts, ",") .. "]"
    elseif kind == "table" then
        local parts = {}
        for k, v in pairs(val) do
            table.insert(parts, '"' .. escape_str(tostring(k)) .. '":' .. json.encode(v))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif kind == "string" then
        return '"' .. escape_str(val) .. '"'
    elseif kind == "number" or kind == "boolean" then
        return tostring(val)
    end
    return "null"
end

local function utf8_char(cp)
    if cp < 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff) then
        error("invalid Unicode scalar value", 0)
    end
    if cp < 128 then
        return string.char(cp)
    elseif cp < 2048 then
        return string.char(192 + math.floor(cp / 64), 128 + (cp % 64))
    elseif cp < 65536 then
        return string.char(224 + math.floor(cp / 4096), 128 + (math.floor(cp / 64) % 64), 128 + (cp % 64))
    else
        return string.char(240 + math.floor(cp / 262144), 128 + (math.floor(cp / 4096) % 64), 128 + (math.floor(cp / 64) % 64), 128 + (cp % 64))
    end
end

local function json_error(pos, message)
    error("JSON decode error at byte " .. tostring(pos) .. ": " .. message, 0)
end

-- Decode strings in one pass so a backslash produced by one replacement can
-- never be interpreted again as a second escape.
local function parse_string(str, quote_idx)
    local out, chunk_start = {}, quote_idx + 1
    local i = quote_idx + 1
    while i <= #str do
        local byte = str:byte(i)
        if byte == 34 then
            out[#out + 1] = str:sub(chunk_start, i - 1)
            return table.concat(out), i + 1
        elseif byte == 92 then
            out[#out + 1] = str:sub(chunk_start, i - 1)
            local esc = str:sub(i + 1, i + 1)
            local simple = {
                ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
            }
            if simple[esc] then
                out[#out + 1] = simple[esc]
                i = i + 2
            elseif esc == "u" then
                local hex = str:sub(i + 2, i + 5)
                if #hex ~= 4 or not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
                    json_error(i, "invalid Unicode escape")
                end
                local cp = tonumber(hex, 16)
                i = i + 6
                if cp >= 0xd800 and cp <= 0xdbff then
                    if str:sub(i, i + 1) ~= "\\u" then json_error(i, "high surrogate without low surrogate") end
                    local low_hex = str:sub(i + 2, i + 5)
                    if #low_hex ~= 4 or not low_hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
                        json_error(i, "invalid low surrogate escape")
                    end
                    local low = tonumber(low_hex, 16)
                    if low < 0xdc00 or low > 0xdfff then json_error(i, "invalid low surrogate") end
                    cp = 0x10000 + (cp - 0xd800) * 0x400 + (low - 0xdc00)
                    i = i + 6
                elseif cp >= 0xdc00 and cp <= 0xdfff then
                    json_error(i - 6, "low surrogate without high surrogate")
                end
                out[#out + 1] = utf8_char(cp)
            else
                json_error(i, "invalid string escape")
            end
            chunk_start = i
        elseif byte < 32 then
            json_error(i, "unescaped control character in string")
        else
            i = i + 1
        end
    end
    json_error(quote_idx, "unterminated string")
end

local function parse_val(str, idx)
    idx = str:find("%S", idx) or idx
    local char = str:sub(idx, idx)

    if char == "{" then
        local obj = {}
        idx = idx + 1
        while true do
            idx = str:find("%S", idx) or idx
            if str:sub(idx, idx) == "}" then return obj, idx + 1 end
            local key, next_idx = parse_val(str, idx)
            idx = str:find(":", next_idx) + 1
            local val, after_val = parse_val(str, idx)
            obj[key] = val
            idx = str:find("%S", after_val) or after_val
            if str:sub(idx, idx) == "," then
                idx = idx + 1
            elseif str:sub(idx, idx) == "}" then
                return obj, idx + 1
            else
                break
            end
        end
        return obj, idx
    elseif char == "[" then
        local arr = {}
        idx = idx + 1
        while true do
            idx = str:find("%S", idx) or idx
            if str:sub(idx, idx) == "]" then return arr, idx + 1 end
            local val, next_idx = parse_val(str, idx)
            table.insert(arr, val)
            idx = str:find("%S", next_idx) or next_idx
            if str:sub(idx, idx) == "," then
                idx = idx + 1
            elseif str:sub(idx, idx) == "]" then
                return arr, idx + 1
            else
                break
            end
        end
        return arr, idx
    elseif char == '"' then
        return parse_string(str, idx)
        --[[ Previous multi-pass gsub decoder retained here only in history;
        the active branch above is intentionally a single-pass scan.
        local end_idx = idx + 1
        while true do
            end_idx = str:find('"', end_idx)
            if not end_idx then return "", #str + 1 end
            local backslashes = 0
            local b = end_idx - 1
            while b >= idx and str:sub(b, b) == "\\" do
                backslashes = backslashes + 1
                b = b - 1
            end
            if backslashes % 2 == 0 then break end
            end_idx = end_idx + 1
        end
        local raw = str:sub(idx + 1, end_idx - 1)
        -- Handle unicode \uXXXX
        raw = raw:gsub('\\u([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])', function(hex)
            return utf8_char(tonumber(hex, 16))
        end)
        -- Standard unescape
        raw = raw:gsub('\\/', '/')
                 :gsub('\\"', '"')
                 :gsub('\\\\', '\\')
                 :gsub('\\n', '\n')
                 :gsub('\\r', '\r')
                 :gsub('\\t', '\t')
                 :gsub('\\b', '\b')
                 :gsub('\\f', '\f')
        return raw, end_idx + 1
        ]]
    elseif str:sub(idx, idx + 3) == "true" then
        return true, idx + 4
    elseif str:sub(idx, idx + 4) == "false" then
        return false, idx + 5
    elseif str:sub(idx, idx + 3) == "null" then
        return nil, idx + 4
    else
        local num_str = str:match("^[%-%d%.eE+]+", idx)
        if num_str then
            return tonumber(num_str), idx + #num_str
        end
        json_error(idx, "unexpected token")
    end
end

function json.decode(str)
    if not str or #str == 0 then return nil, "JSON decode error at byte 1: empty input" end
    local ok, res, next_idx = pcall(parse_val, str, 1)
    if not ok then return nil, tostring(res) end
    local trailing = str:find("%S", next_idx) or (#str + 1)
    if trailing <= #str then return nil, "JSON decode error at byte " .. trailing .. ": trailing data" end
    return res
end

return json
