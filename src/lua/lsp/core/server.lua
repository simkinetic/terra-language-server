-- src/lua/lsp/core/server.lua
local uv = require("luv")
local rpc = require("lsp.core.rpc")

local server = {}
local handlers = {}

-- 1. The Handshake (Tells VS Code what we support)
handlers["initialize"] = function(msg)
    rpc.send({
        jsonrpc = "2.0",
        id = msg.id,
        result = {
            capabilities = {
                textDocumentSync = 1, -- 1 = Full Sync (Send us the whole file on change)
                hoverProvider = true
                -- We will add diagnostics and definitions here later!
            },
            serverInfo = {
                name = "TerraLS",
                version = "0.1.0"
            }
        }
    })
    io.stderr:write("[LSP] Server Initialized!\n")
end

-- 2. Editor confirms handshake is complete
handlers["initialized"] = function(msg)
    io.stderr:write("[LSP] Handshake Complete.\n")
end

-- 3. Editor is closing
handlers["shutdown"] = function(msg)
    rpc.send({ jsonrpc = "2.0", id = msg.id, result = nil })
    io.stderr:write("[LSP] Shutting down...\n")
end

handlers["exit"] = function(msg)
    os.exit(0)
end

-- The main router
local function on_message(msg)
    if not msg.method then return end
    
    local handler = handlers[msg.method]
    if handler then
        handler(msg)
    else
        io.stderr:write("[LSP] Unhandled method: " .. msg.method .. "\n")
    end
end

function server.start()
    io.stderr:write("[LSP] Booting Event Loop...\n")
    rpc.start(on_message)
    
    -- Enter the libuv event loop. This blocks forever.
    uv.run("default") 
end

return server