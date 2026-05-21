local asdl = require("lua.asdl")
local List = asdl.List

local diagnostics = {}
diagnostics.__index = diagnostics

local diagcache = setmetatable({},{ __mode = "v" })

local function formaterror(anchor,...)
    if not anchor or not anchor.filename or not anchor.linenumber then
        error("nil anchor")
    end
    local errlist = List()
    errlist:insert(anchor.filename..":"..anchor.linenumber..": ")
    for i = 1,select("#",...) do errlist:insert(tostring(select(i,...))) end
    errlist:insert("\n")
    if not anchor.offset then 
        return errlist:concat()
    end
    
    local filename = anchor.filename
    local filetext = diagcache[filename] 
    if not filetext then
        local file = io.open(filename,"r")
        if file then
            filetext = file:read("*all")
            diagcache[filename] = filetext
            file:close()
        end
    end
    if filetext then --if the code did not come from a file then we don't print the carrot, since we cannot (easily) find the text
        local begin,finish = anchor.offset + 1,anchor.offset + 1
        local TAB,NL = ("\t"):byte(),("\n"):byte()
        while begin > 1 and filetext:byte(begin) ~= NL do
            begin = begin - 1
        end
        if begin > 1 then
            begin = begin + 1
        end
        while finish < filetext:len() and filetext:byte(finish + 1) ~= NL do
            finish = finish + 1
        end
        local line = filetext:sub(begin,finish) 
        errlist:insert(line)
        errlist:insert("\n")
        for i = begin,anchor.offset do
            errlist:insert((filetext:byte(i) == TAB and "\t") or " ")
        end
        errlist:insert("^\n")
    end
    return errlist:concat()
end

local function erroratlocation(anchor,...)
    error(formaterror(anchor,...),0)
end

diagnostics.source = {}

function diagnostics:reporterror(anchor, msg, ...)
    local formatted_msg = msg
    if select('#', ...) > 0 then
        formatted_msg = string.format(msg, ...)
    end

    -- 1. Create a secret structured list for our LSP
    self.lsp_errors = self.lsp_errors or {}
    table.insert(self.lsp_errors, {
        anchor = anchor,
        message = formatted_msg
    })

    -- 2. Give Terra exactly what it expects so table.concat() doesn't crash
    table.insert(self.errors, formatted_msg)

    -- Return the abort closure so the typechecker can halt safely
    return { 
        aserror = function() error(formatted_msg, 0) end 
    }
end

function diagnostics:haserrors()
    return #self.errors > 0
end

function diagnostics:finishandabortiferrors(msg,depth)
    if #self.errors > 0 then
        error(msg.."\n"..self.errors:concat(),depth+1)
    end
end

local function newdiagnostics()
    return setmetatable({ errors = List() }, diagnostics)
end

return {
    diagnostics = diagnostics,
    newdiagnostics = newdiagnostics,
    erroratlocation = erroratlocation,
    formaterror = formaterror
}