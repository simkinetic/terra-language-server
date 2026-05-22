-- lua/diagnostics.lua
local asdl = require("lua.asdl")
local List = asdl.List

local diagnostics = {}
diagnostics.__index = diagnostics

-- Weak table to cache file reads across error reports
local diagcache = setmetatable({}, { __mode = "v" })

local function formaterror(anchor, ...)
    if not anchor or not anchor.filename or not anchor.linenumber then
        error("nil anchor")
    end
    local errlist = List()
    errlist:insert(anchor.filename .. ":" .. anchor.linenumber .. ": ")
    
    -- Natively concatenate all varargs
    for i = 1, select("#", ...) do 
        errlist:insert(tostring(select(i, ...))) 
    end
    errlist:insert("\n")
    
    if not anchor.offset then 
        return errlist:concat()
    end
    
    local filename = anchor.filename
    local filetext = diagcache[filename] 
    if not filetext then
        local file = io.open(filename, "r")
        if file then
            filetext = file:read("*all")
            diagcache[filename] = filetext
            file:close()
        end
    end
    
    if filetext then
        local begin, finish = anchor.offset + 1, anchor.offset + 1
        local TAB, NL = ("\t"):byte(), ("\n"):byte()
        
        while begin > 1 and filetext:byte(begin) ~= NL do
            begin = begin - 1
        end
        if begin > 1 then
            begin = begin + 1
        end
        while finish < filetext:len() and filetext:byte(finish + 1) ~= NL do
            finish = finish + 1
        end
        
        local line = filetext:sub(begin, finish) 
        errlist:insert(line)
        errlist:insert("\n")
        
        for i = begin, anchor.offset do
            errlist:insert((filetext:byte(i) == TAB and "\t") or " ")
        end
        errlist:insert("^\n")
    end
    
    return errlist:concat()
end

local function erroratlocation(anchor, ...)
    error(formaterror(anchor, ...), 0)
end

function diagnostics:reporterror(anchor, ...)
    -- 1. Safely extract the raw message without file context for the LSP
    local raw_msg_parts = {}
    for i = 1, select('#', ...) do
        table.insert(raw_msg_parts, tostring(select(i, ...)))
    end
    local raw_msg = table.concat(raw_msg_parts)

    -- 2. Create a secret structured list for our LSP
    table.insert(self.lsp_errors, {
        anchor = anchor,
        message = raw_msg
    })

    -- 3. Give Terra exactly what it expects (the fully formatted file snippet)
    local full_formatted_error = formaterror(anchor, ...)
    self.errors:insert(full_formatted_error)

    -- Return the abort closure so the typechecker can halt safely
    return { 
        aserror = function() error(full_formatted_error, 0) end 
    }
end

function diagnostics:haserrors()
    return #self.errors > 0
end

function diagnostics:finishandabortiferrors(msg, depth)
    if #self.errors > 0 then
        error(msg .. "\n" .. self.errors:concat(), (depth or 1) + 1)
    end
end

local function newdiagnostics()
    -- Initialize BOTH the native list and the LSP tracking table
    return setmetatable({ errors = List(), lsp_errors = {} }, diagnostics)
end

return {
    diagnostics = diagnostics,
    newdiagnostics = newdiagnostics,
    erroratlocation = erroratlocation,
    formaterror = formaterror
}