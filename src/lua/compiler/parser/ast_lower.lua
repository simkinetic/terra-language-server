-- lua/ast_lower.lua
local ffi = require("ffi")
local ast = require("compiler.semantics.ast")
local asdl = require("compiler.semantics.asdl")
local types = require("compiler.semantics.types")
local T = ast.T

-- We pass the TS API in so this module doesn't rely on globals
local function create_lowerer(TS, filename)

    local Visitor = {}
    local LowerAST
    
    local state = {
        diagnostics = {}
    }

    local function create_anchor(node)
        if not node or ffi.C.ts_node_is_null(node) then
            -- FIXED: Return the actual anchor instead of infinite recursion
            return ast.newanchor(1, 1, filename)
        end
        local point = ffi.C.ts_node_start_point(node)
        -- Tree-sitter is 0-indexed. DWARF/MLIR/LSP is 1-indexed!
        return ast.newanchor(point.row + 1, point.column + 1, filename)
    end

    -- ==========================================
    -- 1. ERROR HANDLING
    -- ==========================================
    Visitor["ERROR"] = function(node, source)
        local start_byte = TS.node_start_byte(node)
        local end_byte = TS.node_end_byte(node)
        local bad_text = ffi.string(TS.get_node_text(node, source))
        
        -- SAFE APPEND: Record the diagnostic for the Language Server
        state.diagnostics[#state.diagnostics + 1] = {
            message = "Syntax Error: Unexpected or malformed token '" .. bad_text .. "'",
            start_byte = start_byte,
            end_byte = end_byte
        }
        
        -- Return a dummy/empty AST node so the tree can keep building safely
        local anchor = create_anchor(node)
        return ast.newobject(anchor, T.block, asdl.List())
    end

    -- ==========================================
    -- 2. PRIMITIVES & IDENTIFIERS
    -- ==========================================
    Visitor["number"] = function(node, source)
        local text = ffi.string(TS.get_node_text(node, source))
        return ast.newobject(create_anchor(node), T.literal, tonumber(text), types.int32)
    end

    Visitor["identifier"] = function(node, source)
        local text = ffi.string(TS.get_node_text(node, source))
        return ast.newobject(create_anchor(node), T.var, text)
    end

    -- ==========================================
    -- 3. EXPRESSIONS & CALLS
    -- ==========================================
    Visitor["binary_expression"] = function(node, source)
        local left_node = TS.node_child_by_field_name(node, "left", 4)
        local right_node = TS.node_child_by_field_name(node, "right", 5)
        
        -- The operator (+, -, *, /) is always the middle child (index 1)
        local op_node = TS.node_child(node, 1)
        local op_text = ffi.string(TS.get_node_text(op_node, source))
        
        local left_ast = LowerAST(left_node, source)
        local right_ast = LowerAST(right_node, source)
        
        -- Terra's operator schema expects a single ASDL List of operands
        local operands = asdl.List()
        if left_ast then operands:insert(left_ast) end
        if right_ast then operands:insert(right_ast) end
        
        return ast.newobject(create_anchor(node), T.operator, op_text, operands)
    end

    Visitor["function_call"] = function(node, source)
        local anchor = create_anchor(node)
        
        -- Safely extract the callee
        local name_node = TS.node_child_by_field_name(node, "name", 4)
        if ffi.C.ts_node_is_null(name_node) then
            name_node = TS.node_child_by_field_name(node, "function", 8)
        end
        if ffi.C.ts_node_is_null(name_node) then
            name_node = TS.node_child(node, 0) -- Brute force first child
        end
        
        local fn_ast = LowerAST(name_node, source)
        local args_list = asdl.List()
        local args_node = TS.node_child_by_field_name(node, "arguments", 9)
        
        -- Extract the arguments
        if not ffi.C.ts_node_is_null(args_node) then
            local count = TS.node_child_count(args_node)
            for i = 0, count - 1 do
                local child = TS.node_child(args_node, i)
                if ffi.C.ts_node_is_named(child) then
                    local arg_ast = LowerAST(child, source)
                    if arg_ast then 
                        args_list:insert(arg_ast)
                    end
                end
            end
        end
        
        return ast.newobject(anchor, T.apply, fn_ast, args_list)
    end

    Visitor["member_expression"] = function(node, source)
        local anchor = create_anchor(node)

        -- Grab the object/table being accessed (e.g., 'p')
        local object_node = TS.node_child_by_field_name(node, "object", 6)
        if ffi.C.ts_node_is_null(object_node) then
            object_node = TS.node_child_by_field_name(node, "table", 5)
        end
        if ffi.C.ts_node_is_null(object_node) then
            for i = 0, TS.node_child_count(node) - 1 do
                local child = TS.node_child(node, i)
                if ffi.C.ts_node_is_named(child) then
                    object_node = child
                    break
                end
            end
        end

        local value_ast = LowerAST(object_node, source)

        -- Grab the field/property name (e.g., 'x')
        local property_node = TS.node_child_by_field_name(node, "property", 8)
        if ffi.C.ts_node_is_null(property_node) then
            property_node = TS.node_child_by_field_name(node, "field", 5)
        end
        if ffi.C.ts_node_is_null(property_node) then
            local last_named = nil
            for i = 0, TS.node_child_count(node) - 1 do
                local child = TS.node_child(node, i)
                if ffi.C.ts_node_is_named(child) then last_named = child end
            end
            property_node = last_named
        end

        local field_name = ffi.string(TS.get_node_text(property_node, source))

        -- Construct the selectu node exactly as Terra expects
        local named_ident = ast.newobject(anchor, T.namedident, field_name)
        return ast.newobject(anchor, T.selectu, value_ast, named_ident)
    end
    
    -- Alias for field access (p.x)
    Visitor["dot_index_expression"] = Visitor["member_expression"]

    -- ==========================================
    -- 4. VARIABLES & ASSIGNMENT
    -- ==========================================
    Visitor["terra_var_definition"] = function(node, source)
        local anchor = create_anchor(node)
        local decl_node = nil
        local value_node = nil
        
        -- Dynamically find the declaration and the assigned value
        for i = 0, TS.node_child_count(node) - 1 do
            local child = TS.node_child(node, i)
            if ffi.C.ts_node_is_named(child) then
                local tname = TS.safe_node_type(child)
                if tname == "terra_declaration" then
                    decl_node = child
                elseif decl_node then 
                    value_node = child
                end
            end
        end
        
        if not decl_node then return nil end

        -- Safely extract the variable name
        local name_node = TS.node_child_by_field_name(decl_node, "name", 4)
        local type_node = TS.node_child_by_field_name(decl_node, "type", 4)

        if ffi.C.ts_node_is_null(name_node) then
            for i = 0, TS.node_child_count(decl_node) - 1 do
                local child = TS.node_child(decl_node, i)
                if TS.safe_node_type(child) == "identifier" then
                    name_node = child
                    break
                end
            end
        end

        if ffi.C.ts_node_is_null(name_node) then return nil end 

        local name_text = ffi.string(TS.get_node_text(name_node, source))
        
        -- Resolve the Type (if provided)
        local var_name_param
        if not ffi.C.ts_node_is_null(type_node) then
            local type_fn = function()
                local type_text = ffi.string(TS.get_node_text(type_node, source))
                local std_types = { ["int"] = types.int32, ["double"] = types.double, ["bool"] = types.bool, ["float"] = types.float }
                
                local res = std_types[type_text] or types[type_text] or (_G.CURRENT_ENV and _G.CURRENT_ENV[type_text])
                if not res then return types.error or types.niltype end
                return res
            end
            local type_ast = ast.newobject(anchor, T.luaexpression, type_fn, true)
            var_name_param = ast.newobject(anchor, T.unevaluatedparam, T.namedident(name_text), type_ast)
        else
            -- Untyped variable (e.g., var x = ...)
            var_name_param = ast.newobject(anchor, T.unevaluatedparam, T.namedident(name_text))
        end

        local vars_list = asdl.List()
        vars_list:insert(var_name_param)

        -- Process the Initializer (if provided)
        local init_list = asdl.List()
        local hasinit = false
        if value_node then
            local var_value = LowerAST(value_node, source)
            if var_value then
                init_list:insert(var_value)
                hasinit = true
            end
        end
        
        return ast.newobject(anchor, T.defvar, vars_list, hasinit, init_list)
    end

    Visitor["terra_declaration"] = function(node, source)
        local anchor = create_anchor(node)
        local variables = asdl.List()
        local initializers = asdl.List()
        local hasinit = false

        -- Extract Variable Name (e.g., 'p')
        local name_node = TS.node_child_by_field_name(node, "name", 4)
        if ffi.C.ts_node_is_null(name_node) then
            for i = 0, TS.node_child_count(node) - 1 do
                local child = TS.node_child(node, i)
                if TS.safe_node_type(child) == "identifier" then
                    name_node = child
                    break
                end
            end
        end
        local var_name = ffi.string(TS.get_node_text(name_node, source))

        -- Extract Type (e.g., 'Point')
        local type_node = TS.node_child_by_field_name(node, "type", 4)
        local type_expr = nil
        if not ffi.C.ts_node_is_null(type_node) then
            local type_name = ffi.string(TS.get_node_text(type_node, source))
            
            local type_resolver = function() 
                return (_G.CURRENT_ENV and _G.CURRENT_ENV[type_name]) or types[type_name] 
            end
            type_expr = ast.newobject(anchor, T.luaexpression, type_resolver, true)
        end

        -- Extract Initializer (e.g., '= 10.5')
        local value_node = TS.node_child_by_field_name(node, "value", 5)
        if not ffi.C.ts_node_is_null(value_node) then
            hasinit = true
            initializers:insert(LowerAST(value_node, source))
        end

        -- Construct Terra's exact defvar node
        local named_ident = ast.newobject(anchor, T.namedident, var_name)
        local param = ast.newobject(anchor, T.unevaluatedparam, named_ident, type_expr)
        variables:insert(param)

        return ast.newobject(anchor, T.defvar, variables, hasinit, initializers)
    end

    Visitor["assignment_statement"] = function(node, source)
        local anchor = create_anchor(node)
        local lhs = asdl.List()
        local rhs = asdl.List()

        -- Grab the Left-Hand Side
        local var_list_node = TS.node_child_by_field_name(node, "variable_list", 13)
        if ffi.C.ts_node_is_null(var_list_node) then
            var_list_node = TS.node_child_by_field_name(node, "left", 4)
        end

        if not ffi.C.ts_node_is_null(var_list_node) then
            if string.match(TS.safe_node_type(var_list_node), "list") then
                for i = 0, TS.node_child_count(var_list_node) - 1 do
                    local child = TS.node_child(var_list_node, i)
                    if ffi.C.ts_node_is_named(child) then
                        lhs:insert(LowerAST(child, source))
                    end
                end
            else
                lhs:insert(LowerAST(var_list_node, source))
            end
        end

        -- Grab the Right-Hand Side
        local exp_list_node = TS.node_child_by_field_name(node, "expression_list", 15)
        if ffi.C.ts_node_is_null(exp_list_node) then
            exp_list_node = TS.node_child_by_field_name(node, "right", 5)
        end

        if not ffi.C.ts_node_is_null(exp_list_node) then
            if string.match(TS.safe_node_type(exp_list_node), "list") then
                for i = 0, TS.node_child_count(exp_list_node) - 1 do
                    local child = TS.node_child(exp_list_node, i)
                    if ffi.C.ts_node_is_named(child) then
                        rhs:insert(LowerAST(child, source))
                    end
                end
            else
                rhs:insert(LowerAST(exp_list_node, source))
            end
        end

        return ast.newobject(anchor, T.assignment, lhs, rhs)
    end

    -- ==========================================
    -- 5. CONTROL FLOW
    -- ==========================================
    Visitor["block"] = function(node, source)
        local anchor = create_anchor(node)
        local statements = asdl.List()

        local child_count = TS.node_child_count(node)
        for i = 0, child_count - 1 do
            local child = TS.node_child(node, i)
            
            if ffi.C.ts_node_is_named(child) then
                local stmt_ast = LowerAST(child, source)
                if stmt_ast then
                    statements:insert(stmt_ast)
                end
            end
        end

        return ast.newobject(anchor, T.block, statements)
    end

    Visitor["if_statement"] = function(node, source)
        local anchor = create_anchor(node)
        local branches = asdl.List()
        local orelse = nil

        local condition_node = TS.node_child_by_field_name(node, "condition", 9)
        local body_node = TS.node_child_by_field_name(node, "consequence", 11)
        if ffi.C.ts_node_is_null(body_node) then
            body_node = TS.node_child_by_field_name(node, "body", 4) 
        end
        
        local main_cond_ast = LowerAST(condition_node, source)
        local main_body_ast = LowerAST(body_node, source)
        
        branches:insert(ast.newobject(anchor, T.ifbranch, main_cond_ast, main_body_ast))

        local child_count = TS.node_child_count(node)
        for i = 0, child_count - 1 do
            local child = TS.node_child(node, i)
            local child_type = TS.safe_node_type(child)

            if child_type == "elseif_statement" then
                local ei_cond = TS.node_child_by_field_name(child, "condition", 9)
                local ei_body = TS.node_child_by_field_name(child, "consequence", 11)
                if ffi.C.ts_node_is_null(ei_body) then ei_body = TS.node_child_by_field_name(child, "body", 4) end
                
                branches:insert(ast.newobject(anchor, T.ifbranch, LowerAST(ei_cond, source), LowerAST(ei_body, source)))
                
            elseif child_type == "else_statement" then
                local el_body = TS.node_child_by_field_name(child, "body", 4)
                if ffi.C.ts_node_is_null(el_body) then el_body = TS.node_child_by_field_name(child, "consequence", 11) end
                
                orelse = LowerAST(el_body, source)
            end
        end

        return ast.newobject(anchor, T.ifstat, branches, orelse)
    end

    Visitor["for_statement"] = function(node, source)
        local anchor = create_anchor(node)

        local clause_node = TS.node_child_by_field_name(node, "clause", 6)
        local control_parent = ffi.C.ts_node_is_null(clause_node) and node or clause_node

        local var_node = TS.node_child_by_field_name(control_parent, "name", 4)
        if ffi.C.ts_node_is_null(var_node) then
             var_node = TS.node_child_by_field_name(control_parent, "variable", 8)
        end
        
        if ffi.C.ts_node_is_null(var_node) then
             for i = 0, TS.node_child_count(control_parent) - 1 do
                 local child = TS.node_child(control_parent, i)
                 if ffi.C.ts_node_is_named(child) and TS.safe_node_type(child) == "identifier" then
                     var_node = child
                     break
                 end
             end
        end

        local var_name = ffi.string(TS.get_node_text(var_node, source))

        local named_ident = ast.newobject(anchor, T.namedident, var_name)
        local iter_param = ast.newobject(anchor, T.unevaluatedparam, named_ident, nil)

        local initial_node = TS.node_child_by_field_name(control_parent, "start", 5)
        local limit_node = TS.node_child_by_field_name(control_parent, "end", 3)
        local step_node = TS.node_child_by_field_name(control_parent, "step", 4)

        if ffi.C.ts_node_is_null(initial_node) then
            local named_idx = 0
            for i = 0, TS.node_child_count(control_parent) - 1 do
                local child = TS.node_child(control_parent, i)
                if ffi.C.ts_node_is_named(child) and TS.safe_node_type(child) ~= "identifier" then
                    named_idx = named_idx + 1
                    if named_idx == 1 then initial_node = child
                    elseif named_idx == 2 then limit_node = child
                    elseif named_idx == 3 then step_node = child end
                end
            end
        end

        local initial_ast = LowerAST(initial_node, source)
        local limit_ast = LowerAST(limit_node, source)
        local step_ast = ffi.C.ts_node_is_null(step_node) and nil or LowerAST(step_node, source)

        local body_node = TS.node_child_by_field_name(node, "body", 4)
        local body_ast = LowerAST(body_node, source)
        
        if not body_ast then body_ast = ast.newobject(anchor, T.block, asdl.List()) end

        return ast.newobject(anchor, T.fornumu, iter_param, initial_ast, limit_ast, step_ast, body_ast)
    end

    Visitor["while_statement"] = function(node, source)
        local anchor = create_anchor(node)
        
        local condition_node = TS.node_child_by_field_name(node, "condition", 9)
        local body_node = TS.node_child_by_field_name(node, "body", 4)
        
        if ffi.C.ts_node_is_null(condition_node) then
            for i = 0, TS.node_child_count(node) - 1 do
                local child = TS.node_child(node, i)
                if ffi.C.ts_node_is_named(child) then
                    if ffi.C.ts_node_is_null(condition_node) then 
                        condition_node = child
                    else 
                        body_node = child
                        break 
                    end
                end
            end
        end

        local condition_ast = LowerAST(condition_node, source)
        local body_ast = LowerAST(body_node, source)
        
        if not body_ast then body_ast = ast.newobject(anchor, T.block, asdl.List()) end

        return ast.newobject(anchor, T.whilestat, condition_ast, body_ast)
    end

    Visitor["repeat_statement"] = function(node, source)
        local anchor = create_anchor(node)
        
        local condition_node = TS.node_child_by_field_name(node, "condition", 9)
        local body_node = TS.node_child_by_field_name(node, "body", 4)

        if ffi.C.ts_node_is_null(condition_node) then
            local named_children = {}
            for i = 0, TS.node_child_count(node) - 1 do
                local child = TS.node_child(node, i)
                if ffi.C.ts_node_is_named(child) then 
                    table.insert(named_children, child) 
                end
            end
            if #named_children >= 2 then
                body_node = named_children[1]
                condition_node = named_children[#named_children]
            end
        end

        local condition_ast = LowerAST(condition_node, source)
        local body_ast = LowerAST(body_node, source)

        local statements_list = asdl.List()
        if body_ast then
            if body_ast.kind == "block" then
                statements_list = body_ast.statements
            else
                statements_list:insert(body_ast)
            end
        end

        return ast.newobject(anchor, T.repeatstat, statements_list, condition_ast)
    end

    Visitor["break_statement"] = function(node, source)
        return ast.newobject(create_anchor(node), T.breakstat)
    end

    Visitor["return_statement"] = function(node, source)
        local anchor = create_anchor(node)
        local expr_list_ast = asdl.List()
        local child_count = TS.node_child_count(node)
        
        for i = 0, child_count - 1 do
            local child = TS.node_child(node, i)
            if TS.safe_node_type(child) == "expression_list" then
                local exp_count = TS.node_child_count(child)
                for j = 0, exp_count - 1 do
                    local exp_child = TS.node_child(child, j)
                    local exp_type = TS.safe_node_type(exp_child)
                    
                    if exp_type ~= "," and exp_type ~= "(" and exp_type ~= ")" then
                        local exp_ast = LowerAST(exp_child, source)
                        if exp_ast then expr_list_ast:insert(exp_ast) end
                    end
                end
            end
        end
        
        local let_in_expr = ast.newobject(anchor, T.letin, asdl.List(), expr_list_ast, false)
        return ast.newobject(anchor, T.returnstat, let_in_expr)
    end

    -- ==========================================
    -- 6. FUNCTIONS
    -- ==========================================
    Visitor["terra_function_implementation"] = function(node, source)
        local anchor = create_anchor(node)
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
            local type_text = ffi.string(TS.get_node_text(type_node, source))
            local std_types = { ["int"] = types.int32, ["double"] = types.double, ["bool"] = types.bool, ["float"] = types.float }
            local res = std_types[type_text] or types[type_text]
            if not res then 
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
                if child_type == "identifier" or child_type == "ERROR" then
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
                
                local param_name = ffi.string(TS.get_node_text(param_name_node, source))
                local resolved_type = resolve_type(param_type_node)
                
                local sym = ast.newsymbol and ast.newsymbol(resolved_type, param_name) or T.symbol(resolved_type, param_name)
                local param_ast = ast.newobject(anchor, T.concreteparam, resolved_type, param_name, sym, true)
                params_list:insert(param_ast)
            end
        end

        local name_node = TS.node_child_by_field_name(node, "name", 4)
        local func_name = nil
        if not ffi.C.ts_node_is_null(name_node) then
            func_name = ffi.string(TS.get_node_text(name_node, source))
        end

        local func_ast = ast.newobject(anchor, T.functiondefu, params_list, false, return_type_ast, body_block)
        
        func_ast.lsp_name = func_name 
        return func_ast
    end

    -- ==========================================
    -- 7. MEMORY & POINTERS
    -- ==========================================
    Visitor["reference"] = function(node, source)
        local anchor = create_anchor(node)
        local operand_node = nil
        
        for i = 0, TS.node_child_count(node) - 1 do
            local child = TS.node_child(node, i)
            if ffi.C.ts_node_is_named(child) then
                operand_node = child
                break
            end
        end
        
        local operand_ast = LowerAST(operand_node, source)
        return ast.newobject(anchor, T.operator, "&", asdl.List({operand_ast}))
    end

    Visitor["dereference"] = function(node, source)
        local anchor = create_anchor(node)
        local operand_node = nil
        
        for i = 0, TS.node_child_count(node) - 1 do
            local child = TS.node_child(node, i)
            if ffi.C.ts_node_is_named(child) then
                operand_node = child
                break
            end
        end
        
        local operand_ast = LowerAST(operand_node, source)
        return ast.newobject(anchor, T.operator, "@", asdl.List({operand_ast}))
    end

    -- ==========================================
    -- 8. METAPROGRAMMING
    -- ==========================================
    Visitor["escape_expression"] = function(node, source)
        local anchor = create_anchor(node)
        local inner_node = nil
        
        for i = 0, TS.node_child_count(node) - 1 do
            local child = TS.node_child(node, i)
            if ffi.C.ts_node_is_named(child) then
                inner_node = child
                break
            end
        end
        
        local inner_text = ffi.string(TS.get_node_text(inner_node, source))
        
        local lua_eval_fn = function()
            local env = _G.CURRENT_ENV or _G
            
            local chunk = loadstring("return " .. inner_text)
            if chunk then
                setfenv(chunk, env)
                local status, result = pcall(chunk)
                if status and result then return result end
            end
            
            return env[inner_text] or types[inner_text]
        end
        
        return ast.newobject(anchor, T.luaexpression, lua_eval_fn, true)
    end

    -- ==========================================
    -- 9. AST ENGINE ENTRY POINT
    -- ==========================================
    LowerAST = function(node, source)
        -- ⬇️ THE CRITICAL SAFETY SHIELD ⬇️
        if not node or ffi.C.ts_node_is_null(node) then 
            return nil 
        end

        local node_type = ffi.string(TS.node_type(node))
        local visitor_fn = Visitor[node_type]
        if visitor_fn then
            return visitor_fn(node, source)
        else
            -- You might want to suppress this in production, but great for debugging missing grammar features
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