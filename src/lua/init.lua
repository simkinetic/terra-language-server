-- lua/init.lua
local terra = {}

-- 1. Base Structures
terra.asdl = require("compiler.semantics.asdl")
terra.ast  = require("compiler.semantics.ast")
terra.T    = terra.ast.T

-- 2. Primitives 
terra.types     = require("compiler.semantics.types").types
terra.quotes    = require("compiler.semantics.quotes")
terra.macros    = require("compiler.semantics.macros")
terra.functions = require("compiler.semantics.functions")

-- 3. Core Engine
local typechecker  = require("compiler.semantics.typechecker")
terra.typechecker  = typechecker

-- 4. Native Aliases & Constructors (Bridging the API gap)
terra.newlist   = require("compiler.utils.terralist")
terra.newanchor = terra.ast.newanchor
terra.newobject = terra.ast.newobject

terra.defineobjects  = typechecker.defineobjects
terra.anonstruct     = typechecker.anonstruct
terra.anonfunction   = typechecker.anonfunction
terra.externfunction = typechecker.externfunction
terra.definequote    = typechecker.definequote

-- 5. Global Export 
_G.terra = terra
_G.terralib = terra

return terra