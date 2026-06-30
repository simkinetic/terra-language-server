-- lua/diagnostics.lua
local asdl = require("compiler.semantics.asdl")
local List = asdl.List

local diagnostics = {}
diagnostics.__index = diagnostics

-- LSP State
diagnostics.is_lsp_mode = false
diagnostics.lsp_diagnostics_buffer = {}

-- Weak table to cache file reads across error reports
local diagcache = setmetatable({}, { __mode = "v" })

local function formaterror(anchor, ...)
    if not anchor or not anchor.filename or not anchor.linenumber then
        error("nil anchor")
    end
    local errlist = List()
    errlist:insert(anchor.filename .. ":" .. anchor.linenumber .. ": ")
    
    for i = 1, select("#", ...) do 
        -- Wrapped select in extra () to drop multiple returns and silence warnings
        errlist:insert(tostring((select(i, ...)))) 
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
    local raw_msg_parts = {}
    for i = 1, select('#', ...) do
        -- Wrapped select in extra () to silence warnings
        table.insert(raw_msg_parts, tostring((select(i, ...))))
    end
    
    table.insert(diagnostics.lsp_diagnostics_buffer, {
        anchor = anchor,
        message = table.concat(raw_msg_parts)
    })

    local full_formatted_error = formaterror(anchor, ...)
    self.errors:insert(full_formatted_error)

    return { 
        aserror = function() 
            if not diagnostics.is_lsp_mode then
                error(full_formatted_error, 0) 
            end
        end 
    }
end

function diagnostics:haserrors()
    return #self.errors > 0
end

function diagnostics:finishandabortiferrors(msg, depth)
    if #self.errors > 0 then
        if diagnostics.is_lsp_mode then
            return false
        else
            error(msg .. "\n" .. self.errors:concat(), (depth or 1) + 1)
        end
    end
    return true
end

local function newdiagnostics()
    return setmetatable({ errors = List() }, diagnostics)
end

local function set_lsp_mode(enable)
    diagnostics.is_lsp_mode = enable
end

local function pop_lsp_errors()
    local errs = diagnostics.lsp_diagnostics_buffer
    diagnostics.lsp_diagnostics_buffer = {}
    return errs
end

-- ==========================================
-- EXPORT
-- ==========================================
return {
    diagnostics = diagnostics,
    newdiagnostics = newdiagnostics,
    erroratlocation = erroratlocation,
    formaterror = formaterror,
    set_lsp_mode = set_lsp_mode,
    pop_lsp_errors = pop_lsp_errors
}