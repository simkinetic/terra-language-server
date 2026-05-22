-- 1. A standard Lua function that acts as a macro.
-- It takes two Terra AST nodes and returns a new AST node (a quote).
local function multiply_macro(a, b)
    return `a * b
end

-- 2. A native Terra function
terra meta_test(x : int) : int
    var y = 10
    
    -- 3. The escape [ ... ] pauses the compiler, evaluates the Lua macro, 
    -- and injects the resulting quote directly into the Terra AST!
    return [ multiply_macro(x, y) ]
end