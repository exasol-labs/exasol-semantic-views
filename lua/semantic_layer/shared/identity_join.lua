-- Rendering of the F5 identity mapping join, shared by the validator's probes
-- and the compiler's generated SQL. The packaging step embeds this source into
-- both Exasol scripts so the installed runtime has no external dependency.
--
-- A MAPPED identity binding reaches its semantic key through a certified
-- two-column mapping relation, and that one join used to be written out in five
-- places: the compiler's base and alternate key expressions, and the validator's
-- grouped-key query, mapping probes, and F4 conflict probe. BUG-G03 was a single
-- defect -- a declared column name quoted verbatim, so a lower-case
-- `account_id` rendered as `"account_id"` against a physical `ACCOUNT_ID` -- and
-- it existed independently in every one of them. Fixing it meant finding and
-- editing all five, and the last was found only by grepping after the fix looked
-- complete.
--
-- This module owns the two things they were duplicating: the physical spelling of
-- the mapping relation's declared columns, and the shape of the join onto it.
-- Callers still assemble their own statement around those pieces, because a
-- COUNT probe, a grouped key set and a compiled query legitimately want
-- different shapes -- forcing one function to emit all of them would trade a
-- duplication problem for a parameter problem.

local source_columns = assert(ESV_SOURCE_COLUMNS,
    "shared source column runtime is required")

local M = {}

-- Quoting is duplicated from the caller runtimes deliberately: three lines each,
-- against a module that would otherwise have to receive them as arguments at
-- every call. The alternative -- a shared SQL module -- is a bigger change than
-- this one earns.
local function quote_ident(name)
    return '"' .. string.gsub(tostring(name), '"', '""') .. '"'
end

local function quote_qualified(schema_name, object_name)
    return quote_ident(schema_name) .. "." .. quote_ident(object_name)
end

-- The column a semantic-key view projects. Callers reference it through
-- M.semantic_key_reference so the name is written once.
M.SEMANTIC_KEY_COLUMN = "F5_SEMANTIC_KEY"

-- The physical spelling of the mapping relation's two declared columns.
--
-- ADD_IDENTITY_MAPPING_RELATION stores what the modeler typed, and Exasol
-- resolves an unquoted identifier case-insensitively but a quoted one exactly.
-- Everything here quotes, so everything here has to resolve first.
function M.columns(query_fn, mapping, cache)
    return source_columns.resolve_pair(query_fn, mapping.source_schema,
        mapping.source_object, mapping.local_column, mapping.semantic_column,
        cache)
end

-- `"SCHEMA"."OBJECT"` for the mapping relation.
function M.mapping_source(mapping)
    return quote_qualified(mapping.source_schema, mapping.source_object)
end

-- The semantic key as read from the mapping relation: `alias."SEMANTIC_COLUMN"`.
function M.key(map_alias, semantic_column)
    return tostring(map_alias) .. "." .. quote_ident(semantic_column)
end

-- The join predicate onto the mapping relation:
-- `<local expression> = alias."LOCAL_COLUMN"`.
function M.predicate(local_expression, map_alias, local_column)
    return tostring(local_expression) .. " = " .. tostring(map_alias) .. "."
        .. quote_ident(local_column)
end

-- A representation projected alongside its resolved semantic key.
--
-- Used wherever a representation has to be joined *as if* it carried the
-- canonical key: the compiler's alternate-representation source and the
-- validator's F4 conflict probe were byte-identical here apart from their alias
-- prefixes, which is the duplication this replaces.
function M.semantic_key_view(query_fn, representation, mapping, source_alias,
        map_alias, local_expression, cache)
    local local_column, semantic_column = M.columns(query_fn, mapping, cache)
    return "(SELECT " .. tostring(source_alias) .. ".*, "
        .. M.key(map_alias, semantic_column) .. " AS "
        .. quote_ident(M.SEMANTIC_KEY_COLUMN) .. " FROM "
        .. quote_qualified(representation.source_schema, representation.source_object)
        .. " " .. tostring(source_alias) .. " JOIN "
        .. M.mapping_source(mapping) .. " " .. tostring(map_alias)
        .. " ON " .. M.predicate(local_expression, map_alias, local_column) .. ")"
end

-- How a caller refers to the column M.semantic_key_view projected.
function M.semantic_key_reference(alias)
    return tostring(alias) .. "." .. quote_ident(M.SEMANTIC_KEY_COLUMN)
end

ESV_IDENTITY_JOIN = M
