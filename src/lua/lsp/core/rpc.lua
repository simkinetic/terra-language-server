-- src/lua/lsp/core/rpc.lua
local uv = require("luv")
local json = require("compiler.utils.json")

local rpc = {}

-- 0 = stdin, 1 = stdout
local stdin = uv.new_pipe(false)
local stdout = uv.new_pipe(false)

uv.pipe_open(stdin, 0)
uv.pipe_open(stdout, 1)

local buffer = ""

function rpc.start(on_message)
    uv.read_start(stdin, function(err, data)
        if err then
            -- We must log to stderr! Printing to stdout corrupts the LSP stream.
            io.stderr:write("[RPC] Read Error: " .. tostring(err) .. "\n")
            return
        end
        
        if data then
            buffer = buffer .. data
            
            while true do
                -- Find the HTTP header boundary (LSP spec uses \r\n\r\n, terminal uses \n\n)
                local header_start, header_end = buffer:find("\r\n\r\n", 1, true)
                if not header_start then
                    header_start, header_end = buffer:find("\n\n", 1, true)
                end

                if not header_start then break end
                
                local header = buffer:sub(1, header_start - 1)
                local content_length_match = header:match("Content%-Length: (%d+)")
                
                if not content_length_match then
                    io.stderr:write("[RPC] Error: Missing Content-Length header\n")
                    buffer = "" 
                    break
                end
                
                local content_length = tonumber(content_length_match)
                
                -- Do we have the full JSON payload yet?
                if #buffer < header_end + content_length then
                    break 
                end
                
                -- Extract the payload and advance the buffer
                local payload = buffer:sub(header_end + 1, header_end + content_length)
                buffer = buffer:sub(header_end + content_length + 1)
                
                -- Decode and dispatch
                local ok, msg = pcall(json.decode, payload)
                if ok and msg then
                    on_message(msg)
                else
                    io.stderr:write("[RPC] JSON Decode Error: " .. tostring(msg) .. "\n")
                end
            end
        else
            -- EOF (Editor closed the process)
            uv.read_stop(stdin)
            os.exit(0)
        end
    end)
end

function rpc.send(msg)
    local payload = json.encode(msg)
    local data = "Content-Length: " .. tostring(#payload) .. "\r\n\r\n" .. payload
    uv.write(stdout, data)
end

return rpc