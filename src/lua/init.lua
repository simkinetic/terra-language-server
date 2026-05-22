-- lua/init.lua
local terra = {}

-- 1. Base Structures
terra.asdl = require("lua.asdl")
terra.ast  = require("lua.ast")
terra.T    = terra.ast.T

-- 2. Primitives 
terra.types     = require("lua.types").types
terra.quotes    = require("lua.quotes")
terra.macros    = require("lua.macros")
terra.functions = require("lua.functions")

-- 3. Core Engine
local typechecker  = require("lua.typechecker")
terra.typechecker  = typechecker

-- 4. Native Aliases & Constructors (Bridging the API gap)
terra.newlist   = terra.asdl.List
terra.newanchor = terra.ast.newanchor
terra.newobject = terra.ast.newobject

-- Hoist the merged constructors to the root namespace!
terra.defineobjects  = typechecker.defineobjects
terra.anonstruct     = typechecker.anonstruct
terra.anonfunction   = typechecker.anonfunction
terra.externfunction = typechecker.externfunction
terra.definequote    = typechecker.definequote

-- 5. Global Export (Fulfilling the C++ aliasing requirement)
_G.terra = terra
_G.terralib = terra

return terra