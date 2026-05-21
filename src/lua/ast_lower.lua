-- lua/ast_lower.lua
local ffi = require("ffi")
local ast = require("lua.ast")
local asdl = require("lua.asdl")
local types_module = require("lua.types")
local types = types_module.types
local T = ast.T

-- We pass the TS API in so this module doesn't rely on globals
local function create_lowerer(TS)

    local Visitor = {}
    local LowerAST
    
    local state = {
        diagnostics = {}
    }

    Visitor["ERROR"] = function(node, source)
        local start_byte = TS.node_start_byte(node)
        local end_byte = TS.node_end_byte(node)
        local bad_text = source:sub(start_byte + 1, end_byte)
        
        -- SAFE APPEND: Record the diagnostic for the Language Server
        state.diagnostics[#state.diagnostics + 1] = {
            message = "Syntax Error: Unexpected or malformed token '" .. bad_text .. "'",
            start_byte = start_byte,
            end_byte = end_byte
        }
        
        -- Return a dummy/empty AST node so the tree can keep building safely
        local anchor = ast.newanchor(1)
        return ast.newobject(anchor, T.block, asdl.List())
    end

    Visitor["number"] = function(node, source)
        local text = TS.get_node_text(node, source)
        return ast.newobject(ast.newanchor(1), T.literal, tonumber(text), types.int32)
    end

    Visitor["identifier"] = function(node, source)
        local text = TS.get_node_text(node, source)
        return ast.newobject(ast.newanchor(1), T.var, text)
    end

    Visitor["return_statement"] = function(node, source)
        local anchor = ast.newanchor(1)
        local expr_list_ast = asdl.List()
        local child_count = TS.node_child_count(node)
        for i = 0, child_count - 1 do
            local child = TS.node_child(node, i)
            if TS.safe_node_type(child) == "expression_list" then
                local exp_count = TS.node_child_count(child)
                for j = 0, exp_count - 1 do
                    local exp_child = TS.node_child(child, j)
                    local exp_type = TS.safe_node_type(exp_child)
                    if exp_type == "identifier" or exp_type == "number" then
                        local exp_ast = LowerAST(exp_child, source)
                        if exp_ast then expr_list_ast:insert(exp_ast) end
                    end
                end
            end
        end
        local let_in_expr = ast.newobject(anchor, T.letin, asdl.List(), expr_list_ast, false)
        return ast.newobject(anchor, T.returnstat, let_in_expr)
    end

    Visitor["terra_var_definition"] = function(node, source)
        local decl_node = TS.node_child(node, 0)
        local value_node = TS.node_child(node, 2)
        local name_node = TS.node_child_by_field_name(decl_node, "name", 4)
        local type_node = TS.node_child_by_field_name(decl_node, "type", 4)

        local name_text = TS.get_node_text(name_node, source)
        local anchor = ast.newanchor(1)
        local var_name_param

        if not ffi.C.ts_node_is_null(type_node) then
            local type_fn = function()
                local type_text = TS.get_node_text(type_node, source)
                local std_types = { ["int"] = types.int32, ["double"] = types.double, ["bool"] = types.bool, ["float"] = types.float }
                local res = std_types[type_text] or types[type_text]
                if not res then 
                    -- SAFE APPEND: Safely report the missing type instead of crashing!
                    state.diagnostics[#state.diagnostics + 1] = {
                        message = "Unknown type: '" .. type_text .. "'",
                        start_byte = TS.node_start_byte(type_node),
                        end_byte = TS.node_end_byte(type_node)
                    }
                    return types.error or types.niltype
                end
                return res
            end
            local type_ast = ast.newobject(anchor, T.luaexpression, type_fn, true)
            var_name_param = ast.newobject(anchor, T.unevaluatedparam, T.namedident(name_text), type_ast)
        else
            var_name_param = ast.newobject(anchor, T.unevaluatedparam, T.namedident(name_text))
        end

        local vars_list = asdl.List()
        vars_list:insert(var_name_param)

        local init_list = asdl.List()
        local hasinit = false
        if not ffi.C.ts_node_is_null(value_node) then
            local var_value = LowerAST(value_node, source)
            if var_value then
                init_list:insert(var_value)
                hasinit = true
            end
        end
        return ast.newobject(anchor, T.defvar, vars_list, hasinit, init_list)
    end

    Visitor["terra_function_implementation"] = function(node, source)
        local anchor = ast.newanchor(1)
        local statements = asdl.List()
        local params_list = asdl.List()
        local return_type_ast = nil

        local body_node = TS.node_child_by_field_name(node, "body", 4)
        if not ffi.C.ts_node_is_null(body_node) then
            local child_count = TS.node_child_count(body_node)
            for i = 0, child_count - 1 do
                local child = TS.node_child(body_node, i)
                local stmt_ast = LowerAST(child, source)
                if stmt_ast then statements:insert(stmt_ast) end
            end
        end
        local body_block = ast.newobject(anchor, T.block, statements)

        local function resolve_type(type_node)
            local type_text = TS.get_node_text(type_node, source)
            local std_types = { ["int"] = types.int32, ["double"] = types.double, ["bool"] = types.bool, ["float"] = types.float }
            local res = std_types[type_text] or types[type_text]
            if not res then 
                -- SAFE APPEND
                state.diagnostics[#state.diagnostics + 1] = {
                    message = "Unknown function signature type: '" .. type_text .. "'",
                    start_byte = TS.node_start_byte(type_node),
                    end_byte = TS.node_end_byte(type_node)
                }
                return types.error or types.niltype
            end
            return res
        end

        local params_node = TS.node_child_by_field_name(node, "parameters", 10)
        if not ffi.C.ts_node_is_null(params_node) then
            local identifiers = {}
            local param_child_count = TS.node_child_count(params_node)

            for i = 0, param_child_count - 1 do
                local child = TS.node_child(params_node, i)
                local child_type = TS.safe_node_type(child)
                -- We want to capture identifiers OR missing nodes
                if child_type == "identifier" or child_type == "ERROR" then
                    -- SAFE APPEND
                    identifiers[#identifiers + 1] = child 
                end
            end

            local num_params = #identifiers
            if num_params % 2 ~= 0 then
                local ret_type_node = identifiers[num_params]
                return_type_ast = resolve_type(ret_type_node)
                num_params = num_params - 1
            end

            for i = 1, num_params, 2 do
                local param_name_node = identifiers[i]
                local param_type_node = identifiers[i+1]
                
                local param_name = TS.get_node_text(param_name_node, source)
                local resolved_type = resolve_type(param_type_node)
                
                local sym = ast.newsymbol and ast.newsymbol(resolved_type, param_name) or T.symbol(resolved_type, param_name)
                local param_ast = ast.newobject(anchor, T.concreteparam, resolved_type, param_name, sym, true)
                params_list:insert(param_ast)
            end
        end

        return ast.newobject(anchor, T.functiondefu, params_list, false, return_type_ast, body_block)
    end

    LowerAST = function(node, source)
        local node_type = ffi.string(TS.node_type(node))
        local visitor_fn = Visitor[node_type]
        if visitor_fn then
            return visitor_fn(node, source)
        else
            print("[Warning] No visitor defined for node type: " .. node_type)
            return nil
        end
    end

    -- Return a clear interface
    return {
        lower = LowerAST,
        get_diagnostics = function() return state.diagnostics end,
        clear_diagnostics = function() state.diagnostics = {} end
    }
end

return { create = create_lowerer }