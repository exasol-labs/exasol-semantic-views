local M = {}
local json = assert(ESV_JSON, "shared JSON runtime is required")
-- Bound to their own names rather than through a module alias: 763 call sites
-- read better as `row_value(row, ...)`, a `rows` alias would be shadowed by the
-- many local `rows` variables these files declare, and four names cost the chunk
-- exactly what the four function definitions they replace used to.
assert(ESV_ROWS, "shared row runtime is required")
local missing, row_value, null_if_missing, scalar =
    ESV_ROWS.missing, ESV_ROWS.row_value, ESV_ROWS.null_if_missing, ESV_ROWS.scalar
local sql_text = assert(ESV_SQL_TEXT, "shared SQL text runtime is required")

-- Semantic SQL compares whole comparison operators, so the lexer fuses
-- `>=`/`<=`/`<>`/`!=`; it must NOT fold quoted identifiers to upper case,
-- because token_upper is what the clause scanner compares against keywords
-- and a column quoted as "AND" would then parse as a conjunction. The DDL
-- parser wants the opposite of both; see shared/sql_text.lua.
local SEMANTIC_SQL_LEXER = {operators = true}
local grain_graph = assert(ESV_GRAIN_GRAPH, "shared grain graph runtime is required")
local identity_join = assert(ESV_IDENTITY_JOIN,
    "shared identity join runtime is required")
local source_columns = assert(ESV_SOURCE_COLUMNS,
    "shared source-column runtime is required")
local query_spec_runtime = assert(ESV_QUERY_SPEC, "query spec runtime is required")
local catalog_snapshot_runtime = assert(ESV_CATALOG_SNAPSHOT, "catalog snapshot runtime is required")
local metric_plan_runtime = assert(ESV_METRIC_PLAN, "metric plan runtime is required")
local physical_plan_runtime = assert(ESV_PHYSICAL_PLAN, "physical plan runtime is required")
local grain_sql_runtime = assert(ESV_GRAIN_SQL, "grain SQL runtime is required")

if type(import) == "function" then
    import("SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME", "materializations")
elseif type(exa) == "table" and type(exa.import) == "function" then
    exa.import("SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME", "materializations")
end

local materialization_runtime = materializations

-- Identity, not a copy: JSON_NULL is meaningful only while every holder of a
-- decoded null compares against the same table (see shared/json.lua).
local JSON_NULL = json.NULL
local MAX_LIMIT = 10000

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(tostring(value))
end

local function key(value)
    return tostring(value)
end


local function quote_column(alias, column_name)
    return tostring(alias) .. "." .. sql_text.quote_ident(column_name)
end

local function quote_alias(name)
    return sql_text.quote_ident(name)
end

local function is_text_type(data_type)
    local dtype = upper(data_type or "")
    return string.find(dtype, "CHAR", 1, true) ~= nil
        or string.find(dtype, "CLOB", 1, true) ~= nil
        or string.find(dtype, "VARCHAR", 1, true) ~= nil
end

local function as_array(value, field_name)
    if missing(value) then
        return {}
    end
    if not json.is_array(value) then
        error(field_name .. " must be an array")
    end
    return value
end

local function normalize_name(value, label)
    if missing(value) then
        error(label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("invalid " .. label .. ": " .. name)
    end
    return name
end

local function boolish(value)
    return value == true or tostring(value) == "true" or tostring(value) == "TRUE" or tostring(value) == "1"
end

local function error_result(code, message, clarification)
    return {
        status = clarification and "NEEDS_CLARIFICATION" or "ERROR",
        error_code = code,
        error_message = message,
        generated_sql = nil,
        plan_json = nil,
        clarification_json = clarification and json.encode(clarification) or nil,
        validation_run_id = nil,
        agent_request_id = nil,
        query_log_id = nil,
    }
end

-- Response shaping and the compile cache, behind two namespaces in a `do` block.
--
-- The block is load-bearing rather than stylistic. Exasol caps a Lua function at
-- 200 locals; the packaged COMPILER_RUNTIME is every compiler source
-- concatenated into one chunk, and this file alone declared 121 of those 200 --
-- leaving no room to add a shared module at all. Locals declared inside a block
-- are released at its `end`, so these eighteen helpers cost two slots instead of
-- eighteen. tools/package_lua_scripts.py enforces the ceiling and prints the
-- remaining headroom.
--
-- A block was the right shape because everything declared above it stays in
-- scope inside it: the grouping needed no dependency untangling, where a
-- separate module file would have had to duplicate the JSON codec and take
-- error_result (79 call sites) with it.
local envelope = {}
local compile_cache = {}
do
    function envelope.unchanged_result(sql_text)
        return {
            status = "UNCHANGED",
            error_code = nil,
            error_message = nil,
            generated_sql = sql_text,
            plan_json = nil,
            clarification_json = nil,
            validation_run_id = nil,
            agent_request_id = nil,
            query_log_id = nil,
        }
    end

    function envelope.recode_error_prefix(result, prefix)
        if type(result) == "table" and type(result.error_code) == "string" then
            result.error_code = string.gsub(result.error_code, "^SEMANTIC_REQUEST", prefix)
        end
        return result
    end

    function envelope.plan_materialization_name(plan)
        if type(plan) ~= "table" then
            return nil
        end
        if type(plan.selected_materializations) == "table"
            and #plan.selected_materializations > 0 then
            local names = {}
            for _, selected in ipairs(plan.selected_materializations) do
                names[#names + 1] = tostring(selected.materialization_name)
            end
            return table.concat(names, ",")
        end
        if plan.selected_materialization == nil
            or plan.selected_materialization == JSON_NULL then
            return nil
        elseif type(plan.selected_materialization) == "table" then
            return plan.selected_materialization.materialization_name
        end
        return tostring(plan.selected_materialization)
    end

    function envelope.typed_failure_message(failure)
        local reason = failure.reason_code or "TYPED_PLANNING_FAILED"
        if reason == "METRIC_STATE_UNSUPPORTED" then
            local metric_name = tostring(failure.metric or failure.metric_id or "unknown")
            local aggregate = tostring(failure.aggregation_function
                or failure.state_class or "unknown aggregate")
            if failure.entity_name ~= nil then
                return "Metric '" .. metric_name .. "' uses " .. aggregate
                    .. ", which has no mergeable aggregate state; entity '"
                    .. tostring(failure.entity_name)
                    .. "' is partitioned (partition fusion supports SUM and COUNT). Remove the metric "
                    .. "from this request or express it using mergeable SUM/COUNT states."
            end
            return "Metric '" .. metric_name .. "' uses " .. aggregate
                .. ", which has no mergeable aggregate state for strict typed planning."
        end
        if reason == "FUSION_PARTITION_DIMENSION_UNSUPPORTED" then
            local dimension_name = tostring(failure.dimension
                or failure.dimension_id or "unknown")
            local usage = failure.usage == "GLOBAL_FILTER"
                and "Filter dimension" or "Dimension"
            return usage .. " '" .. dimension_name
                .. "' resolves to partitioned entity '"
                .. tostring(failure.entity_name or failure.entity_id or "unknown")
                .. "', which is used here only as a joined dimension. Partitioned joined "
                .. "dimensions are not supported by partition fusion."
        end
        if reason == "FUSION_PARTITION_JOIN_UNSUPPORTED" then
            local entity_name = tostring(failure.entity_name
                or failure.entity_id or "unknown")
            local via = failure.path == nil and ""
                or " (join path: " .. tostring(failure.path) .. ")"
            return "Entity '" .. entity_name
                .. "' carries temporal coverage and is traversed as an"
                .. " intermediate join on the way to a requested field" .. via
                .. ". Partition fusion expands partitions only where the entity is a metric's own"
                .. " leaf, so joining through it would read the primary partition"
                .. " alone and silently omit the others. Request this field from a"
                .. " semantic object rooted at '" .. entity_name
                .. "', or remove the coverage declarations from that entity."
        end
        return "Typed planning failed: " .. tostring(reason) .. "."
    end

    -- What the layer was enforcing when this SQL was produced.
    --
    -- Written into the plan rather than left to be reconstructed, because the
    -- two questions a governance surface has to answer -- "why can I not see
    -- this" and "why is my number different from my colleague's" -- are asked
    -- after the fact, about a statement that has already run. The effective
    -- principal is part of it: compiled SQL is principal-independent, so
    -- recording who compiled it is the only way to tell two runs apart.
    --
    -- Read from SOURCE_TRUST, which VALIDATE_MODEL derives, and skipped
    -- entirely when there is nothing to say. This runs on a cold compile only:
    -- a cache hit returns the plan that was stored with it.
    function envelope.governance_block(model, generated_sql)
        if model == nil or missing(model.version_id) then
            return nil
        end
        local relations = compile_cache.qualified_relations(generated_sql)
        if #relations == 0 then
            return nil
        end
        local ok, rows = pcall(query, [[
            SELECT UPPER(PHYSICAL_SCHEMA) || '.' || UPPER(PHYSICAL_OBJECT) AS RELATION_NAME,
                   TRUST_CLASS
              FROM SEMANTIC_SOURCE.SOURCE_TRUST
             WHERE VERSION_ID = :version_id
        ]], {version_id = model.version_id})
        if not ok then
            return nil
        end
        local classified = {}
        for _, row in ipairs(rows or {}) do
            classified[tostring(row_value(row, "RELATION_NAME", 1))] =
                tostring(row_value(row, "TRUST_CLASS", 2))
        end
        local sources, unvouched = {}, {}
        for _, relation in ipairs(relations) do
            local trust_class = classified[relation] or "NOT_CLASSIFIED"
            sources[#sources + 1] = {relation = relation, trust_class = trust_class}
            if trust_class ~= "GOVERNED" and trust_class ~= "RAW" then
                unvouched[#unvouched + 1] = relation
            end
        end
        local principal = scalar("SELECT CURRENT_USER")
        return {
            governance_mode = upper(tostring(model.governance_mode or "OPEN")),
            compiled_by = principal and tostring(principal) or nil,
            sources = sources,
            unvouched_sources = unvouched,
        }
    end

    function envelope.with_governance(plan, model, generated_sql)
        local block = envelope.governance_block(model, generated_sql)
        if block ~= nil then
            plan.governance = block
        end
        return plan
    end

    -- GOVERNED means refuse, and this is where an ordinary compile finds that out.
    --
    -- The mode used to be consulted in exactly one place -- the guard that
    -- refuses to freeze a view -- so a model in GOVERNED mode reported
    -- SEMANTIC_MODEL_065 from validation, printed "it will refuse to compile"
    -- in its own summary, and then served the query. The rollup that drops a
    -- representation's row filter is the scenario the mode was built for, and it
    -- was still live in the mode that promises to stop it.
    --
    -- RAW is not refused. A materialization built *from* the governed views is a
    -- table, so it classifies RAW rather than GOVERNED, and it carries their
    -- policy perfectly well; refusing it would make the mode unusable with any
    -- pre-aggregate. What is refused is what the model cannot vouch for:
    -- DIVERGENT (reads relations the representations do not), UNKNOWN (the
    -- dependencies cannot be resolved) and NOT_CLASSIFIED (no derivation has run
    -- since the relation set last changed).
    function envelope.governance_refusal(model, plan, error_prefix)
        if model == nil or plan == nil or type(plan.governance) ~= "table" then
            return nil
        end
        if upper(tostring(model.governance_mode or "OPEN")) ~= "GOVERNED" then
            return nil
        end
        local unvouched = plan.governance.unvouched_sources or {}
        if #unvouched == 0 then
            return nil
        end
        return error_result(error_prefix .. "_028",
            "This model runs in GOVERNED mode and the SQL for this request reads "
            .. table.concat(unvouched, ", ") .. ", which the model does not vouch"
            .. " for. Whatever row or column policy its representations carry,"
            .. " that relation does not necessarily carry it, so answering would"
            .. " return rows the caller may not be entitled to. Rebuild or retire"
            .. " it, re-run VALIDATE_MODEL, or set the model back to OPEN with"
            .. " SET_MODEL_GOVERNANCE_MODE."
            .. " SEMANTIC_CATALOG.SOURCE_TRUST_FOR_MODEL has the derivation.")
    end

    function envelope.ok_result(sql_text, plan, validation_run_id)
        return {
            status = "OK",
            error_code = nil,
            error_message = nil,
            generated_sql = sql_text,
            plan_json = json.encode(plan),
            clarification_json = nil,
            validation_run_id = validation_run_id,
            agent_request_id = nil,
            query_log_id = nil,
            materialization_used = envelope.plan_materialization_name(plan),
        }
    end

    function envelope.monotonic_ms()
        if os ~= nil and type(os.clock) == "function" then
            return math.floor(os.clock() * 1000 + 0.5)
        end
        return nil
    end

    function envelope.attach_planning_runtime(result, started_ms)
        local finished_ms = envelope.monotonic_ms()
        if result ~= nil and started_ms ~= nil and finished_ms ~= nil then
            result.planning_runtime_ms = math.max(0, finished_ms - started_ms)
        end
        return result
    end

    -- Compile-result cache (BUG-D-002). The compiler is deterministic per
    -- (model_version_id, normalized request), so a successful compile is reused
    -- until PUBLISH_MODEL drops cache entries for the model version. The parsed
    -- request is canonicalized (strip logging-only fields, sort top-level keys)
    -- and hashed with a 64-bit polynomial hash. Collisions in this space are
    -- vanishingly improbable for any realistic dashboard workload.

    compile_cache.CACHE_IGNORED_REQUEST_KEYS = {client = true, purpose = true,
        natural_language_text = true, natural_language = true, source = true}

    -- COMPILE_REQUEST_JSON is a closed contract. Silently dropping misspelled or
    -- future-looking keys is unsafe for autonomous callers: a request can return
    -- STATUS=OK while not doing what the caller asked. Keep this list aligned with
    -- SEMANTIC_AGENT.COMPILE_REQUEST_SCHEMA_FOR_AGENT.
    compile_cache.STRUCTURED_REQUEST_KEY_NAMES = {
        "client", "dimensions", "filters", "having", "limit", "metrics",
        "model", "natural_language_text", "object", "options", "order_by",
        "proof_mode", "purpose",
    }

    compile_cache.STRUCTURED_REQUEST_KEYS = {}
    for _, request_key in ipairs(compile_cache.STRUCTURED_REQUEST_KEY_NAMES) do
        compile_cache.STRUCTURED_REQUEST_KEYS[request_key] = true
    end

    -- Per-request planner safeguards. docs/data-fusion.md documented these as
    -- overridable while the closed schema rejected the key outright. They are
    -- accepted now, and they can only *tighten*: a request may ask to fail earlier
    -- than the deployment's limit, never later, so a caller cannot talk the planner
    -- out of a safeguard. (Declared inside the function on purpose: this chunk is
    -- close to Lua's 200-local limit for a main chunk.)
    function compile_cache.validate_structured_request_keys(request)
        local option_names = {"max_branches", "max_bytes"}
        local unknown = {}
        for request_key, _ in pairs(request) do
            if type(request_key) ~= "string" or not compile_cache.STRUCTURED_REQUEST_KEYS[request_key] then
                unknown[#unknown + 1] = tostring(request_key)
            end
        end
        if #unknown > 0 then
            table.sort(unknown)
            return error_result(
                "SEMANTIC_REQUEST_004",
                "Unknown top-level request key(s): " .. table.concat(unknown, ", ")
                    .. ". Allowed keys: " .. table.concat(compile_cache.STRUCTURED_REQUEST_KEY_NAMES, ", ") .. "."
            )
        end

        local options = request.options
        if options == nil or options == null or options == JSON_NULL then
            return nil
        end
        if type(options) ~= "table" or json.is_array(options) then
            return error_result("SEMANTIC_REQUEST_004",
                "options must be an object with keys: "
                    .. table.concat(option_names, ", ") .. ".")
        end
        local allowed_options = {}
        for _, option_key in ipairs(option_names) do allowed_options[option_key] = true end
        local unknown_options = {}
        for option_key, _ in pairs(options) do
            if type(option_key) ~= "string" or not allowed_options[option_key] then
                unknown_options[#unknown_options + 1] = tostring(option_key)
            end
        end
        if #unknown_options > 0 then
            table.sort(unknown_options)
            return error_result("SEMANTIC_REQUEST_004",
                "Unknown options key(s): " .. table.concat(unknown_options, ", ")
                    .. ". Allowed keys: " .. table.concat(option_names, ", ") .. ".")
        end
        for _, option_key in ipairs(option_names) do
            local value = options[option_key]
            if value ~= nil and value ~= null and value ~= JSON_NULL then
                local number = tonumber(value)
                if number == nil or number < 1 or number ~= math.floor(number) then
                    return error_result("SEMANTIC_REQUEST_004",
                        "options." .. option_key .. " must be a positive integer.")
                end
            end
        end
        return nil
    end

    function compile_cache.canonical_value(value)
        if value == nil or value == null or value == JSON_NULL then
            return null
        end
        if type(value) == "table" then
            if json.is_array(value) then
                local out = {}
                for i = 1, #value do
                    out[i] = compile_cache.canonical_value(value[i])
                end
                return out
            end
            local keys = {}
            for k, _ in pairs(value) do
                if type(k) == "string" then
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys)
            local out = {}
            for _, k in ipairs(keys) do
                out[k] = compile_cache.canonical_value(value[k])
            end
            return out
        end
        return value
    end

    -- Identity of the runtime that produced a cached statement. `PLAN_VERSION`
    -- alone is not enough: it is a hand-maintained constant, so a parser or
    -- renderer change that leaves it alone used to keep serving SQL compiled by
    -- the previous runtime. `package_lua_scripts.py` stamps ESV_RUNTIME_BUILD
    -- from the hash of the sources that decide compiler output, so every build
    -- gets its own keyspace and a stale entry is unreachable rather than wrong.
    -- Absent when the sources are loaded directly, as the database-free tests
    -- do; "dev" keeps those runs sharing one keyspace.
    function compile_cache.runtime_build()
        local stamped = rawget(_G, "ESV_RUNTIME_BUILD")
        if stamped == nil or stamped == "" then
            return "dev"
        end
        return tostring(stamped)
    end

    function compile_cache.canonical_request_text(request)
        if type(request) ~= "table" then
            return nil
        end
        local stripped = {}
        for k, v in pairs(request) do
            if type(k) == "string" and not compile_cache.CACHE_IGNORED_REQUEST_KEYS[string.lower(k)] then
                stripped[k] = v
            end
        end
        local ok, encoded = pcall(json.encode, compile_cache.canonical_value(stripped))
        if not ok then
            return nil
        end
        return "plan=" .. tostring(metric_plan_runtime.PLAN_VERSION)
            .. "|build=" .. compile_cache.runtime_build() .. "|" .. encoded
    end

    -- The Semantic SQL lane cannot reach the request-keyed cache above until it
    -- has resolved every field name in the SELECT list, and resolving them costs
    -- a full load_catalog that a cache hit then throws away. Keying the same
    -- cache by the token stream lets that lane answer a repeat query from the
    -- model version alone.
    --
    -- The token stream is the right canonical form: it is insensitive to
    -- whitespace and comments, and sensitive to everything else. Token text is
    -- NOT case-folded, because folding would merge the literals in
    -- `status = 'Complete'` and `status = 'COMPLETE'`, which are different
    -- filters. Case variants of the same query therefore occupy separate
    -- entries -- a cache-efficiency cost, never a correctness one. The kind is
    -- part of the key so a string literal can never collide with the keyword
    -- spelled the same way.
    function compile_cache.canonical_sql_text(tokens)
        if type(tokens) ~= "table" or #tokens == 0 then
            return nil
        end
        local parts = {}
        for i = 1, #tokens do
            parts[i] = tostring(tokens[i].kind or "") .. "\30" .. tostring(tokens[i].text or "")
        end
        return "sql=" .. tostring(metric_plan_runtime.PLAN_VERSION)
            .. "|build=" .. compile_cache.runtime_build() .. "|"
            .. table.concat(parts, "\31")
    end

    -- 64-bit polynomial hash (two parallel 32-bit polynomials with different bases
    -- and primes). Pure Lua 5.1 - no bitwise ops, all arithmetic stays under 2^53
    -- so doubles are exact.
    function compile_cache.compile_cache_key(canonical_text)
        if type(canonical_text) ~= "string" or canonical_text == "" then
            return nil
        end
        local h1, h2 = 5381, 0
        for i = 1, #canonical_text do
            local b = string.byte(canonical_text, i)
            h1 = (h1 * 33 + b) % 4294967296
            h2 = (h2 * 31 + b) % 4294967296
        end
        return string.format("%08x%08x", h1, h2)
    end

    -- Cache integrity: what a cached statement is allowed to read.
    --
    -- COMPILE_CACHE is an ordinary table in SYS_SEMANTIC, and the compiler is
    -- not the only thing that can write to it. Whoever can `UPDATE
    -- SYS_SEMANTIC.COMPILE_CACHE SET GENERATED_SQL = ...` chooses the text that
    -- a published guarded view then executes with the view owner's rights, for
    -- every caller, with no compile in between. So a cache row is not trusted
    -- input merely because the compiler is what usually writes it. It is
    -- checked on the way out.
    --
    -- The boundary is read from the model's *declarations* -- representations,
    -- materializations, and F5 identity mapping relations -- and not from
    -- SYS_SEMANTIC.SOURCE_TRUST, which VALIDATE_MODEL derives. The planner
    -- reads the declarations, so a check that reads the same rows cannot
    -- disagree with the compile that produced the entry it is checking.
    -- SOURCE_TRUST can lag: a materialization added after the last
    -- VALIDATE_MODEL is absent from it while the planner is already choosing
    -- it, and a boundary that lags is a boundary that rejects SQL the compiler
    -- emitted seconds ago. SOURCE_TRUST keeps the job it was built for, which
    -- is classifying these relations (RAW / GOVERNED / DIVERGENT) -- not
    -- deciding membership.
    function compile_cache.trust_boundary(model_version_id)
        local boundary = {names = {}, count = 0}
        if model_version_id == nil then
            return boundary
        end
        -- One view, not three reads. SEMANTIC_SOURCE.MODEL_RELATIONS unions the
        -- three declaration tables that can put a physical relation into
        -- rendered SQL, and it carries the authorization filter once rather
        -- than once per branch. That is what keeps the warm path free: this
        -- runs on every cache hit, and three filter evaluations per hit was the
        -- whole measured cost of scoping there.
        --
        -- SYS_SEMANTIC.ENTITIES is deliberately not among the three. It carries
        -- SOURCE_SCHEMA/SOURCE_OBJECT columns, but load_catalog selects
        -- `er.SOURCE_SCHEMA` through an inner join on the entity's active
        -- PRIMARY representation and never reads the entity's own pair, so
        -- admitting it would widen the boundary with relations the renderer
        -- cannot emit.
        local rows = query([[
            SELECT RELATION_SCHEMA AS SOURCE_SCHEMA, RELATION_OBJECT AS SOURCE_OBJECT
              FROM SEMANTIC_SOURCE.MODEL_RELATIONS
             WHERE VERSION_ID = :version_id
        ]], {version_id = model_version_id})
        for _, row in ipairs(rows or {}) do
            local schema_name = row_value(row, "SOURCE_SCHEMA", 1)
            local object_name = row_value(row, "SOURCE_OBJECT", 2)
            if not missing(schema_name) and not missing(object_name) then
                local name = upper(schema_name) .. "." .. upper(object_name)
                if not boundary.names[name] then
                    boundary.names[name] = true
                    boundary.count = boundary.count + 1
                end
            end
        end
        return boundary
    end

    -- The relations a statement reads, found by the one shape that cannot be
    -- mistaken for anything else: a quoted schema identifier, a dot, and a
    -- quoted object identifier. Every physical relation the renderer emits has
    -- that shape, and nothing else in its output does -- a column reference is
    -- `alias."NAME"`, whose head is an unquoted alias, and a CTE reference is a
    -- lone `"__esv_..."` with no dot at all.
    --
    -- Reading pairs rather than parsing from-clauses is deliberate. A
    -- from-clause parser has to know that the `FROM` in `EXTRACT(YEAR FROM
    -- o."ORDER_DATE")` and `TRIM(BOTH ' ' FROM x)` does not introduce a
    -- relation, and being wrong about that rejects a statement the compiler
    -- just produced. The pair scan has no such cases. It runs on the token
    -- stream, not the raw text, so a `"MART"."ORDERS"` written inside a string
    -- literal is a literal and not a relation.
    --
    -- What it does not see is an *unqualified* reference -- `FROM SECRETS`,
    -- resolved against the executing schema. The renderer quotes and qualifies
    -- everything, so it never emits one, but a rewritten entry could. Finding it
    -- needs the from-clause parser this avoids, and it is not worth that while
    -- the same principal can widen the boundary by declaring a relation; G3 is
    -- what closes both.
    function compile_cache.qualified_relations(sql)
        local found = {}
        if type(sql) ~= "string" or sql == "" then
            return found
        end
        local tokens = sql_text.tokenize(sql)
        local i = 1
        while i + 2 <= #tokens do
            local head, dot, tail = tokens[i], tokens[i + 1], tokens[i + 2]
            if head.kind == "identifier" and dot.kind == "symbol" and dot.text == "."
                and tail.kind == "identifier" then
                found[#found + 1] = upper(sql_text.decode_quoted_identifier(head.text))
                    .. "." .. upper(sql_text.decode_quoted_identifier(tail.text))
                i = i + 3
            else
                i = i + 1
            end
        end
        return found
    end

    -- Two conditions, and the second is the one that does the work.
    --
    -- Containment alone accepts `SELECT 'PWNED'`, which reads no relation at
    -- all -- the shortest poisoned entry there is, and the first one a
    -- demonstration reaches for. Requiring that the statement actually read
    -- something the model declares is what turns "may not read anything else"
    -- into "may only be this model's query".
    function compile_cache.within_trust_boundary(sql, boundary)
        if boundary == nil or boundary.count == 0 then
            return false, "no declared relations"
        end
        local inside = 0
        for _, name in ipairs(compile_cache.qualified_relations(sql)) do
            if not boundary.names[name] then
                return false, name
            end
            inside = inside + 1
        end
        if inside == 0 then
            return false, "no relation inside the boundary"
        end
        return true, nil
    end

    function compile_cache.discard_entry(model_version_id, cache_key)
        pcall(query, [[
            DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
            WHERE MODEL_VERSION_ID = :model_version_id
              AND CACHE_KEY = :cache_key
        ]], {model_version_id = model_version_id, cache_key = cache_key})
    end

    function compile_cache.cache_lookup(model_version_id, cache_key)
        if cache_key == nil or model_version_id == nil then
            return nil
        end
        local rows = query([[
            SELECT GENERATED_SQL, PLAN_JSON, VALIDATION_RUN_ID
            FROM SYS_SEMANTIC.COMPILE_CACHE
            WHERE MODEL_VERSION_ID = :model_version_id
              AND CACHE_KEY = :cache_key
        ]], {model_version_id = model_version_id, cache_key = cache_key})
        if rows == nil or #rows == 0 then
            return nil
        end
        local row = rows[1]
        local generated_sql = row_value(row, "GENERATED_SQL", 1)
        local boundary = compile_cache.trust_boundary(model_version_id)
        local within, offending = compile_cache.within_trust_boundary(generated_sql, boundary)
        if not within then
            -- A rejected entry is a miss: the caller compiles, gets the right
            -- answer, and pays what any cold query pays. The row is dropped
            -- only when there was a boundary to violate, so an installation
            -- whose declarations could not be read loses cache hits rather
            -- than its cache.
            if boundary.count > 0 then
                compile_cache.discard_entry(model_version_id, cache_key)
            end
            return nil, offending
        end
        return {
            generated_sql = generated_sql,
            plan_json = row_value(row, "PLAN_JSON", 2),
            validation_run_id = row_value(row, "VALIDATION_RUN_ID", 3),
        }
    end

    function compile_cache.cache_store(model_version_id, cache_key, result)
        if cache_key == nil or model_version_id == nil or result == nil
            or result.status ~= "OK" or missing(result.generated_sql) then
            return
        end
        -- Best-effort insert. A PK collision (same model_version_id + cache_key)
        -- means another concurrent compile already wrote this entry, so nothing
        -- to do. A transient transaction collision is also swallowed - the caller
        -- already has the compile result.
        pcall(query, [[
            INSERT INTO SYS_SEMANTIC.COMPILE_CACHE (
              MODEL_VERSION_ID, CACHE_KEY, GENERATED_SQL, PLAN_JSON,
              VALIDATION_RUN_ID, LAST_HIT_AT, HIT_COUNT
            ) VALUES (
              :model_version_id, :cache_key, :generated_sql, :plan_json,
              :validation_run_id, NULL, 0
            )
        ]], {
            model_version_id = model_version_id,
            cache_key = cache_key,
            generated_sql = null_if_missing(result.generated_sql),
            plan_json = null_if_missing(result.plan_json),
            validation_run_id = null_if_missing(result.validation_run_id),
        })
    end

    function compile_cache.cache_touch(model_version_id, cache_key)
        if cache_key == nil or model_version_id == nil then
            return
        end
        pcall(query, [[
            UPDATE SYS_SEMANTIC.COMPILE_CACHE
            SET LAST_HIT_AT = CURRENT_TIMESTAMP,
                HIT_COUNT = HIT_COUNT + 1
            WHERE MODEL_VERSION_ID = :model_version_id
              AND CACHE_KEY = :cache_key
        ]], {model_version_id = model_version_id, cache_key = cache_key})
    end

    function compile_cache.cached_ok_result(cached)
        -- Reconstruct an envelope.ok_result payload from the cached row. plan_json comes
        -- straight from storage. materialization_used is recovered by decoding it.
        local plan = nil
        if not missing(cached.plan_json) then
            local ok, decoded = pcall(json.decode, cached.plan_json)
            if ok then plan = decoded end
        end
        return {
            status = "OK",
            error_code = nil,
            error_message = nil,
            generated_sql = cached.generated_sql,
            plan_json = cached.plan_json,
            clarification_json = nil,
            validation_run_id = cached.validation_run_id,
            agent_request_id = nil,
            query_log_id = nil,
            materialization_used = envelope.plan_materialization_name(plan),
            cache_hit = true,
            planning_runtime_ms = 0,
        }
    end
end


local function load_model(model_name)
    -- GOVERNANCE_MODE is part of the model's identity here, not an extra.
    -- Omitting it did not read as absent: `model.governance_mode or "OPEN"` in
    -- two consumers turned a missing column into the literal answer OPEN, so a
    -- GOVERNED model reported OPEN in PLAN_JSON and skipped its own enforcement.
    -- load_model_by_published_schema selects it, which is why the CREATE VIEW
    -- path refused correctly while the ordinary compile did not.
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID, mv.VERSION_NUMBER,
               m.GOVERNANCE_MODE
        FROM SEMANTIC_SOURCE.MODELS m
        LEFT JOIN SEMANTIC_SOURCE.MODEL_VERSIONS mv
          ON mv.VERSION_ID = m.ACTIVE_VERSION_ID
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        return nil
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2),
        version_number = row_value(rows[1], "VERSION_NUMBER", 3),
        governance_mode = row_value(rows[1], "GOVERNANCE_MODE", 4),
        model_name = model_name,
    }
end

local function validate_model(model)
    local rows = query([[
        EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)
    ]], {model_name = model.model_name})
    local errors = {}
    for _, row in ipairs(rows or {}) do
        local severity = row_value(row, "SEVERITY", 1)
        if severity == "ERROR" or severity == "PRECONDITION" then
            errors[#errors + 1] = {
                code = row_value(row, "RULE_CODE", 4),
                object_type = row_value(row, "OBJECT_TYPE", 2),
                object = row_value(row, "OBJECT_NAME", 3),
                message = row_value(row, "MESSAGE", 5),
            }
        end
    end
    local validation_run_id = scalar([[
        SELECT MAX(VALIDATION_RUN_ID)
        FROM SEMANTIC_SOURCE.VALIDATION_RUNS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    return errors, validation_run_id
end

local function collect_referenced_validation_objects(ctx, metrics, dimensions)
    local referenced = {
        DIMENSION = {},
        FACT = {},
        METRIC = {},
    }
    for _, dimension in ipairs(dimensions or {}) do
        referenced.DIMENSION[upper(dimension.name)] = true
    end
    local function add_metric(metric, seen)
        local metric_key = key(metric.id)
        if seen[metric_key] then
            return
        end
        seen[metric_key] = true
        referenced.METRIC[upper(metric.name)] = true
        local dep_rows = query([[
            SELECT DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID
            FROM SEMANTIC_SOURCE.METRIC_DEPENDENCIES
            WHERE METRIC_ID = :metric_id
        ]], {metric_id = metric.id})
        for _, row in ipairs(dep_rows or {}) do
            local dep_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 1)
            local dep_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 2)
            if dep_type == "FACT" then
                local fact = ctx.fact_by_id[key(dep_id)]
                if fact ~= nil then
                    referenced.FACT[upper(fact.name)] = true
                end
            elseif dep_type == "METRIC" then
                local dep_metric = (ctx.all_metric_by_id or ctx.metric_by_id)[key(dep_id)]
                if dep_metric ~= nil then
                    add_metric(dep_metric, seen)
                end
            end
        end
    end
    for _, metric in ipairs(metrics or {}) do
        add_metric(metric, {})
    end
    return referenced
end

local function validation_error_applies(error_row, referenced)
    local object_type = upper(error_row.object_type or "")
    local object_name = upper(error_row.object or "")
    if object_type == "DIMENSION" or object_type == "FACT" or object_type == "METRIC" then
        return referenced[object_type] ~= nil and referenced[object_type][object_name] == true
    end
    if object_type == "SYNONYM" then
        return false
    end
    return true
end

local function load_catalog(model, object_name)
    local object_rows = query([[
        SELECT OBJECT_ID, OBJECT_NAME, ROOT_ENTITY_ID
        FROM SEMANTIC_SOURCE.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
          AND STATUS = 'ACTIVE'
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if object_rows == nil or #object_rows == 0 then
        return nil, "SEMANTIC_REQUEST_012", "Semantic object not found: " .. tostring(object_name)
    end

    local ctx = {
        model = model,
        object = {
            id = row_value(object_rows[1], "OBJECT_ID", 1),
            name = row_value(object_rows[1], "OBJECT_NAME", 2),
            root_entity_id = row_value(object_rows[1], "ROOT_ENTITY_ID", 3),
        },
        entities = {},
        representations = {},
        representations_by_entity = {},
        representation_by_id = {},
        entity_by_id = {},
        entity_by_alias = {},
        dimensions = {},
        dimension_by_id = {},
        metrics = {},
        metric_by_id = {},
        all_metrics = {},
        all_metric_by_id = {},
        facts = {},
        fact_by_id = {},
        fact_by_name = {},
        attribute_bindings = {},
        bindings_by_attribute = {},
        attribute_fusion_policies = {},
        fusion_policy_by_attribute = {},
        semantic_identities = {},
        identity_by_id = {},
        identities_by_entity = {},
        identity_bindings = {},
        identity_binding_by_id = {},
        relationships = {},
        relationship_by_id = {},
        unique_keys = {},
        unique_key_by_id = {},
        unique_keys_by_entity = {},
        relationship_identity_remaps = {},
        relationship_candidate_rejections = {},
        canonical_fields = {},
        synonym_fields = {},
    }

    local entity_rows = query([[
        SELECT e.ENTITY_ID, e.ENTITY_NAME,
               er.SOURCE_SCHEMA, er.SOURCE_OBJECT, er.SOURCE_ALIAS,
               e.PRIMARY_KEY_EXPR, e.GRAIN_DESCRIPTION,
               er.REPRESENTATION_ID, er.REPRESENTATION_NAME,
               er.SOURCE_KIND, er.REPRESENTATION_ROLE, er.PRIORITY
        FROM SEMANTIC_SOURCE.ENTITIES e
        JOIN SEMANTIC_SOURCE.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        ORDER BY e.ENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(entity_rows or {}) do
        local entity = {
            id = row_value(row, "ENTITY_ID", 1),
            name = row_value(row, "ENTITY_NAME", 2),
            source_schema = row_value(row, "SOURCE_SCHEMA", 3),
            source_object = row_value(row, "SOURCE_OBJECT", 4),
            alias = row_value(row, "SOURCE_ALIAS", 5),
            primary_key_expr = row_value(row, "PRIMARY_KEY_EXPR", 6),
            grain_description = row_value(row, "GRAIN_DESCRIPTION", 7),
            primary_representation = {
                id = row_value(row, "REPRESENTATION_ID", 8),
                entity_id = row_value(row, "ENTITY_ID", 1),
                name = row_value(row, "REPRESENTATION_NAME", 9),
                source_kind = row_value(row, "SOURCE_KIND", 10) or "RELATION",
                role = row_value(row, "REPRESENTATION_ROLE", 11) or "PRIMARY",
                priority = row_value(row, "PRIORITY", 12) or 1,
                source_schema = row_value(row, "SOURCE_SCHEMA", 3),
                source_object = row_value(row, "SOURCE_OBJECT", 4),
                alias = row_value(row, "SOURCE_ALIAS", 5),
            },
        }
        ctx.entities[#ctx.entities + 1] = entity
        ctx.entity_by_id[key(entity.id)] = entity
        ctx.entity_by_alias[upper(entity.alias)] = entity
    end

    local representation_rows = query([[
        SELECT er.REPRESENTATION_ID, er.ENTITY_ID, er.REPRESENTATION_NAME,
               er.SOURCE_KIND, er.SOURCE_SCHEMA, er.SOURCE_OBJECT,
               er.SOURCE_ALIAS, er.REPRESENTATION_ROLE, er.PRIORITY,
               er.FRESHNESS_POLICY, er.COVERAGE_PREDICATE, er.VALID_FROM,
               er.VALID_TO, COALESCE(ra.AUTHORITY_ROLE, 'PREFER') AS AUTHORITY_ROLE
        FROM SEMANTIC_SOURCE.ENTITY_REPRESENTATIONS er
        LEFT JOIN SEMANTIC_SOURCE.REPRESENTATION_AUTHORITIES ra
          ON ra.MODEL_ID = er.MODEL_ID AND ra.VERSION_ID = er.VERSION_ID
         AND ra.REPRESENTATION_ID = er.REPRESENTATION_ID AND ra.STATUS = 'ACTIVE'
        WHERE er.MODEL_ID = :model_id
          AND er.VERSION_ID = :version_id
          AND er.STATUS = 'ACTIVE'
        ORDER BY er.ENTITY_ID,
          CASE WHEN er.REPRESENTATION_ROLE = 'PRIMARY' THEN 0 ELSE 1 END,
          er.PRIORITY, er.REPRESENTATION_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(representation_rows or {}) do
        local representation = {
            id = row_value(row, "REPRESENTATION_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "REPRESENTATION_NAME", 3),
            source_kind = row_value(row, "SOURCE_KIND", 4),
            source_schema = row_value(row, "SOURCE_SCHEMA", 5),
            source_object = row_value(row, "SOURCE_OBJECT", 6),
            alias = row_value(row, "SOURCE_ALIAS", 7),
            role = row_value(row, "REPRESENTATION_ROLE", 8),
            priority = row_value(row, "PRIORITY", 9),
            freshness_policy = row_value(row, "FRESHNESS_POLICY", 10),
            coverage_predicate = row_value(row, "COVERAGE_PREDICATE", 11),
            valid_from = row_value(row, "VALID_FROM", 12),
            valid_to = row_value(row, "VALID_TO", 13),
            authority_role = row_value(row, "AUTHORITY_ROLE", 14) or "PREFER",
        }
        ctx.representations[#ctx.representations + 1] = representation
        ctx.representation_by_id[key(representation.id)] = representation
        local entity_key = key(representation.entity_id)
        ctx.representations_by_entity[entity_key] =
            ctx.representations_by_entity[entity_key] or {}
        ctx.representations_by_entity[entity_key]
            [#ctx.representations_by_entity[entity_key] + 1] = representation
        if upper(representation.role) == "PRIMARY" and ctx.entity_by_id[entity_key] ~= nil then
            ctx.entity_by_id[entity_key].primary_representation = representation
        end
    end

    local dimension_rows = query([[
        SELECT d.DIMENSION_ID, d.DIMENSION_NAME, d.ENTITY_ID, d.EXPRESSION,
               d.DATA_TYPE, d.DISPLAY_NAME, d.IS_HIDDEN, d.DISPLAY_POLICY
        FROM SEMANTIC_SOURCE.OBJECT_COLUMNS oc
        JOIN SEMANTIC_SOURCE.DIMENSIONS d
          ON d.DIMENSION_ID = oc.OBJECT_REF_ID
        WHERE oc.OBJECT_ID = :object_id
          AND oc.COLUMN_KIND = 'DIMENSION'
          AND oc.IS_VISIBLE = TRUE
          AND d.STATUS = 'ACTIVE'
        ORDER BY oc.ORDINAL_POSITION
    ]], {object_id = ctx.object.id})
    for _, row in ipairs(dimension_rows or {}) do
        local dimension = {
            kind = "DIMENSION",
            id = row_value(row, "DIMENSION_ID", 1),
            name = row_value(row, "DIMENSION_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            display_name = row_value(row, "DISPLAY_NAME", 6),
            withheld = row_value(row, "IS_HIDDEN", 7) == true,
            display_policy = row_value(row, "DISPLAY_POLICY", 8),
        }
        ctx.dimensions[#ctx.dimensions + 1] = dimension
        ctx.dimension_by_id[key(dimension.id)] = dimension
        ctx.canonical_fields[upper(dimension.name)] = dimension
    end

    local metric_rows = query([[
        SELECT mt.METRIC_ID, mt.METRIC_NAME, mt.BASE_ENTITY_ID, mt.EXPRESSION,
               COALESCE(mt.SQL_FILTER_EXPR, mt.FILTER_EXPR) AS FILTER_EXPR,
               mt.METRIC_TYPE, mt.DATA_TYPE, mt.DISPLAY_NAME,
               COALESCE(mt.METRIC_KIND, mt.METRIC_TYPE) AS METRIC_KIND,
               mt.AGGREGATION_FUNCTION, mt.MEASURE_EXPR,
               mt.SEMANTIC_FILTER_EXPR, mt.SQL_FILTER_EXPR,
               mt.DISTINCT_KEY_EXPR, mt.NON_ADDITIVE_DIMENSION_ID,
               mt.WINDOW_SPEC_JSON, mt.TYPE_PARAMS_JSON,
               mt.IS_PRIVATE, mt.DISPLAY_POLICY
        FROM SEMANTIC_SOURCE.OBJECT_COLUMNS oc
        JOIN SEMANTIC_SOURCE.METRICS mt
          ON mt.METRIC_ID = oc.OBJECT_REF_ID
        WHERE oc.OBJECT_ID = :object_id
          AND oc.COLUMN_KIND = 'METRIC'
          AND oc.IS_VISIBLE = TRUE
          AND mt.STATUS = 'ACTIVE'
        ORDER BY oc.ORDINAL_POSITION
    ]], {object_id = ctx.object.id})
    for _, row in ipairs(metric_rows or {}) do
        local metric = {
            kind = "METRIC",
            id = row_value(row, "METRIC_ID", 1),
            name = row_value(row, "METRIC_NAME", 2),
            base_entity_id = row_value(row, "BASE_ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            filter_expr = row_value(row, "FILTER_EXPR", 5),
            metric_type = row_value(row, "METRIC_TYPE", 6),
            data_type = row_value(row, "DATA_TYPE", 7),
            display_name = row_value(row, "DISPLAY_NAME", 8),
            metric_kind = row_value(row, "METRIC_KIND", 9),
            aggregation_function = row_value(row, "AGGREGATION_FUNCTION", 10),
            measure_expr = row_value(row, "MEASURE_EXPR", 11),
            semantic_filter_expr = row_value(row, "SEMANTIC_FILTER_EXPR", 12),
            sql_filter_expr = row_value(row, "SQL_FILTER_EXPR", 13),
            distinct_key_expr = row_value(row, "DISTINCT_KEY_EXPR", 14),
            non_additive_dimension_id = row_value(row, "NON_ADDITIVE_DIMENSION_ID", 15),
            window_spec_json = row_value(row, "WINDOW_SPEC_JSON", 16),
            type_params_json = row_value(row, "TYPE_PARAMS_JSON", 17),
            withheld = row_value(row, "IS_PRIVATE", 18) == true,
            display_policy = row_value(row, "DISPLAY_POLICY", 19),
            inputs = {},
            filters = {},
        }
        ctx.metrics[#ctx.metrics + 1] = metric
        ctx.metric_by_id[key(metric.id)] = metric
        ctx.all_metrics[#ctx.all_metrics + 1] = metric
        ctx.all_metric_by_id[key(metric.id)] = metric
        ctx.canonical_fields[upper(metric.name)] = metric
    end

    -- Planner catalog completeness is independent of field visibility.
    -- Private metrics stay absent from canonical_fields while remaining
    -- available for transitive dependency planning.
    local all_metric_rows = query([[
        SELECT METRIC_ID, METRIC_NAME, BASE_ENTITY_ID, EXPRESSION,
               COALESCE(SQL_FILTER_EXPR, FILTER_EXPR) AS FILTER_EXPR,
               METRIC_TYPE, DATA_TYPE, DISPLAY_NAME,
               COALESCE(METRIC_KIND, METRIC_TYPE) AS METRIC_KIND,
               AGGREGATION_FUNCTION, MEASURE_EXPR,
               SEMANTIC_FILTER_EXPR, SQL_FILTER_EXPR,
               DISTINCT_KEY_EXPR, NON_ADDITIVE_DIMENSION_ID,
               WINDOW_SPEC_JSON, TYPE_PARAMS_JSON
        FROM SEMANTIC_SOURCE.METRICS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY METRIC_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(all_metric_rows or {}) do
        local metric_id = row_value(row, "METRIC_ID", 1)
        if ctx.all_metric_by_id[key(metric_id)] == nil then
            local metric = {
                kind = "METRIC",
                id = metric_id,
                name = row_value(row, "METRIC_NAME", 2),
                base_entity_id = row_value(row, "BASE_ENTITY_ID", 3),
                expression = row_value(row, "EXPRESSION", 4),
                filter_expr = row_value(row, "FILTER_EXPR", 5),
                metric_type = row_value(row, "METRIC_TYPE", 6),
                data_type = row_value(row, "DATA_TYPE", 7),
                display_name = row_value(row, "DISPLAY_NAME", 8),
                metric_kind = row_value(row, "METRIC_KIND", 9),
                aggregation_function = row_value(row, "AGGREGATION_FUNCTION", 10),
                measure_expr = row_value(row, "MEASURE_EXPR", 11),
                semantic_filter_expr = row_value(row, "SEMANTIC_FILTER_EXPR", 12),
                sql_filter_expr = row_value(row, "SQL_FILTER_EXPR", 13),
                distinct_key_expr = row_value(row, "DISTINCT_KEY_EXPR", 14),
                non_additive_dimension_id = row_value(row, "NON_ADDITIVE_DIMENSION_ID", 15),
                window_spec_json = row_value(row, "WINDOW_SPEC_JSON", 16),
                type_params_json = row_value(row, "TYPE_PARAMS_JSON", 17),
                inputs = {},
                filters = {},
                dependencies = {},
                visible = false,
            }
            ctx.all_metrics[#ctx.all_metrics + 1] = metric
            ctx.all_metric_by_id[key(metric.id)] = metric
        end
    end

    local metric_input_rows = query([[
        SELECT mi.METRIC_ID, mi.INPUT_ROLE, mi.INPUT_OBJECT_TYPE,
               mi.INPUT_OBJECT_ID, mi.EXPRESSION_ALIAS, mi.OFFSET_WINDOW,
               mi.FILTER_EXPR, mi.ORDINAL_POSITION
        FROM SEMANTIC_SOURCE.METRIC_INPUTS mi
        JOIN SEMANTIC_SOURCE.METRICS mt
          ON mt.METRIC_ID = mi.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY mi.METRIC_ID, mi.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(metric_input_rows or {}) do
        local metric = ctx.all_metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.inputs[#metric.inputs + 1] = {
                role = row_value(row, "INPUT_ROLE", 2),
                object_type = row_value(row, "INPUT_OBJECT_TYPE", 3),
                object_id = row_value(row, "INPUT_OBJECT_ID", 4),
                expression_alias = row_value(row, "EXPRESSION_ALIAS", 5),
                offset_window = row_value(row, "OFFSET_WINDOW", 6),
                filter_expr = row_value(row, "FILTER_EXPR", 7),
                ordinal_position = row_value(row, "ORDINAL_POSITION", 8),
            }
        end
    end

    local metric_filter_rows = query([[
        SELECT mf.METRIC_ID, mf.FILTER_KIND, mf.FILTER_EXPR,
               mf.RESOLVED_SQL_EXPR, mf.REQUIRED_DIMENSION_ID,
               mf.REQUIRED_ENTITY_ID, mf.ORDINAL_POSITION
        FROM SEMANTIC_SOURCE.METRIC_FILTERS mf
        JOIN SEMANTIC_SOURCE.METRICS mt
          ON mt.METRIC_ID = mf.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY mf.METRIC_ID, mf.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(metric_filter_rows or {}) do
        local metric = ctx.all_metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.filters[#metric.filters + 1] = {
                kind = row_value(row, "FILTER_KIND", 2),
                expression = row_value(row, "FILTER_EXPR", 3),
                resolved_sql_expr = row_value(row, "RESOLVED_SQL_EXPR", 4),
                required_dimension_id = row_value(row, "REQUIRED_DIMENSION_ID", 5),
                required_entity_id = row_value(row, "REQUIRED_ENTITY_ID", 6),
                ordinal_position = row_value(row, "ORDINAL_POSITION", 7),
            }
        end
    end

    local metric_dependency_rows = query([[
        SELECT md.METRIC_ID, md.DEPENDS_ON_OBJECT_TYPE, md.DEPENDS_ON_OBJECT_ID
        FROM SEMANTIC_SOURCE.METRIC_DEPENDENCIES md
        JOIN SEMANTIC_SOURCE.METRICS mt ON mt.METRIC_ID = md.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY md.METRIC_ID, md.DEPENDS_ON_OBJECT_TYPE, md.DEPENDS_ON_OBJECT_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(metric_dependency_rows or {}) do
        local metric = ctx.all_metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.dependencies = metric.dependencies or {}
            metric.dependencies[#metric.dependencies + 1] = {
                object_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 2),
                object_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 3),
            }
        end
    end

    local fact_rows = query([[
        SELECT FACT_ID, FACT_NAME, ENTITY_ID, EXPRESSION, DATA_TYPE,
               ADDITIVE_POLICY
        FROM SEMANTIC_SOURCE.FACTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY FACT_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(fact_rows or {}) do
        local fact = {
            id = row_value(row, "FACT_ID", 1),
            name = row_value(row, "FACT_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            additive_policy = row_value(row, "ADDITIVE_POLICY", 6),
        }
        ctx.facts[#ctx.facts + 1] = fact
        ctx.fact_by_id[key(fact.id)] = fact
        ctx.fact_by_name[upper(fact.name)] = fact
    end

    local binding_rows = query([[
        SELECT ATTRIBUTE_BINDING_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
               REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE,
               BINDING_PRIORITY, IS_DEFAULT
        FROM SEMANTIC_SOURCE.ATTRIBUTE_BINDINGS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ATTRIBUTE_TYPE, ATTRIBUTE_ID,
          CASE WHEN BINDING_ROLE = 'PREFER' THEN 0 ELSE 1 END,
          BINDING_PRIORITY, ATTRIBUTE_BINDING_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(binding_rows or {}) do
        local binding = {
            id = row_value(row, "ATTRIBUTE_BINDING_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            attribute_type = row_value(row, "ATTRIBUTE_TYPE", 3),
            attribute_id = row_value(row, "ATTRIBUTE_ID", 4),
            representation_id = row_value(row, "REPRESENTATION_ID", 5),
            expression = row_value(row, "SOURCE_EXPRESSION", 6),
            role = row_value(row, "BINDING_ROLE", 7),
            priority = row_value(row, "BINDING_PRIORITY", 8),
            is_default = row_value(row, "IS_DEFAULT", 9),
            legacy = row_value(row, "IS_DEFAULT", 9) == true,
        }
        ctx.attribute_bindings[#ctx.attribute_bindings + 1] = binding
        local attribute_key = upper(binding.attribute_type) .. ":" .. key(binding.attribute_id)
        ctx.bindings_by_attribute[attribute_key] =
            ctx.bindings_by_attribute[attribute_key] or {}
        ctx.bindings_by_attribute[attribute_key]
            [#ctx.bindings_by_attribute[attribute_key] + 1] = binding
    end

    local fusion_policy_rows = query([[
        SELECT ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID, FUSION_STRATEGY
        FROM SEMANTIC_SOURCE.ATTRIBUTE_FUSION_POLICIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ATTRIBUTE_TYPE, ATTRIBUTE_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(fusion_policy_rows or {}) do
        local policy = {
            entity_id = row_value(row, "ENTITY_ID", 1),
            attribute_type = row_value(row, "ATTRIBUTE_TYPE", 2),
            attribute_id = row_value(row, "ATTRIBUTE_ID", 3),
            strategy = row_value(row, "FUSION_STRATEGY", 4),
        }
        local attribute_key = upper(policy.attribute_type) .. ":" .. key(policy.attribute_id)
        ctx.attribute_fusion_policies[#ctx.attribute_fusion_policies + 1] = policy
        ctx.fusion_policy_by_attribute[attribute_key] = policy
    end

    local identity_rows = query([[
        SELECT IDENTITY_ID, ENTITY_ID, IDENTITY_NAME, IDENTITY_KIND, DATA_TYPE
        FROM SEMANTIC_SOURCE.SEMANTIC_IDENTITIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID, IDENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(identity_rows or {}) do
        local identity = {
            id = row_value(row, "IDENTITY_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "IDENTITY_NAME", 3),
            kind = row_value(row, "IDENTITY_KIND", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            bindings = {},
        }
        ctx.semantic_identities[#ctx.semantic_identities + 1] = identity
        ctx.identity_by_id[key(identity.id)] = identity
        ctx.identities_by_entity[key(identity.entity_id)] =
            ctx.identities_by_entity[key(identity.entity_id)] or {}
        ctx.identities_by_entity[key(identity.entity_id)]
            [#ctx.identities_by_entity[key(identity.entity_id)] + 1] = identity
    end
    local identity_binding_rows = query([[
        SELECT ib.IDENTITY_BINDING_ID, ib.ENTITY_ID, ib.IDENTITY_ID,
               ib.REPRESENTATION_ID, ib.SOURCE_EXPRESSION, ib.BINDING_KIND,
               im.IDENTITY_MAPPING_ID, im.SOURCE_SCHEMA, im.SOURCE_OBJECT,
               im.SOURCE_LOCAL_COLUMN, im.SEMANTIC_KEY_COLUMN,
               im.CERTIFICATION_STATUS
        FROM SEMANTIC_SOURCE.IDENTITY_BINDINGS ib
        LEFT JOIN SEMANTIC_SOURCE.IDENTITY_MAPPING_RELATIONS im
          ON im.IDENTITY_BINDING_ID = ib.IDENTITY_BINDING_ID
         AND im.STATUS = 'ACTIVE'
        WHERE ib.MODEL_ID = :model_id AND ib.VERSION_ID = :version_id
          AND ib.STATUS = 'ACTIVE'
        ORDER BY ib.IDENTITY_ID, ib.IDENTITY_BINDING_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(identity_binding_rows or {}) do
        local binding = {
            id = row_value(row, "IDENTITY_BINDING_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            identity_id = row_value(row, "IDENTITY_ID", 3),
            representation_id = row_value(row, "REPRESENTATION_ID", 4),
            expression = row_value(row, "SOURCE_EXPRESSION", 5),
            kind = row_value(row, "BINDING_KIND", 6),
            mapping = not missing(row_value(row, "IDENTITY_MAPPING_ID", 7)) and {
                id = row_value(row, "IDENTITY_MAPPING_ID", 7),
                source_schema = row_value(row, "SOURCE_SCHEMA", 8),
                source_object = row_value(row, "SOURCE_OBJECT", 9),
                local_column = row_value(row, "SOURCE_LOCAL_COLUMN", 10),
                semantic_column = row_value(row, "SEMANTIC_KEY_COLUMN", 11),
                certification = row_value(row, "CERTIFICATION_STATUS", 12),
            } or nil,
        }
        ctx.identity_bindings[#ctx.identity_bindings + 1] = binding
        ctx.identity_binding_by_id[key(binding.id)] = binding
        local identity = ctx.identity_by_id[key(binding.identity_id)]
        if identity ~= nil then
            identity.bindings[#identity.bindings + 1] = binding
            identity.binding_by_representation = identity.binding_by_representation or {}
            identity.binding_by_representation[key(binding.representation_id)] = binding
        end
    end

    local relationship_rows = query([[
        SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
               JOIN_CONDITION, RELATIONSHIP_CARDINALITY, JOIN_TYPE, FANOUT_POLICY,
               PATH_PRIORITY
        FROM SEMANTIC_SOURCE.RELATIONSHIPS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY PATH_PRIORITY, RELATIONSHIP_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(relationship_rows or {}) do
        local relationship = {
            id = row_value(row, "RELATIONSHIP_ID", 1),
            name = row_value(row, "RELATIONSHIP_NAME", 2),
            from_entity_id = row_value(row, "FROM_ENTITY_ID", 3),
            to_entity_id = row_value(row, "TO_ENTITY_ID", 4),
            join_condition = row_value(row, "JOIN_CONDITION", 5),
            cardinality = row_value(row, "RELATIONSHIP_CARDINALITY", 6),
            join_type = row_value(row, "JOIN_TYPE", 7),
            fanout_policy = row_value(row, "FANOUT_POLICY", 8),
            path_priority = row_value(row, "PATH_PRIORITY", 9),
            key_mappings = {},
        }
        ctx.relationships[#ctx.relationships + 1] = relationship
        ctx.relationship_by_id[key(relationship.id)] = relationship
    end

    local mapping_rows = query([[
        SELECT rkm.RELATIONSHIP_ID, rkm.ORDINAL_POSITION,
               rkm.FROM_COLUMN_NAME, rkm.FROM_EXPRESSION,
               rkm.TO_COLUMN_NAME, rkm.TO_EXPRESSION
        FROM SEMANTIC_SOURCE.RELATIONSHIP_KEY_MAPPINGS rkm
        JOIN SEMANTIC_SOURCE.RELATIONSHIPS r
          ON r.RELATIONSHIP_ID = rkm.RELATIONSHIP_ID
        WHERE r.MODEL_ID = :model_id
          AND r.VERSION_ID = :version_id
          AND r.STATUS = 'ACTIVE'
        ORDER BY rkm.RELATIONSHIP_ID, rkm.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(mapping_rows or {}) do
        local relationship = ctx.relationship_by_id[key(row_value(row, "RELATIONSHIP_ID", 1))]
        if relationship ~= nil then
            relationship.key_mappings[#relationship.key_mappings + 1] = {
                ordinal_position = row_value(row, "ORDINAL_POSITION", 2),
                from_column_name = row_value(row, "FROM_COLUMN_NAME", 3),
                from_expression = row_value(row, "FROM_EXPRESSION", 4),
                to_column_name = row_value(row, "TO_COLUMN_NAME", 5),
                to_expression = row_value(row, "TO_EXPRESSION", 6),
            }
        end
    end

    local unique_key_rows = query([[
        SELECT UNIQUE_KEY_ID, ENTITY_ID, KEY_NAME, KEY_KIND, SOURCE_FORMAT
        FROM SEMANTIC_SOURCE.UNIQUE_KEYS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID, UNIQUE_KEY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(unique_key_rows or {}) do
        local unique_key = {
            id = row_value(row, "UNIQUE_KEY_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "KEY_NAME", 3),
            kind = row_value(row, "KEY_KIND", 4),
            source_format = row_value(row, "SOURCE_FORMAT", 5),
            columns = {},
        }
        ctx.unique_keys[#ctx.unique_keys + 1] = unique_key
        ctx.unique_key_by_id[key(unique_key.id)] = unique_key
        local entity_key = key(unique_key.entity_id)
        ctx.unique_keys_by_entity[entity_key] = ctx.unique_keys_by_entity[entity_key] or {}
        ctx.unique_keys_by_entity[entity_key][#ctx.unique_keys_by_entity[entity_key] + 1] = unique_key
    end

    local unique_key_column_rows = query([[
        SELECT ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION,
               ukc.COLUMN_NAME, ukc.EXPRESSION
        FROM SEMANTIC_SOURCE.UNIQUE_KEY_COLUMNS ukc
        JOIN SEMANTIC_SOURCE.UNIQUE_KEYS uk
          ON uk.UNIQUE_KEY_ID = ukc.UNIQUE_KEY_ID
        WHERE uk.MODEL_ID = :model_id
          AND uk.VERSION_ID = :version_id
          AND uk.STATUS = 'ACTIVE'
        ORDER BY ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(unique_key_column_rows or {}) do
        local unique_key = ctx.unique_key_by_id[key(row_value(row, "UNIQUE_KEY_ID", 1))]
        if unique_key ~= nil then
            unique_key.columns[#unique_key.columns + 1] = {
                ordinal_position = row_value(row, "ORDINAL_POSITION", 2),
                column_name = row_value(row, "COLUMN_NAME", 3),
                expression = row_value(row, "EXPRESSION", 4),
            }
        end
    end
    for _, unique_key in ipairs(ctx.unique_keys) do
        local canonical = grain_graph.canonical_key(unique_key)
        unique_key.columns = canonical.columns
        unique_key.kind = canonical.kind
    end

    local synonym_rows = query([[
        SELECT OBJECT_TYPE, OBJECT_ID, SYNONYM
        FROM SEMANTIC_SOURCE.SYNONYMS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND OBJECT_TYPE IN ('DIMENSION', 'METRIC')
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(synonym_rows or {}) do
        local object_type = row_value(row, "OBJECT_TYPE", 1)
        local object_id = row_value(row, "OBJECT_ID", 2)
        local synonym = upper(row_value(row, "SYNONYM", 3))
        local field = nil
        if object_type == "DIMENSION" then
            field = ctx.dimension_by_id[key(object_id)]
        elseif object_type == "METRIC" then
            field = ctx.metric_by_id[key(object_id)]
        end
        if field ~= nil then
            ctx.synonym_fields[synonym] = ctx.synonym_fields[synonym] or {}
            ctx.synonym_fields[synonym][#ctx.synonym_fields[synonym] + 1] = field
        end
    end

    return ctx
end

local function add_unique(list, seen, item)
    local item_key = item.kind .. ":" .. key(item.id)
    if not seen[item_key] then
        seen[item_key] = true
        list[#list + 1] = item
    end
end

-- Which of `candidates` is the author plausibly reaching for with `normalized`?
--
-- Two lanes ask this about the same typo. `SELECT bogus FROM obj` is read by the
-- whole-statement lane, which resolves each field and answers "Unknown semantic
-- field: bogus. Did you mean: ...?"; the same statement inside a subquery is
-- read by reference expansion, which has to decide which published columns to
-- put in the derived table and finds none named. Both must reach the same
-- suggestions, or a redundant wrapper changes the diagnosis -- which is the
-- defect this whole fallthrough exists to remove. So the rule lives here once.
--
-- `candidates` is an array of `{key = <normalized name>, display = <as shown>}`;
-- the callers hold different structures, and only the comparison is shared.
local function near_field_names(normalized, candidates)
    local near, seen = {}, {}
    for _, candidate in ipairs(candidates) do
        local key, display = candidate.key, candidate.display
        if not seen[display]
            and (string.find(key, normalized, 1, true)
                or string.find(normalized, key, 1, true)
                or (#normalized >= 3
                    and string.sub(key, 1, 3) == string.sub(normalized, 1, 3))) then
            seen[display] = true
            near[#near + 1] = display
        end
    end
    table.sort(near)
    while #near > 5 do table.remove(near) end
    return near
end

local function resolve_field(ctx, field_name, expected_kind)
    if missing(field_name) then
        return nil, error_result("SEMANTIC_REQUEST_020", "Field name is required.")
    end
    local normalized = upper(trim(field_name))
    local exact = ctx.canonical_fields[normalized]
    if exact ~= nil then
        if expected_kind ~= nil and exact.kind ~= expected_kind then
            return nil, error_result("SEMANTIC_REQUEST_022", "Field " .. tostring(field_name) .. " is not a " .. expected_kind .. ".")
        end
        -- `IS_PRIVATE` on a metric and `IS_HIDDEN` on a dimension already remove
        -- the field from discovery. They did not remove it from compilation, so
        -- anyone who knew the name got the data -- which made a column whose
        -- vocabulary reads like a control into a naming convention. Refused
        -- here, at the one place every lane resolves a name, so the filter
        -- lanes cannot reach a field the projection lane refuses.
        if exact.withheld then
            return nil, error_result("SEMANTIC_REQUEST_027",
                "Field " .. tostring(field_name) .. " is withheld by the model:"
                .. " it is marked " .. (exact.kind == "METRIC" and "IS_PRIVATE" or "IS_HIDDEN")
                .. ", which removes it from discovery and from queries. Ask the"
                .. " model's owner to publish it if you need it.")
        end
        return exact, nil
    end

    local candidates = ctx.synonym_fields[normalized] or {}
    local filtered = {}
    for _, candidate in ipairs(candidates) do
        if expected_kind == nil or candidate.kind == expected_kind then
            filtered[#filtered + 1] = candidate
        end
    end
    if #filtered == 1 then
        return filtered[1], nil
    elseif #filtered > 1 then
        local names = {}
        for _, candidate in ipairs(filtered) do
            names[#names + 1] = candidate.name
        end
        return nil, error_result("SEMANTIC_REQUEST_021", "Ambiguous semantic field: " .. tostring(field_name), {
            message = "Ambiguous semantic field.",
            field = tostring(field_name),
            candidates = names,
            clarification_question = "Which field did you mean for " .. tostring(field_name) .. "?",
        })
    end

    -- An unknown field is the most common thing an agent gets wrong, and it is
    -- answerable: either the name is near a field this object does have, or the
    -- field exists in a different semantic view of the same model. Both are put
    -- in CLARIFICATION_JSON, which was documented as the disambiguation channel
    -- and never populated for anything but ambiguity.
    local considered = {}
    for candidate_name, candidate in pairs(ctx.canonical_fields or {}) do
        if expected_kind == nil or candidate.kind == expected_kind then
            considered[#considered + 1] = {
                key = candidate_name,
                display = tostring(candidate.name or candidate_name),
            }
        end
    end
    local near = near_field_names(normalized, considered)

    local elsewhere = {}
    if ctx.model ~= nil and ctx.object ~= nil then
        for _, row in ipairs(query([[
            SELECT so.OBJECT_NAME, oc.COLUMN_KIND
            FROM SEMANTIC_SOURCE.OBJECT_COLUMNS oc
            JOIN SEMANTIC_SOURCE.SEMANTIC_OBJECTS so
              ON so.OBJECT_ID = oc.OBJECT_ID
            WHERE so.MODEL_ID = :model_id
              AND so.VERSION_ID = :version_id
              AND so.STATUS = 'ACTIVE'
              AND oc.IS_VISIBLE = TRUE
              AND UPPER(oc.COLUMN_NAME) = UPPER(:field_name)
              AND so.OBJECT_ID <> :object_id
            ORDER BY so.OBJECT_NAME
        ]], {
            model_id = ctx.model.model_id,
            version_id = ctx.model.version_id,
            field_name = trim(field_name),
            object_id = ctx.object.id,
        }) or {}) do
            elsewhere[#elsewhere + 1] = tostring(row_value(row, "OBJECT_NAME", 1))
        end
    end

    local question = "Which field did you mean instead of "
        .. tostring(field_name) .. "?"
    local detail = ""
    if #elsewhere > 0 then
        question = tostring(field_name) .. " belongs to semantic view "
            .. table.concat(elsewhere, ", ") .. ". Query that view, or choose a"
            .. " field of " .. tostring(ctx.object.name) .. "."
        detail = " It is a column of semantic view " .. table.concat(elsewhere, ", ")
            .. ", not of " .. tostring(ctx.object.name) .. "."
    elseif #near > 0 then
        detail = " Did you mean: " .. table.concat(near, ", ") .. "?"
    end
    -- A clarification is attached only when there is something to clarify:
    -- candidates in this object, or the view the field really belongs to. With
    -- neither, the request is simply wrong and stays a plain ERROR -- attaching
    -- an empty clarification would turn every typo into NEEDS_CLARIFICATION
    -- while giving the caller nothing to act on.
    if #near == 0 and #elsewhere == 0 then
        return nil, error_result("SEMANTIC_REQUEST_020",
            "Unknown semantic field: " .. tostring(field_name) .. ".")
    end
    return nil, error_result("SEMANTIC_REQUEST_020",
        "Unknown semantic field: " .. tostring(field_name) .. "." .. detail, {
            message = "Unknown semantic field.",
            field = tostring(field_name),
            object = ctx.object ~= nil and tostring(ctx.object.name) or nil,
            candidates = near,
            available_in_objects = elsewhere,
            clarification_question = question,
        })
end

local function relationship_edges(ctx)
    if ctx._edges == nil then
        ctx._edges, ctx._all_edges = grain_graph.build_edges(ctx.relationships)
    end
    return ctx._edges, ctx._all_edges
end

local function find_path(ctx, from_id, to_id)
    local edges = relationship_edges(ctx)
    local proof = grain_graph.prove_path(edges, from_id, to_id, {
        require_safe = true,
        reject_ambiguous = true,
    })
    if not proof.ok then
        ctx._last_path_proof = proof
        return nil
    end
    local path = {}
    for _, edge in ipairs(proof.edges) do
        path[#path + 1] = {
            from_entity_id = edge.from_id,
            to_entity_id = edge.to_id,
            relationship = edge.relationship,
        }
    end
    ctx._last_path_proof = proof
    return path
end

local function aliases_in_expression(expression)
    local aliases = {}
    if missing(expression) then
        return aliases
    end
    local text = sql_text.strip_string_literals(tostring(expression))
    for alias in string.gmatch(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%.") do
        aliases[upper(alias)] = true
    end
    return aliases
end

local function replace_identifiers(text, replace_fn)
    local out = {}
    local i = 1
    local in_quote = false
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            out[#out + 1] = c
            if in_quote and n == "'" then
                out[#out + 1] = n
                i = i + 2
            else
                in_quote = not in_quote
                i = i + 1
            end
        elseif in_quote then
            out[#out + 1] = c
            i = i + 1
        elseif string.match(c, "[A-Za-z_]") then
            local j = i + 1
            while j <= #text and string.match(string.sub(text, j, j), "[A-Za-z0-9_]") do
                j = j + 1
            end
            local token = string.sub(text, i, j - 1)
            out[#out + 1] = replace_fn(token) or token
            i = j
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function collect_metric_entities(ctx, metric, needed_entities, seen_metrics)
    local metric_key = key(metric.id)
    if seen_metrics[metric_key] then
        return
    end
    seen_metrics[metric_key] = true
    needed_entities[key(metric.base_entity_id)] = true
    for alias, _ in pairs(aliases_in_expression(metric.filter_expr)) do
        local entity = ctx.entity_by_alias[alias]
        if entity ~= nil then
            needed_entities[key(entity.id)] = true
        end
    end
    local dep_rows = query([[
        SELECT DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID
        FROM SEMANTIC_SOURCE.METRIC_DEPENDENCIES
        WHERE METRIC_ID = :metric_id
        ORDER BY DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID
    ]], {metric_id = metric.id})
    for _, row in ipairs(dep_rows or {}) do
        local dep_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 1)
        local dep_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 2)
        if dep_type == "FACT" then
            local fact = ctx.fact_by_id[key(dep_id)]
            if fact ~= nil then
                needed_entities[key(fact.entity_id)] = true
            end
        elseif dep_type == "METRIC" then
            local dep_metric = (ctx.all_metric_by_id or ctx.metric_by_id)[key(dep_id)]
            if dep_metric ~= nil then
                collect_metric_entities(ctx, dep_metric, needed_entities, seen_metrics)
            end
        end
    end
end

local function collect_metric_facts(ctx, metric, required, seen_metrics)
    local metric_key = key(metric.id)
    if seen_metrics[metric_key] then return end
    seen_metrics[metric_key] = true
    for _, dependency in ipairs(metric.dependencies or {}) do
        if upper(dependency.object_type) == "FACT" then
            local fact = ctx.fact_by_id[key(dependency.object_id)]
            if fact ~= nil then required["FACT:" .. key(fact.id)] = fact end
        elseif upper(dependency.object_type) == "METRIC" then
            local nested = ctx.all_metric_by_id[key(dependency.object_id)]
            if nested ~= nil then collect_metric_facts(ctx, nested, required, seen_metrics) end
        end
    end
end

local function complete_semantic_identity(ctx, entity)
    local representations = ctx.representations_by_entity[key(entity.id)] or {}
    for _, identity in ipairs((ctx.identities_by_entity or {})[key(entity.id)] or {}) do
        local complete = #representations > 0
        for _, representation in ipairs(representations) do
            local binding = identity.binding_by_representation
                and identity.binding_by_representation[key(representation.id)] or nil
            if binding == nil or (upper(binding.kind) == "MAPPED"
                and (binding.mapping == nil
                    or upper(binding.mapping.certification) ~= "CERTIFIED")) then
                complete = false
                break
            end
        end
        if complete then return identity end
    end
    return nil
end

local function compiler_source_column_exists(ctx, representation, column_name)
    ctx._source_column_exists = ctx._source_column_exists or {}
    local cache_key = tostring(representation.source_schema) .. "\31"
        .. tostring(representation.source_object) .. "\31" .. tostring(column_name)
    if ctx._source_column_exists[cache_key] ~= nil then
        return ctx._source_column_exists[cache_key]
    end
    local rows = query([[
        SELECT COUNT(*) AS COLUMN_COUNT
        FROM SYS.EXA_ALL_COLUMNS
        WHERE (COLUMN_SCHEMA = :schema_name OR COLUMN_SCHEMA = UPPER(:schema_name))
          AND (COLUMN_TABLE = :object_name OR COLUMN_TABLE = UPPER(:object_name))
          AND (COLUMN_NAME = :column_name OR COLUMN_NAME = UPPER(:column_name))
    ]], {schema_name = representation.source_schema,
          object_name = representation.source_object,
          column_name = column_name})
    local exists = rows ~= nil and #rows > 0
        and tonumber(row_value(rows[1], "COLUMN_COUNT", 1) or 0) > 0
    ctx._source_column_exists[cache_key] = exists
    return exists
end

local function relationship_candidate(ctx, requirement, entity, representation)
    local relationship = requirement.relationship
    local side = requirement.side
    local mapping = relationship.key_mappings and relationship.key_mappings[1] or nil
    local column_name = mapping and mapping[side .. "_column_name"] or nil
    if missing(column_name) then
        return nil, "relationship endpoint is not a scalar physical column"
    end
    if compiler_source_column_exists(ctx, representation, column_name) then
        return {kind = "PHYSICAL", column_name = column_name}, nil
    end
    if key(representation.id) == key(entity.primary_representation.id) then
        return nil, "primary representation is missing the relationship key column"
    end
    local unique_key, key_error = grain_graph.scalar_mapping_key(
        ctx.unique_keys_by_entity[key(entity.id)] or {},
        relationship.key_mappings or {}, side)
    if unique_key == nil then return nil, key_error end
    local identity = complete_semantic_identity(ctx, entity)
    local remap, remap_error = grain_graph.direct_identity_remap(identity,
        entity.primary_representation, representation, unique_key)
    if remap == nil then return nil, remap_error end
    return {
        kind = "DIRECT_IDENTITY",
        column_name = column_name,
        identity = identity,
        unique_key = unique_key,
        binding = remap.binding,
    }, nil
end

local function base_semantic_key_expression(ctx, entity, representation, identity_binding)
    if upper(identity_binding.kind) == "DIRECT" then
        return tostring(identity_binding.expression)
    end
    local mapping = identity_binding.mapping
    local cache = ctx ~= nil and ctx._source_column_cache or nil
    local local_column, semantic_column = identity_join.columns(query, mapping, cache)
    local map_alias = "f5_base_map_" .. tostring(identity_binding.id)
    entity.fusion_joins = entity.fusion_joins or {}
    entity.fusion_join_by_representation = entity.fusion_join_by_representation or {}
    local join_key = "MAP:" .. key(identity_binding.id)
    if not entity.fusion_join_by_representation[join_key] then
        entity.fusion_joins[#entity.fusion_joins + 1] = {
            source_sql = identity_join.mapping_source(mapping),
            alias = map_alias,
            predicates = {identity_join.predicate(identity_binding.expression,
                map_alias, local_column)},
            identity_mapping = true,
        }
        entity.fusion_join_by_representation[join_key] = true
    end
    return identity_join.key(map_alias, semantic_column)
end

local function alternate_identity_source(ctx, representation, identity_binding,
        lookup_alias)
    if upper(identity_binding.kind) == "DIRECT" then
        return sql_text.quote_qualified(representation.source_schema,
            representation.source_object),
            sql_text.replace_qualified_alias(identity_binding.expression,
                representation.alias, lookup_alias), nil
    end
    local mapping = identity_binding.mapping
    local source_alias = "f5_src_" .. tostring(representation.id)
    local local_expression = sql_text.replace_qualified_alias(identity_binding.expression,
        representation.alias, source_alias)
    local source_sql = identity_join.semantic_key_view(query, representation,
        mapping, source_alias, "f5_map_" .. tostring(identity_binding.id),
        local_expression, ctx ~= nil and ctx._source_column_cache or nil)
    return source_sql, identity_join.semantic_key_reference(lookup_alias), mapping
end

local function representation_by_id(ctx, representation_id)
    for _, representation in ipairs(ctx.representations or {}) do
        if key(representation.id) == key(representation_id) then return representation end
    end
    return nil
end

local function fusion_contributor_rank(ctx, binding)
    local representation = representation_by_id(ctx, binding.representation_id) or {}
    local authority = upper(representation.authority_role or "PREFER")
    local authority_rank = authority == "AUTHORITATIVE" and 0
        or authority == "PREFER" and 1 or 2
    local role_rank = upper(binding.role) == "PREFER" and 0 or 1
    return authority_rank, role_rank, tonumber(binding.priority or 1),
        tonumber(representation.priority or 1), tonumber(representation.id or 0)
end

local function sorted_fusion_bindings(ctx, bindings)
    local result = {}
    for _, binding in ipairs(bindings or {}) do result[#result + 1] = binding end
    table.sort(result, function(left, right)
        local la, lr, lb, lp, li = fusion_contributor_rank(ctx, left)
        local ra, rr, rb, rp, ri = fusion_contributor_rank(ctx, right)
        if la ~= ra then return la < ra end
        if lr ~= rr then return lr < rr end
        if lb ~= rb then return lb < rb end
        if lp ~= rp then return lp < rp end
        return li < ri
    end)
    return result
end

local function fused_attribute_expression(ctx, entity, base_representation,
        attribute_key, strategy)
    ctx._source_column_cache = ctx._source_column_cache or {}
    local unique_key = grain_graph.physical_unique_key(ctx.unique_keys_by_entity[key(entity.id)])
    local semantic_identity = complete_semantic_identity(ctx, entity)
    if unique_key == nil and semantic_identity == nil then
        return nil, nil, "Attribute fusion on entity '" .. tostring(entity.name)
            .. "' requires either a complete certified semantic identity or a declared unique key containing physical columns only."
    end
    local base_identity_binding = semantic_identity
        and semantic_identity.binding_by_representation[key(base_representation.id)] or nil
    local base_identity_expression = base_identity_binding
        and base_semantic_key_expression(ctx, entity, base_representation,
            base_identity_binding) or nil
    local bindings = sorted_fusion_bindings(ctx,
        ctx.bindings_by_attribute[attribute_key] or {})
    if #bindings < 2 then
        return nil, nil, "Fusion strategy " .. tostring(strategy) .. " for attribute '"
            .. tostring(attribute_key) .. "' requires bindings on at least two representations."
    end

    local expressions = {}
    local contributors = {}
    for _, binding in ipairs(bindings) do
        local representation = representation_by_id(ctx, binding.representation_id)
        if representation ~= nil then
            local expression = nil
            if key(representation.id) == key(base_representation.id) then
                expression = binding.expression
            else
                local lookup_alias = "f4_rep_" .. tostring(representation.id)
                local predicates = {}
                local source_sql = sql_text.quote_qualified(representation.source_schema,
                    representation.source_object)
                local identity_mapping = nil
                if semantic_identity ~= nil then
                    local identity_binding = semantic_identity.binding_by_representation[
                        key(representation.id)]
                    local alternate_identity
                    source_sql, alternate_identity, identity_mapping =
                        alternate_identity_source(ctx, representation, identity_binding,
                            lookup_alias)
                    predicates[#predicates + 1] = alternate_identity
                        .. " = " .. base_identity_expression
                else
                    -- Resolve the declared key column to the physical name each
                    -- source actually carries. A declared `customer_id` quoted
                    -- verbatim against a physical `CUSTOMER_ID` produces SQL
                    -- that parses and plans and then fails at execution, which
                    -- is what made a clean-validating model unqueryable. The
                    -- validator's conflict probe resolves the same way through
                    -- the same module, so probe and render cannot disagree.
                    for _, column in ipairs(unique_key.columns) do
                        -- Each side resolves against its own source, so sources
                        -- that spell the key differently still join. When the
                        -- metadata cannot answer -- a source outside
                        -- EXA_ALL_COLUMNS -- fall back to the declared spelling,
                        -- which is what this rendered before: the validator's
                        -- conflict probe is the gate that refuses a key column
                        -- no source exposes, and it runs for exactly the two
                        -- strategies that build this join.
                        local lookup_column = source_columns.resolve(
                            query, representation.source_schema,
                            representation.source_object, column.column_name,
                            ctx._source_column_cache) or column.column_name
                        local base_column = source_columns.resolve(
                            query, base_representation.source_schema,
                            base_representation.source_object, column.column_name,
                            ctx._source_column_cache) or column.column_name
                        predicates[#predicates + 1] = quote_column(lookup_alias, lookup_column)
                            .. " = " .. quote_column(base_representation.alias, base_column)
                    end
                end
                entity.fusion_joins = entity.fusion_joins or {}
                entity.fusion_join_by_representation =
                    entity.fusion_join_by_representation or {}
                if not entity.fusion_join_by_representation[key(representation.id)] then
                    entity.fusion_joins[#entity.fusion_joins + 1] = {
                        representation = representation,
                        source_sql = source_sql,
                        alias = lookup_alias,
                        predicates = predicates,
                        identity_mapping = identity_mapping,
                    }
                    entity.fusion_join_by_representation[key(representation.id)] = true
                end
                expression = sql_text.replace_qualified_alias(binding.expression,
                    representation.alias, lookup_alias)
            end
            expressions[#expressions + 1] = expression
            contributors[#contributors + 1] = {
                representation_id = representation.id,
                representation_name = representation.name,
                authority_role = upper(representation.authority_role or "PREFER"),
                attribute_binding_id = binding.id,
                source_expression = binding.expression,
                semantic_identity_id = semantic_identity and semantic_identity.id or nil,
                semantic_identity_name = semantic_identity and semantic_identity.name or nil,
                identity_binding_id = semantic_identity and
                    semantic_identity.binding_by_representation[key(representation.id)].id or nil,
                identity_mapping_id = semantic_identity and
                    semantic_identity.binding_by_representation[key(representation.id)].mapping
                    and semantic_identity.binding_by_representation[key(representation.id)].mapping.id or nil,
            }
        end
    end
    if #expressions < 2 then
        return nil, nil, "Fusion strategy " .. tostring(strategy) .. " for attribute '"
            .. tostring(attribute_key) .. "' has fewer than two active contributors."
    end
    return "COALESCE(" .. table.concat(expressions, ", ") .. ")", contributors, nil
end

local function select_attribute_bindings(ctx, dimensions, metrics, needed_entities)
    local required_by_entity = {}
    local function require_attribute(attribute_type, attribute)
        local entity_key = key(attribute.entity_id)
        required_by_entity[entity_key] = required_by_entity[entity_key] or {}
        required_by_entity[entity_key][attribute_type .. ":" .. key(attribute.id)] = attribute
    end
    for _, dimension in ipairs(dimensions or {}) do
        require_attribute("DIMENSION", dimension)
    end
    local required_facts = {}
    for _, metric in ipairs(metrics or {}) do
        collect_metric_facts(ctx, metric, required_facts, {})
    end
    for _, fact in pairs(required_facts) do require_attribute("FACT", fact) end

    ctx.selected_representations = {}
    for entity_id, _ in pairs(needed_entities or {}) do
        local entity = ctx.entity_by_id[key(entity_id)]
        if entity ~= nil then
            local attributes = required_by_entity[key(entity.id)] or {}
            local candidates = {}
            local incomplete_candidates = {}
            local representations = ctx.representations_by_entity[key(entity.id)] or {}
            if #representations == 0 and entity.primary_representation ~= nil then
                representations = {entity.primary_representation}
            end
            for _, representation in ipairs(representations) do
                local candidate = {
                    representation = representation,
                    bindings = {},
                    fallback_count = 0,
                    binding_priority = 0,
                    complete = true,
                    legacy_only = true,
                }
                local attribute_keys = {}
                for attribute_key, _ in pairs(attributes) do
                    attribute_keys[#attribute_keys + 1] = attribute_key
                end
                table.sort(attribute_keys)
                for _, attribute_key in ipairs(attribute_keys) do
                    local attribute = attributes[attribute_key]
                    local bindings = ctx.bindings_by_attribute[attribute_key] or {}
                    local selected = nil
                    for _, binding in ipairs(bindings) do
                        if key(binding.representation_id) == key(representation.id) then
                            selected = binding
                            break
                        end
                    end
                    if selected == nil and #bindings == 0
                        and upper(representation.role) == "PRIMARY" then
                        selected = {
                            id = nil,
                            representation_id = representation.id,
                            expression = attribute.expression,
                            role = "PREFER",
                            priority = 1,
                            legacy = true,
                        }
                    end
                    if selected == nil then
                        candidate.complete = false
                        candidate.missing_attribute_key = attribute_key
                        candidate.missing_attribute_name = attribute.name
                        break
                    end
                    candidate.bindings[attribute_key] = selected
                    if selected.legacy ~= true then candidate.legacy_only = false end
                    if upper(selected.role) == "FALLBACK" then
                        candidate.fallback_count = candidate.fallback_count + 1
                    end
                    candidate.binding_priority = candidate.binding_priority
                        + tonumber(selected.priority or 1)
                end
                for _, requirement in ipairs(
                    (ctx.relationship_requirements_by_entity or {})[key(entity.id)] or {}) do
                    if candidate.complete then
                        local route, route_error = relationship_candidate(ctx,
                            requirement, entity, representation)
                        if route == nil then
                            candidate.complete = false
                            candidate.relationship_error = route_error
                            candidate.relationship_name = requirement.relationship.name
                            candidate.relationship_side = requirement.side
                            ctx.relationship_candidate_rejections[#ctx.relationship_candidate_rejections + 1] = {
                                relationship_id = requirement.relationship.id,
                                relationship_name = requirement.relationship.name,
                                side = requirement.side,
                                entity_id = entity.id,
                                entity_name = entity.name,
                                representation_id = representation.id,
                                representation_name = representation.name,
                                reason = route_error,
                            }
                            break
                        end
                        candidate.relationship_routes = candidate.relationship_routes or {}
                        candidate.relationship_routes[key(requirement.relationship.id)
                            .. ":" .. requirement.side] = route
                    end
                end
                if candidate.complete then
                    candidates[#candidates + 1] = candidate
                else
                    incomplete_candidates[#incomplete_candidates + 1] = candidate
                end
            end
            table.sort(candidates, function(left, right)
                if left.fallback_count ~= right.fallback_count then
                    return left.fallback_count < right.fallback_count
                end
                if left.binding_priority ~= right.binding_priority then
                    return left.binding_priority < right.binding_priority
                end
                local left_is_primary = upper(left.representation.role) == "PRIMARY"
                local right_is_primary = upper(right.representation.role) == "PRIMARY"
                if left_is_primary ~= right_is_primary then return left_is_primary end
                local left_priority = tonumber(left.representation.priority or 1)
                local right_priority = tonumber(right.representation.priority or 1)
                if left_priority ~= right_priority then return left_priority < right_priority end
                return tonumber(left.representation.id) < tonumber(right.representation.id)
            end)
            local covered_count = 0
            for _, representation in ipairs(representations) do
                if not missing(representation.coverage_predicate) then
                    covered_count = covered_count + 1
                end
            end
            local partitioned = covered_count > 0
            if partitioned and covered_count ~= #representations then
                return nil, "Partitioned entity '" .. tostring(entity.name)
                    .. "' has incomplete coverage metadata."
            end
            if partitioned and #candidates ~= #representations then
                local incomplete = incomplete_candidates[1]
                if incomplete ~= nil then
                    return nil, "Attribute '" .. tostring(incomplete.missing_attribute_name
                        or incomplete.missing_attribute_key) .. "' has no binding on partition '"
                        .. tostring(incomplete.representation.name) .. "' of entity '"
                        .. tostring(entity.name)
                        .. "'. Add it with ADD_ATTRIBUTE_BINDING."
                end
                return nil, "No complete UNION binding set exists for every partition of entity '"
                    .. tostring(entity.name) .. "'."
            end
            for attribute_key, _ in pairs(attributes) do
                local policy = ctx.fusion_policy_by_attribute[attribute_key]
                local strategy = upper(policy and policy.strategy or "PREFER")
                if partitioned and strategy ~= "PREFER" then
                    return nil, "Entity '" .. tostring(entity.name)
                        .. "' cannot combine partition UNION with attribute strategy "
                        .. tostring(strategy) .. "."
                end
            end
            local selected = candidates[1]
            if selected == nil then
                local relationship_failure = nil
                for _, incomplete in ipairs(incomplete_candidates) do
                    if incomplete.relationship_name ~= nil then
                        relationship_failure = incomplete
                        break
                    end
                end
                if relationship_failure ~= nil then
                    return nil, "No active representation can traverse relationship '"
                        .. tostring(relationship_failure.relationship_name) .. "' on "
                        .. tostring(relationship_failure.relationship_side) .. " entity '"
                        .. tostring(entity.name) .. "': "
                        .. tostring(relationship_failure.relationship_error) .. "."
                end
                return nil, "No active representation provides every required attribute for entity '"
                    .. tostring(entity.name) .. "'. Add compatible PREFER/FALLBACK bindings."
            end
            local representation = selected.representation
            entity.source_schema = representation.source_schema
            entity.source_object = representation.source_object
            entity.alias = representation.alias
            entity.selected_representation = representation
            if partitioned then
                entity.fusion_strategy = "UNION"
                entity.fusion_candidates = candidates
            end
            for attribute_key, binding in pairs(selected.bindings) do
                local attribute_type, attribute_id = string.match(attribute_key, "^([^:]+):(.+)$")
                local attribute = attribute_type == "DIMENSION"
                    and ctx.dimension_by_id[key(attribute_id)] or ctx.fact_by_id[key(attribute_id)]
                if attribute ~= nil then
                    local policy = ctx.fusion_policy_by_attribute[attribute_key]
                    local strategy = upper(policy and policy.strategy or "PREFER")
                    if strategy == "COALESCE" or strategy == "RECONCILE" then
                        local fused_expression, contributors, fusion_error =
                            fused_attribute_expression(ctx, entity, representation,
                                attribute_key, strategy)
                        if fused_expression == nil then return nil, fusion_error end
                        attribute.expression = fused_expression
                        attribute.fusion_strategy = strategy
                        attribute.fusion_contributors = contributors
                        ctx.has_attribute_fusion = true
                        if attribute_type == "FACT" then
                            ctx.has_fact_fusion = true
                        end
                    else
                        attribute.expression = binding.expression
                        attribute.fusion_strategy = "PREFER"
                    end
                    attribute.selected_binding = binding
                end
            end
            ctx.selected_representations[key(entity.id)] = {
                representation = representation,
                fallback_count = selected.fallback_count,
                binding_priority = selected.binding_priority,
                bindings = selected.bindings,
                legacy_only = selected.legacy_only,
                fusion_strategy = partitioned and "UNION" or nil,
                candidates = partitioned and candidates or nil,
                relationship_routes = selected.relationship_routes or {},
            }
        end
    end
    return true, nil
end

local function apply_metric_filter(expression, filter_expr)
    if missing(filter_expr) then
        return expression
    end
    local inner = string.match(expression, "^%s*SUM%s*%((.*)%)%s*$")
    if inner ~= nil then
        return "SUM(CASE WHEN " .. tostring(filter_expr) .. " THEN " .. inner .. " ELSE 0 END)"
    end
    inner = string.match(expression, "^%s*COUNT%s*%((.*)%)%s*$")
    if inner ~= nil then
        return "COUNT(CASE WHEN " .. tostring(filter_expr) .. " THEN " .. inner .. " ELSE NULL END)"
    end
    return "CASE WHEN " .. tostring(filter_expr) .. " THEN " .. expression .. " ELSE NULL END"
end

local function expand_metric(ctx, metric, stack)
    stack = stack or {}
    local metric_key = key(metric.id)
    if stack[metric_key] then
        error("Cyclic metric dependency detected while expanding " .. tostring(metric.name))
    end
    stack[metric_key] = true
    local expanded = replace_identifiers(tostring(metric.expression), function(token)
        local normalized = upper(token)
        local fact = ctx.fact_by_name[normalized]
        if fact ~= nil then
            return "(" .. tostring(fact.expression) .. ")"
        end
        for _, candidate in ipairs(ctx.all_metrics or ctx.metrics) do
            if upper(candidate.name) == normalized then
                return "(" .. expand_metric(ctx, candidate, stack) .. ")"
            end
        end
        return nil
    end)
    stack[metric_key] = nil
    return apply_metric_filter(expanded, metric.filter_expr)
end

local function build_dimension_predicate(expression, op, value, data_type, value_sql)
    if op == "IS NULL" or op == "IS NOT NULL" then
        return expression .. " " .. op, nil
    end
    local rhs = value_sql or sql_text.sql_literal(value, data_type)
    local text_compare = value_sql == nil and is_text_type(data_type)
    if op == "=" or op == "!=" or op == "<>" or op == ">" or op == ">=" or op == "<" or op == "<=" or op == "LIKE" then
        if text_compare and (op == "=" or op == "!=" or op == "<>" or op == "LIKE") then
            return "UPPER(" .. expression .. ") " .. op .. " UPPER(" .. rhs .. ")"
        end
        return expression .. " " .. op .. " " .. rhs
    elseif op == "IN" then
        local values = as_array(value, "filter.value")
        if #values == 0 then
            return nil, error_result("SEMANTIC_REQUEST_032", "IN filter requires at least one value.")
        end
        local literals = {}
        for _, item in ipairs(values) do
            local literal = sql_text.sql_literal(item, data_type)
            if is_text_type(data_type) then
                literal = "UPPER(" .. literal .. ")"
            end
            literals[#literals + 1] = literal
        end
        if is_text_type(data_type) then
            return "UPPER(" .. expression .. ") IN (" .. table.concat(literals, ", ") .. ")", nil
        end
        return expression .. " IN (" .. table.concat(literals, ", ") .. ")", nil
    elseif op == "BETWEEN" then
        local values = as_array(value, "filter.value")
        if #values ~= 2 then
            return nil, error_result("SEMANTIC_REQUEST_032", "BETWEEN filter requires exactly two values.")
        end
        return expression .. " BETWEEN " .. sql_text.sql_literal(values[1], data_type) .. " AND " .. sql_text.sql_literal(values[2], data_type), nil
    end
    return nil, error_result("SEMANTIC_REQUEST_033", "Unsupported filter operator: " .. tostring(op) .. ". Supported operators: =, !=, <>, >, >=, <, <=, LIKE, IN, BETWEEN, IS NULL, IS NOT NULL.")
end

local function build_filters(ctx, request_filters, selected_dimensions, needed_entities)
    local filters = {}
    local filter_dimensions = {}
    local filter_seen = {}
    for _, filter in ipairs(as_array(request_filters, "filters")) do
        if type(filter) ~= "table" then
            return nil, nil, error_result("SEMANTIC_REQUEST_030", "Each filter must be an object.")
        end
        local filter_field = filter.field or filter.dimension or filter.column or filter.name
        if missing(filter_field) then
            return nil, nil, error_result("SEMANTIC_REQUEST_020", "Filter requires a field key. Accepted aliases: field, dimension, column, name.")
        end
        local field, err = resolve_field(ctx, filter_field, nil)
        if err ~= nil then
            return nil, nil, err
        end
        if field.kind ~= "DIMENSION" then
            return nil, nil, error_result("SEMANTIC_REQUEST_031", "MVP filters support dimensions only: " .. tostring(filter_field) .. ".")
        end
        local op = upper(filter.op or filter.operator or "=")
        if missing(filter.value) and missing(filter.value_sql) and op ~= "IS NULL" and op ~= "IS NOT NULL" then
            return nil, nil, error_result("SEMANTIC_REQUEST_015",
                "Filter for field '" .. tostring(field.name) .. "' requires a value or value_sql key.")
        end
        local expression = tostring(field.expression)
        local predicate, predicate_err = build_dimension_predicate(expression, op, filter.value, field.data_type, filter.value_sql)
        if predicate_err ~= nil then
            return nil, nil, predicate_err
        end
        filters[#filters + 1] = {
            field = field.name,
            field_id = field.id,
            field_kind = field.kind,
            entity_id = field.entity_id,
            op = op,
            value = filter.value,
            value_sql = filter.value_sql,
            data_type = field.data_type,
            expression = expression,
            predicate = predicate,
        }
        needed_entities[key(field.entity_id)] = true
        add_unique(filter_dimensions, filter_seen, field)
    end
    return filters, filter_dimensions, nil
end

local function collect_intrinsic_filter_dimensions(ctx, metrics, needed_entities)
    local dimensions = {}
    local seen = {}
    for _, metric in ipairs(metrics or {}) do
        local rows = query([[
            SELECT REQUIRED_DIMENSION_ID
            FROM SEMANTIC_SOURCE.METRIC_FILTERS
            WHERE METRIC_ID = :metric_id
              AND REQUIRED_DIMENSION_ID IS NOT NULL
            ORDER BY ORDINAL_POSITION
        ]], {metric_id = metric.id})
        for _, row in ipairs(rows or {}) do
            local dimension = ctx.dimension_by_id[key(row_value(row, "REQUIRED_DIMENSION_ID", 1))]
            if dimension ~= nil then
                needed_entities[key(dimension.entity_id)] = true
                add_unique(dimensions, seen, dimension)
            end
        end
    end
    return dimensions
end

local function validate_metric_dimensions(ctx, metrics, dimensions)
    for _, metric in ipairs(metrics) do
        for _, dimension in ipairs(dimensions) do
            local rows = query([[
                SELECT IS_VALID, REASON_CODE, RELATIONSHIP_PATH
                FROM SEMANTIC_SOURCE.METRIC_DIMENSION_MATRIX
                WHERE MODEL_ID = :model_id
                  AND VERSION_ID = :version_id
                  AND METRIC_ID = :metric_id
                  AND DIMENSION_ID = :dimension_id
            ]], {
                model_id = ctx.model.model_id,
                version_id = ctx.model.version_id,
                metric_id = metric.id,
                dimension_id = dimension.id,
            })
            if rows == nil or #rows == 0 then
                return error_result("SEMANTIC_REQUEST_040", "Missing validation matrix row for " .. tostring(metric.name) .. " and " .. tostring(dimension.name) .. ".")
            end
            local is_valid = row_value(rows[1], "IS_VALID", 1)
            if not boolish(is_valid) then
                return error_result("SEMANTIC_REQUEST_041", "Metric " .. tostring(metric.name) .. " cannot be grouped or filtered by dimension " .. tostring(dimension.name) .. ": " .. tostring(row_value(rows[1], "REASON_CODE", 2)) .. ".")
            end
        end
    end
    return nil
end

-- Turn a relationship proof that had to choose between safe paths into a plan
-- warning. The compiler picks the shortest safe path and refuses only a tie
-- (SEMANTIC_REQUEST_042 / AMBIGUOUS_RELATIONSHIP_PATH), so an alternative of a
-- different length is selected against silently. Path length is not a semantic
-- authority: the alternative can attribute a fact row to a different dimension
-- row, which changes the number. Say so instead of choosing quietly.
local function relationship_path_warnings(ctx, typed_plan)
    local warnings = {}
    for _, proof in ipairs((typed_plan or {}).relationship_proofs or {}) do
        if proof.status == "PROVEN" and #(proof.alternate_paths or {}) > 0 then
            local entity = ctx.entity_by_id[key(proof.to_entity_id)]
            local entity_name = entity ~= nil and entity.name
                or tostring(proof.to_entity_id)
            local alternates = table.concat(proof.alternate_paths, ", ")
            local message = "Entity " .. entity_name .. " is reachable by "
                .. tostring(#(proof.candidate_paths or {})) .. " safe relationship"
                .. " paths. Selected " .. tostring(proof.selected_path)
                .. " because it is the shortest; not selected: " .. alternates
                .. ". Paths can attribute a fact row to a different row of "
                .. entity_name .. ", so the selected path decides the number, and"
                .. " path length is not a statement about meaning. PATH_PRIORITY"
                .. " does not choose between them. Remove the redundant"
                .. " relationship, or model the paths as separate entities with"
                .. " their own dimensions, to make the choice explicit."
                .. " Proof mode STRICT_GRAIN refuses the request instead of"
                .. " choosing."
            warnings[#warnings + 1] = {
                code = "RELATIONSHIP_PATH_ALTERNATIVES",
                severity = "WARNING",
                target_entity_id = proof.to_entity_id,
                target_entity = entity_name,
                selected_path = proof.selected_path,
                selection_reason = proof.selection_reason or "SHORTEST_SAFE_PATH",
                candidate_paths = proof.candidate_paths or {},
                alternate_paths = proof.alternate_paths,
                message = message,
            }
        end
    end
    return warnings
end

local function plan_joins(ctx, needed_entities)
    local root_id = ctx.object.root_entity_id
    needed_entities[key(root_id)] = true
    local joins = {}
    local joined_entities = {[key(root_id)] = true}
    local joined_relationships = {}
    local relationship_paths = {}

    local entity_ids = {}
    for entity_id, _ in pairs(needed_entities) do
        if entity_id ~= key(root_id) then
            entity_ids[#entity_ids + 1] = entity_id
        end
    end
    table.sort(entity_ids)

    for _, entity_id in ipairs(entity_ids) do
        local path = find_path(ctx, root_id, entity_id)
        if path == nil then
            local entity = ctx.entity_by_id[entity_id]
            local proof = ctx._last_path_proof or {}
            if proof.reason == "AMBIGUOUS_RELATIONSHIP_PATH" then
                return nil, nil, error_result(
                    "SEMANTIC_REQUEST_042",
                    "Ambiguous safe relationship path from semantic object root to entity "
                        .. tostring(entity and entity.name or entity_id) .. ": "
                        .. table.concat(proof.candidate_paths or {}, " | ") .. "."
                )
            end
            -- Name the edge that blocked the walk. Without it a many-to-many
            -- refusal is indistinguishable from a missing relationship, and the
            -- modeler cannot tell which one to fix. Same phrasing as the
            -- validator's compatibility matrix.
            local _, all_edges = relationship_edges(ctx)
            local blocked_path, blocked_reason = grain_graph.attempted_path(
                all_edges, root_id, entity_id)
            local detail = ""
            if blocked_reason ~= nil and blocked_path ~= nil then
                detail = ": " .. tostring(blocked_reason) .. " via " .. tostring(blocked_path)
            end
            return nil, nil, error_result("SEMANTIC_REQUEST_042",
                "No safe relationship path from semantic object root to entity "
                    .. tostring(entity and entity.name or entity_id) .. detail .. ".")
        end
        local path_names = {}
        for _, edge in ipairs(path) do
            local relationship = edge.relationship
            path_names[#path_names + 1] = relationship.name
            local join_key = key(relationship.id)
            local to_entity_key = key(edge.to_entity_id)
            needed_entities[to_entity_key] = true
            if not joined_relationships[join_key] and not joined_entities[to_entity_key] then
                joins[#joins + 1] = {
                    relationship = relationship,
                    entity = ctx.entity_by_id[to_entity_key],
                }
                joined_relationships[join_key] = true
                joined_entities[to_entity_key] = true
            end
        end
        relationship_paths[#relationship_paths + 1] = table.concat(path_names, " > ")
    end
    return joins, relationship_paths, nil
end

local function configure_relationship_requirements(ctx, joins)
    ctx.relationship_requirements_by_entity = {}
    for _, join in ipairs(joins or {}) do
        local relationship = join.relationship
        if #(relationship.key_mappings or {}) > 0 then
            for _, endpoint in ipairs({
                {side = "from", entity_id = relationship.from_entity_id},
                {side = "to", entity_id = relationship.to_entity_id},
            }) do
                local entity_key = key(endpoint.entity_id)
                ctx.relationship_requirements_by_entity[entity_key] =
                    ctx.relationship_requirements_by_entity[entity_key] or {}
                ctx.relationship_requirements_by_entity[entity_key][#ctx.relationship_requirements_by_entity[entity_key] + 1] = {
                    relationship = relationship,
                    side = endpoint.side,
                }
            end
        end
    end
end

local function replace_qualified_column(expression, source_alias, source_column,
        replacement)
    local text = tostring(expression)
    local out = {}
    local i = 1
    local in_string = false
    while i <= #text do
        local char = string.sub(text, i, i)
        local next_char = string.sub(text, i + 1, i + 1)
        if char == "'" then
            out[#out + 1] = char
            if in_string and next_char == "'" then
                out[#out + 1] = next_char
                i = i + 2
            else
                in_string = not in_string
                i = i + 1
            end
        elseif not in_string and string.match(char, "[A-Za-z_]") then
            local alias_end = i + 1
            while alias_end <= #text
                and string.match(string.sub(text, alias_end, alias_end), "[A-Za-z0-9_]") do
                alias_end = alias_end + 1
            end
            local alias = string.sub(text, i, alias_end - 1)
            local cursor = alias_end
            while string.match(string.sub(text, cursor, cursor), "%s") do cursor = cursor + 1 end
            if upper(alias) == upper(source_alias)
                and string.sub(text, cursor, cursor) == "." then
                cursor = cursor + 1
                while string.match(string.sub(text, cursor, cursor), "%s") do cursor = cursor + 1 end
                local column = nil
                local column_end = cursor
                if string.sub(text, cursor, cursor) == '"' then
                    local parts = {}
                    column_end = cursor + 1
                    while column_end <= #text do
                        local current = string.sub(text, column_end, column_end)
                        local following = string.sub(text, column_end + 1, column_end + 1)
                        if current == '"' and following == '"' then
                            parts[#parts + 1] = '"'
                            column_end = column_end + 2
                        elseif current == '"' then
                            column = table.concat(parts)
                            column_end = column_end + 1
                            break
                        else
                            parts[#parts + 1] = current
                            column_end = column_end + 1
                        end
                    end
                else
                    local start_pos, end_pos, value = string.find(text,
                        "([A-Za-z_][A-Za-z0-9_]*)", cursor)
                    if start_pos == cursor then
                        column = value
                        column_end = end_pos + 1
                    end
                end
                if column ~= nil and upper(column) == upper(source_column) then
                    out[#out + 1] = tostring(replacement)
                    i = column_end
                else
                    out[#out + 1] = alias
                    i = alias_end
                end
            else
                out[#out + 1] = alias
                i = alias_end
            end
        else
            out[#out + 1] = char
            i = i + 1
        end
    end
    return table.concat(out)
end

local function relationship_join_condition(ctx, relationship)
    local condition = tostring(relationship.join_condition)
    local provenance = {}
    for _, endpoint in ipairs({
        {side = "from", entity_id = relationship.from_entity_id},
        {side = "to", entity_id = relationship.to_entity_id},
    }) do
        local entity = ctx.entity_by_id[key(endpoint.entity_id)]
        local selection = entity and ctx.selected_representations
            and ctx.selected_representations[key(entity.id)] or nil
        local route = selection and selection.relationship_routes[
            key(relationship.id) .. ":" .. endpoint.side] or nil
        if route ~= nil and route.kind == "DIRECT_IDENTITY" then
            condition = replace_qualified_column(condition, entity.alias,
                route.column_name, route.binding.expression)
            provenance[#provenance + 1] = {
                relationship_id = relationship.id,
                relationship_name = relationship.name,
                side = endpoint.side,
                entity_id = entity.id,
                entity_name = entity.name,
                representation_id = selection.representation.id,
                representation_name = selection.representation.name,
                semantic_identity_id = route.identity.id,
                semantic_identity_name = route.identity.name,
                identity_binding_id = route.binding.id,
                identity_mapping_id = nil,
                source_expression = route.binding.expression,
                unique_key_id = route.unique_key.id,
            }
        end
    end
    return condition, provenance
end

local function build_order_by(ctx, request_order_by, output_fields)
    local clauses = {}
    for _, item in ipairs(as_array(request_order_by, "order_by")) do
        if type(item) ~= "table" then
            return nil, error_result("SEMANTIC_REQUEST_060", "Each order_by item must be an object.")
        end
        local field, err = resolve_field(ctx, item.field, nil)
        if err ~= nil then
            return nil, err
        end
        if not output_fields[field.kind .. ":" .. key(field.id)] then
            return nil, error_result("SEMANTIC_REQUEST_061", "ORDER BY field must be selected in the MVP: " .. tostring(item.field) .. ".")
        end
        local direction = upper(item.direction or "ASC")
        if direction ~= "ASC" and direction ~= "DESC" then
            return nil, error_result("SEMANTIC_REQUEST_062", "Unsupported ORDER BY direction: " .. tostring(item.direction) .. ".")
        end
        clauses[#clauses + 1] = quote_alias(field.name) .. " " .. direction
    end
    return clauses, nil
end

local function build_sql(ctx, dimensions, metrics, filters, joins, order_by, limit, having_predicates)
    local root = ctx.entity_by_id[key(ctx.object.root_entity_id)]
    local select_parts = {}
    local group_parts = {}
    local join_sql = {}
    local where_predicates = {}
    for _, dimension in ipairs(dimensions) do
        select_parts[#select_parts + 1] = tostring(dimension.expression) .. " AS " .. quote_alias(dimension.name)
        group_parts[#group_parts + 1] = tostring(dimension.expression)
    end
    for _, metric in ipairs(metrics) do
        select_parts[#select_parts + 1] = expand_metric(ctx, metric) .. " AS " .. quote_alias(metric.name)
    end

    local function append_fusion_joins(entity)
        for _, fusion_join in ipairs(entity.fusion_joins or {}) do
            local representation = fusion_join.representation
            join_sql[#join_sql + 1] = "LEFT JOIN "
                .. (fusion_join.source_sql or sql_text.quote_qualified(
                    representation.source_schema, representation.source_object))
                .. " " .. fusion_join.alias
                .. " ON " .. table.concat(fusion_join.predicates, " AND ")
        end
    end
    append_fusion_joins(root)
    for _, join in ipairs(joins) do
        local join_condition, remaps = relationship_join_condition(ctx,
            join.relationship)
        for _, remap in ipairs(remaps) do
            ctx.relationship_identity_remaps[#ctx.relationship_identity_remaps + 1] = remap
        end
        join_sql[#join_sql + 1] = tostring(join.relationship.join_type or "LEFT") .. " JOIN "
            .. sql_text.quote_qualified(join.entity.source_schema, join.entity.source_object)
            .. " " .. tostring(join.entity.alias)
            .. " ON " .. join_condition
        append_fusion_joins(join.entity)
    end
    for _, filter in ipairs(filters) do
        where_predicates[#where_predicates + 1] = filter.predicate
    end
    return grain_sql_runtime.render_single_branch({
        select_parts = select_parts,
        from_sql = sql_text.quote_qualified(root.source_schema, root.source_object)
            .. " " .. tostring(root.alias),
        join_sql = join_sql,
        where_predicates = where_predicates,
        group_parts = group_parts,
        having_predicates = having_predicates or {},
        order_by = order_by,
        limit = limit,
    })
end

local function build_materialized_sql(ctx, dimensions, metrics, filters, order_by, limit, materialization)
    local alias = "mat"
    local select_parts = {}
    local group_parts = {}
    local uses_aggregate = false
    for _, dimension in ipairs(dimensions) do
        local column = materialization.columns[dimension.kind .. ":" .. key(dimension.id)]
        local expression = quote_column(alias, column.physical_column)
        select_parts[#select_parts + 1] = expression .. " AS " .. quote_alias(dimension.name)
        group_parts[#group_parts + 1] = expression
    end
    for _, metric in ipairs(metrics) do
        local metric_key = metric.kind .. ":" .. key(metric.id)
        local column = materialization.columns[metric_key]
        local column_expression = quote_column(alias, column.physical_column)
        local policy = materialization.metric_rollup_policies and materialization.metric_rollup_policies[metric_key] or "DIRECT"
        local expression = column_expression
        if policy == "SUM" then
            expression = "SUM(" .. column_expression .. ")"
            uses_aggregate = true
        elseif policy == "MIN" then
            expression = "MIN(" .. column_expression .. ")"
            uses_aggregate = true
        elseif policy == "MAX" then
            expression = "MAX(" .. column_expression .. ")"
            uses_aggregate = true
        elseif policy == "COUNT" then
            expression = "SUM(" .. column_expression .. ")"
            uses_aggregate = true
        end
        select_parts[#select_parts + 1] = expression .. " AS " .. quote_alias(metric.name)
    end

    local sql_parts = {}
    sql_parts[#sql_parts + 1] = "SELECT " .. table.concat(select_parts, ", ")
    sql_parts[#sql_parts + 1] = "FROM " .. sql_text.quote_qualified(materialization.physical_schema, materialization.physical_object) .. " " .. alias
    if #filters > 0 then
        local predicates = {}
        for _, filter in ipairs(filters) do
            local column = materialization.columns[tostring(filter.field_kind) .. ":" .. key(filter.field_id)]
            local predicate, predicate_err = build_dimension_predicate(
                quote_column(alias, column.physical_column),
                filter.op,
                filter.value,
                filter.data_type,
                filter.value_sql
            )
            if predicate_err ~= nil then
                error(predicate_err.error_message or "Invalid materialized filter predicate.")
            end
            predicates[#predicates + 1] = predicate
        end
        sql_parts[#sql_parts + 1] = "WHERE " .. table.concat(predicates, " AND ")
    end
    if uses_aggregate and #group_parts > 0 then
        sql_parts[#sql_parts + 1] = "GROUP BY " .. table.concat(group_parts, ", ")
    end
    if #order_by > 0 then
        sql_parts[#sql_parts + 1] = "ORDER BY " .. table.concat(order_by, ", ")
    end
    if limit ~= nil then
        sql_parts[#sql_parts + 1] = "LIMIT " .. tostring(limit)
    end
    return table.concat(sql_parts, "\n")
end

local function log_request(result, request_json, request, model)
    local request_model_id = model and model.model_id or null
    local request_version_id = model and model.version_id or null
    local dimensions = request and request.dimensions or {}
    local metrics = request and request.metrics or {}
    query([[
        INSERT INTO SYS_SEMANTIC.AGENT_REQUEST_LOG (
          MODEL_ID, VERSION_ID, CLIENT_NAME, PURPOSE, NATURAL_LANGUAGE_TEXT,
          REQUEST_JSON, GENERATED_SQL,
          PLAN_JSON, REQUESTED_METRICS, REQUESTED_DIMENSIONS, STATUS, ERROR_CODE, ERROR_MESSAGE,
          CACHE_HIT, FINISHED_AT, RUNTIME_MS
        ) VALUES (
          :model_id, :version_id, :client_name, :purpose, :natural_language_text,
          :request_json, :generated_sql,
          :plan_json, :requested_metrics, :requested_dimensions, :status, :error_code, :error_message,
          :cache_hit, CURRENT_TIMESTAMP, :runtime_ms
        )
    ]], {
        model_id = null_if_missing(request_model_id),
        version_id = null_if_missing(request_version_id),
        client_name = request and null_if_missing(request.client) or null,
        purpose = request and null_if_missing(request.purpose) or null,
        -- COMPILE_REQUEST_SCHEMA_FOR_AGENT tells an agent that
        -- `natural_language_text` is "retained as request metadata", and the
        -- column exists to hold it. The INSERT omitted it, so the promise was
        -- kept only accidentally, by REQUEST_JSON storing the request whole.
        natural_language_text = request and null_if_missing(request.natural_language_text) or null,
        request_json = null_if_missing(request_json),
        generated_sql = null_if_missing(result.generated_sql),
        plan_json = null_if_missing(result.plan_json),
        requested_metrics = null_if_missing(json.encode(metrics)),
        requested_dimensions = null_if_missing(json.encode(dimensions)),
        status = null_if_missing(result.status),
        error_code = null_if_missing(result.error_code),
        error_message = null_if_missing(result.error_message),
        cache_hit = result.cache_hit == true,
        runtime_ms = null_if_missing(result.planning_runtime_ms),
    })
    result.agent_request_id = scalar([[
        SELECT MAX(AGENT_REQUEST_ID)
        FROM SEMANTIC_SOURCE.MY_AGENT_REQUESTS
    ]])
end

-- `want_id` reads the row back so a caller can hand the id to
-- EXPLAIN_COMPILED_SQL. The preprocessor lane passes false: nothing there can
-- return an id to anybody, and the read-back is a second statement on the path
-- every semantic query in the session takes.
local function log_query_result(result, original_sql, request, model, client_name, want_id)
    local request_model_id = model and model.model_id or null
    local request_version_id = model and model.version_id or null
    -- NULL, not `[]`, when there is no canonical request to read them from.
    -- EXPLAIN_COMPILED_SQL falls back to PLAN_JSON for these two columns, and
    -- that fallback tests whether the column is missing -- an empty array is
    -- present, so writing one suppresses the fallback and reports a statement as
    -- having asked for no fields at all. The preprocessor lane has no request on
    -- a cache hit or an expansion, which is most of what it logs.
    local dimensions = request and request.dimensions or nil
    local metrics = request and request.metrics or nil
    query([[
        INSERT INTO SYS_SEMANTIC.QUERY_LOG (
          MODEL_ID, VERSION_ID, CLIENT_NAME, ORIGINAL_SQL, GENERATED_SQL,
          PLAN_JSON, REQUESTED_DIMENSIONS, REQUESTED_METRICS, MATERIALIZATION_USED,
          STATUS, ERROR_CODE,
          ERROR_MESSAGE, FINISHED_AT, RUNTIME_MS
        ) VALUES (
          :model_id, :version_id, :client_name, :original_sql, :generated_sql,
          :plan_json, :requested_dimensions, :requested_metrics, :materialization_used,
          :status, :error_code,
          :error_message, CURRENT_TIMESTAMP, :runtime_ms
        )
    ]], {
        model_id = null_if_missing(request_model_id),
        version_id = null_if_missing(request_version_id),
        client_name = null_if_missing(client_name or "COMPILE_SQL_DEBUG"),
        original_sql = null_if_missing(original_sql),
        generated_sql = null_if_missing(result.generated_sql),
        plan_json = null_if_missing(result.plan_json),
        requested_dimensions = dimensions ~= nil
            and null_if_missing(json.encode(dimensions)) or null,
        requested_metrics = metrics ~= nil
            and null_if_missing(json.encode(metrics)) or null,
        materialization_used = null_if_missing(result.materialization_used),
        status = null_if_missing(result.status),
        error_code = null_if_missing(result.error_code),
        error_message = null_if_missing(result.error_message),
        runtime_ms = null_if_missing(result.planning_runtime_ms),
    })
    if want_id == false then
        return
    end
    result.query_log_id = scalar([[
        SELECT MAX(QUERY_LOG_ID)
        FROM SEMANTIC_SOURCE.MY_QUERY_LOG
    ]])
end

local function latest_successful_validation(model)
    local rows = query([[
        SELECT VALIDATION_RUN_ID, STATUS, ERROR_COUNT
        FROM SEMANTIC_SOURCE.VALIDATION_RUNS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS IN ('OK', 'WARNING')
          AND ERROR_COUNT = 0
        ORDER BY VALIDATION_RUN_ID DESC
        LIMIT 1
    ]], {model_id = model.model_id, version_id = model.version_id})
    if rows == nil or #rows == 0 then
        local latest_rows = query([[
            SELECT STATUS, ERROR_COUNT
            FROM SEMANTIC_SOURCE.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id
              AND VERSION_ID = :version_id
            ORDER BY VALIDATION_RUN_ID DESC
            LIMIT 1
        ]], {model_id = model.model_id, version_id = model.version_id})
        if latest_rows ~= nil and #latest_rows > 0 then
            local status = tostring(row_value(latest_rows[1], "STATUS", 1) or "UNKNOWN")
            if status == "STALE" then
                return nil, "The active catalog version changed after its last successful validation. This release edits the published version in place, so its published surface is unavailable until VALIDATE_MODEL succeeds."
            end
            return nil, "The latest validation status is " .. status
                .. " with " .. tostring(row_value(latest_rows[1], "ERROR_COUNT", 2) or 0)
                .. " error(s)."
        end
        return nil, "No validation run exists for this model version."
    end
    return row_value(rows[1], "VALIDATION_RUN_ID", 1), nil
end

-- A schema that PUBLISH_MODEL created (it always creates SEMANTIC_DISCOVERY)
-- but that no active model claims any more.
local function orphaned_published_schema(published_schema)
    local rows = query([[
        SELECT COUNT(*) AS DISCOVERY_COUNT
        FROM SYS.EXA_ALL_TABLES
        WHERE (TABLE_SCHEMA = :schema_name OR TABLE_SCHEMA = UPPER(:schema_name))
          AND TABLE_NAME = 'SEMANTIC_DISCOVERY'
    ]], {schema_name = published_schema})
    if rows == nil or #rows == 0 then return false end
    return tonumber(row_value(rows[1], "DISCOVERY_COUNT", 1) or 0) > 0
end

-- More than one model can carry the same PUBLISHED_SCHEMA, so this has to choose
-- rather than take whichever row the database happened to return first. It
-- prefers the model that actually contains the object being asked for, then the
-- one with an active version, then the lowest id -- deterministic at every step.
--
-- Picking arbitrarily was survivable only while nothing else depended on the
-- choice: a model without the object resolves, and the caller is told their
-- object does not exist while it sits in the model next to it.
local function load_model_by_published_schema(schema_name, object_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.MODEL_NAME, m.ACTIVE_VERSION_ID AS VERSION_ID,
               mv.VERSION_NUMBER, m.GOVERNANCE_MODE
        FROM SEMANTIC_SOURCE.MODELS m
        LEFT JOIN SEMANTIC_SOURCE.MODEL_VERSIONS mv
          ON mv.VERSION_ID = m.ACTIVE_VERSION_ID
        LEFT JOIN SEMANTIC_SOURCE.SEMANTIC_OBJECTS so
          ON so.MODEL_ID = m.MODEL_ID
         AND so.VERSION_ID = m.ACTIVE_VERSION_ID
         AND so.STATUS = 'ACTIVE'
         AND UPPER(so.OBJECT_NAME) = UPPER(:object_name)
        WHERE UPPER(m.PUBLISHED_SCHEMA) = UPPER(:schema_name)
        ORDER BY CASE WHEN so.OBJECT_ID IS NULL THEN 1 ELSE 0 END,
                 CASE WHEN m.ACTIVE_VERSION_ID IS NULL THEN 1 ELSE 0 END,
                 m.MODEL_ID
    ]], {schema_name = schema_name, object_name = object_name})
    if rows == nil or #rows == 0 then
        return nil
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        model_name = row_value(rows[1], "MODEL_NAME", 2),
        version_id = row_value(rows[1], "VERSION_ID", 3),
        version_number = row_value(rows[1], "VERSION_NUMBER", 4),
        governance_mode = row_value(rows[1], "GOVERNANCE_MODE", 5),
    }
end

local function compile_request_table(request, options)
    options = options or {}
    local error_prefix = options.error_prefix or "SEMANTIC_REQUEST"
    local normalized_request, query_spec_error = query_spec_runtime.new(
        request, options.source or request.source or "JSON"
    )
    if normalized_request == nil then
        return error_result(error_prefix .. "_001",
            "Invalid canonical query specification: " .. tostring(query_spec_error) .. ".")
    end
    request = normalized_request
    if request.proof_mode ~= "LEGACY_JOIN" and request.proof_mode ~= "STRICT_GRAIN" then
        return error_result(error_prefix .. "_071",
            "Unsupported proof_mode: " .. tostring(request.proof_mode) .. ".")
    end

    local ok_model_name, model_name = pcall(normalize_name, request.model, "model")
    if not ok_model_name then
        return error_result(error_prefix .. "_002", tostring(model_name) .. ".")
    end
    local ok_object_name, object_name = pcall(normalize_name, request.object, "object")
    if not ok_object_name then
        return error_result(error_prefix .. "_003", tostring(object_name) .. ".")
    end

    local model = options.model or load_model(model_name)
    if model == nil then
        -- The model is absent *from what this caller may see*, which is the
        -- same answer for a model that does not exist and one that exists but
        -- was granted to somebody else. Saying so is the point: before the
        -- catalog reads were principal-scoped, an unauthorized model failed
        -- much later and much worse -- the source-column probe found nothing,
        -- the planner concluded no representation could traverse a
        -- relationship, and an authorization outcome was reported as
        -- SEMANTIC_REQUEST_080, a modelling defect. That sent modellers looking
        -- for a bug that did not exist. One code, and a message that names the
        -- other possibility, costs nothing and points at GRANT_MODEL_ROLE.
        return error_result(error_prefix .. "_011",
            "Model not found: " .. model_name
            .. ". It does not exist, or it is not granted to you"
            .. " -- see SEMANTIC_SOURCE.AUTHORIZED_MODELS for the models you can read.")
    end

    -- Compile-cache fast path: hit returns the stored GENERATED_SQL + PLAN_JSON
    -- without re-running catalog load, matrix lookup, join planning, materialization
    -- selection, or SQL emission. Cache writes happen further down the function
    -- only when the full compile succeeded (so error results never get cached).
    local cache_key = nil
    if options.cache ~= false and not missing(model.version_id) then
        cache_key = compile_cache.compile_cache_key(compile_cache.canonical_request_text(request))
        if cache_key ~= nil then
            local cached = compile_cache.cache_lookup(model.version_id, cache_key)
            if cached ~= nil then
                compile_cache.cache_touch(model.version_id, cache_key)
                local result = compile_cache.cached_ok_result(cached)
                if error_prefix ~= "SEMANTIC_REQUEST" then
                    envelope.recode_error_prefix(result, error_prefix)
                end
                return result, request, model
            end
        end
    end

    local planning_started_ms = envelope.monotonic_ms()
    -- The Semantic SQL lane already loaded this object's catalog to resolve the
    -- field names in its SELECT list, so it hands the context over rather than
    -- paying for it twice. Reuse only on an exact identity match -- same model
    -- table, same object -- and fall back to loading otherwise, so a caller that
    -- passes the wrong context loses the optimisation instead of the answer.
    local ctx, load_code, load_message = options.ctx, nil, nil
    if ctx ~= nil and not (ctx.model == model and ctx.object ~= nil
            and upper(tostring(ctx.object.name)) == upper(tostring(object_name))) then
        ctx = nil
    end
    if ctx == nil then
        ctx, load_code, load_message = load_catalog(model, object_name)
    end
    if ctx == nil then
        return error_result(load_code, load_message)
    end

    -- `DISPLAY_POLICY = 'MASK'` says the value may not be shown. It is enforced
    -- by refusing to *return* the field, not by substituting a redacted value,
    -- and that choice is deliberate: ESV groups by every selected dimension, so
    -- masking a dimension's output would either collapse every row into one
    -- group or emit a column of identical placeholders beside real counts.
    -- Either one silently changes what the number means, which is the failure
    -- this layer exists to prevent. Filtering on a masked field still works --
    -- slice by it without seeing it -- which is the useful half.
    local function refuse_masked(field, field_name)
        -- `missing`, not `~= nil`: an unset DISPLAY_POLICY arrives as truthy
        -- userdata, so the comparison has to survive that before it compares.
        if field ~= nil and not missing(field.display_policy)
            and upper(tostring(field.display_policy)) == "MASK" then
            return error_result(error_prefix .. "_024",
                "Field " .. tostring(field_name) .. " carries DISPLAY_POLICY = 'MASK',"
                .. " so its value is not returned. You can still filter on it.")
        end
        return nil
    end

    local selected_dimensions = {}
    local selected_dimension_seen = {}
    for _, dimension_name in ipairs(as_array(request.dimensions, "dimensions")) do
        local field, err = resolve_field(ctx, dimension_name, "DIMENSION")
        if err ~= nil then
            return err
        end
        local masked = refuse_masked(field, dimension_name)
        if masked ~= nil then
            return masked
        end
        add_unique(selected_dimensions, selected_dimension_seen, field)
    end

    local selected_metrics = {}
    local selected_metric_seen = {}
    for _, metric_name in ipairs(as_array(request.metrics, "metrics")) do
        local field, err = resolve_field(ctx, metric_name, "METRIC")
        if err ~= nil then
            return err
        end
        local masked = refuse_masked(field, metric_name)
        if masked ~= nil then
            return masked
        end
        add_unique(selected_metrics, selected_metric_seen, field)
    end
    -- Dimension-only discovery (BUG-D-003): allow an empty metrics list as long
    -- as dimensions is non-empty. Compiles to a deduplicated GROUP BY over the
    -- dimensions - the same shape a dashboard needs to populate facet filters
    -- without having to fake an unused metric.
    if #selected_metrics == 0 and #selected_dimensions == 0 then
        return error_result("SEMANTIC_REQUEST_023",
            "At least one metric or dimension is required.")
    end

    local needed_entities = {[key(ctx.object.root_entity_id)] = true}
    local all_dimensions = {}
    local all_dimension_seen = {}
    for _, dimension in ipairs(selected_dimensions) do
        add_unique(all_dimensions, all_dimension_seen, dimension)
        needed_entities[key(dimension.entity_id)] = true
    end
    for _, metric in ipairs(selected_metrics) do
        collect_metric_entities(ctx, metric, needed_entities, {})
    end

    local filters, filter_dimensions, filter_err = build_filters(ctx, request.filters, selected_dimensions, needed_entities)
    if filter_err ~= nil then
        return filter_err
    end
    local filter_dimension_seen = {}
    for _, dimension in ipairs(filter_dimensions) do
        filter_dimension_seen[dimension.kind .. ":" .. key(dimension.id)] = true
    end
    local intrinsic_filter_dimensions = collect_intrinsic_filter_dimensions(ctx, selected_metrics, needed_entities)
    for _, dimension in ipairs(intrinsic_filter_dimensions) do
        add_unique(filter_dimensions, filter_dimension_seen, dimension)
    end
    for _, dimension in ipairs(filter_dimensions) do
        add_unique(all_dimensions, all_dimension_seen, dimension)
    end

    local validation_run_id = nil
    if options.validate == false then
        local validation_message
        validation_run_id, validation_message = latest_successful_validation(model)
        if validation_run_id == nil then
            return error_result(error_prefix .. "_010",
                "Model validation is missing or stale: " .. validation_message
                .. " Run EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('" .. tostring(model.model_name) .. "') (or PUBLISH_MODEL) before compiling.")
        end
    else
        local validation_errors
        validation_errors, validation_run_id = validate_model(model)
        local referenced = collect_referenced_validation_objects(ctx, selected_metrics, all_dimensions)
        for _, validation_error in ipairs(validation_errors) do
            if validation_error_applies(validation_error, referenced) then
                return error_result(error_prefix .. "_010", "Model validation failed: " .. tostring(validation_error.code) .. " " .. tostring(validation_error.message))
            end
        end
    end

    local limit = nil
    if not missing(request.limit) then
        limit = tonumber(request.limit)
        -- Zero is allowed: JDBC/ODBC drivers issue `LIMIT 0` during schema
        -- discovery to learn a result's shape without fetching it, and refusing
        -- that can fail a tool before the user has run anything.
        if limit == nil or limit < 0 or limit % 1 ~= 0 then
            return error_result("SEMANTIC_REQUEST_050", "LIMIT must be a non-negative integer.")
        end
        if limit > MAX_LIMIT then
            return error_result("SEMANTIC_REQUEST_051", "LIMIT exceeds maximum " .. tostring(MAX_LIMIT) .. ".")
        end
    end

    local output_fields = {}
    for _, dimension in ipairs(selected_dimensions) do
        output_fields[dimension.kind .. ":" .. key(dimension.id)] = true
    end
    for _, metric in ipairs(selected_metrics) do
        output_fields[metric.kind .. ":" .. key(metric.id)] = true
    end
    local order_by, order_err = build_order_by(ctx, request.order_by, output_fields)
    if order_err ~= nil then
        return order_err
    end

    local having_predicates = {}
    local bound_having_filters = {}
    local planning_metrics = {}
    local planning_metric_seen = {}
    for _, metric in ipairs(selected_metrics) do
        add_unique(planning_metrics, planning_metric_seen, metric)
    end
    local having_list = as_array(request.having, "having")
    if #having_list > 0 and #selected_metrics == 0 then
        return error_result("SEMANTIC_REQUEST_026",
            "HAVING requires at least one metric in the request.")
    end
    for _, having_filter in ipairs(having_list) do
        if type(having_filter) ~= "table" then
            return error_result("SEMANTIC_REQUEST_030", "Each having filter must be an object.")
        end
        local filter_field = having_filter.field or having_filter.dimension or having_filter.column or having_filter.name
        if missing(filter_field) then
            -- SEMANTIC_REQUEST_025: having filter structure error (missing field key), distinct from
            -- SEMANTIC_REQUEST_020 (unknown field name) so agents can handle each differently.
            return error_result("SEMANTIC_REQUEST_025", "Having filter requires a field key. Accepted aliases: field, dimension, column, name.")
        end
        local metric_field, having_err = resolve_field(ctx, filter_field, "METRIC")
        if having_err ~= nil then
            return having_err
        end
        add_unique(planning_metrics, planning_metric_seen, metric_field)
        collect_metric_entities(ctx, metric_field, needed_entities, {})
        local op = upper(having_filter.op or having_filter.operator or "=")
        if missing(having_filter.value) and missing(having_filter.value_sql)
            and op ~= "IS NULL" and op ~= "IS NOT NULL" then
            return error_result("SEMANTIC_REQUEST_015",
                "Having filter for field '" .. tostring(metric_field.name)
                .. "' requires a value or value_sql key.")
        end
        local expr = expand_metric(ctx, metric_field)
        local predicate, predicate_err = build_dimension_predicate(expr, op, having_filter.value, metric_field.data_type, having_filter.value_sql)
        if predicate_err ~= nil then
            return predicate_err
        end
        having_predicates[#having_predicates + 1] = predicate
        bound_having_filters[#bound_having_filters + 1] = {
            metric_id = metric_field.id,
            metric = metric_field.name,
            op = op,
            value = having_filter.value,
            value_sql = having_filter.value_sql,
            data_type = metric_field.data_type,
        }
    end


    local metric_base_entities = {}
    for _, planning_metric in ipairs(planning_metrics) do
        metric_base_entities[key(planning_metric.base_entity_id)] = true
        local planning_facts = {}
        collect_metric_facts(ctx, planning_metric, planning_facts, {})
        for _, planning_fact in pairs(planning_facts) do
            metric_base_entities[key(planning_fact.entity_id)] = true
        end
    end
    local metric_base_entity_count = 0
    for _, _ in pairs(metric_base_entities) do
        metric_base_entity_count = metric_base_entity_count + 1
    end
    local joins, relationship_paths = {}, {}
    if metric_base_entity_count <= 1 then
        local join_err
        joins, relationship_paths, join_err = plan_joins(ctx, needed_entities)
        if join_err ~= nil then return join_err end
        configure_relationship_requirements(ctx, joins)
    end

    local binding_ok, binding_error = select_attribute_bindings(
        ctx, all_dimensions, planning_metrics, needed_entities)
    if binding_ok == nil then
        -- The same shape as the model-authorization case above, one level down.
        -- A caller who cannot read a physical source gets an empty source-column
        -- probe, and the planner concludes from that that no representation can
        -- traverse the relationship -- reporting an authorization outcome as a
        -- modelling defect and sending the reader to look for a bug that is not
        -- there. The compiler runs with the caller's rights, so being authorized
        -- for the model is not the same as being able to read what it is built
        -- on. Named as a possibility, not asserted: this code fires for genuine
        -- modelling defects too, and for those the sentence costs one line.
        return error_result(error_prefix .. "_080", tostring(binding_error)
            .. " If the model is otherwise sound, check that you can read the"
            .. " relations it is built on: the compiler runs with your rights, so"
            .. " a model you are authorized for still needs SELECT on its"
            .. " physical sources."
            .. " SEMANTIC_CATALOG.SOURCE_TRUST_FOR_MODEL lists them.")
    end

    -- Filters and HAVING expressions were resolved while discovering required
    -- attributes. Rebuild them after representation selection so fallback
    -- expressions are used consistently in WHERE and HAVING.
    filters, _, filter_err = build_filters(
        ctx, request.filters, selected_dimensions, needed_entities)
    if filter_err ~= nil then return filter_err end
    having_predicates = {}
    for index, bound in ipairs(bound_having_filters) do
        local metric_field = ctx.all_metric_by_id[key(bound.metric_id)]
        local source = having_list[index]
        local expression = expand_metric(ctx, metric_field)
        local predicate, predicate_err = build_dimension_predicate(
            expression, bound.op, source.value, bound.data_type, source.value_sql)
        if predicate_err ~= nil then return predicate_err end
        having_predicates[#having_predicates + 1] = predicate
    end

    local snapshot = catalog_snapshot_runtime.from_context(ctx, planning_metrics)
    local relationship_targets = {}
    for entity_id, _ in pairs(needed_entities) do
        if entity_id ~= key(ctx.object.root_entity_id) then
            relationship_targets[#relationship_targets + 1] = {
                target_entity_id = entity_id,
            }
        end
    end
    table.sort(relationship_targets, function(left, right)
        return key(left.target_entity_id) < key(right.target_entity_id)
    end)
    local bound_query = metric_plan_runtime.bind_query(
        request,
        selected_dimensions,
        selected_metrics,
        filters,
        bound_having_filters,
        relationship_targets
    )
    local typed_plan, typed_plan_error = metric_plan_runtime.logical_plan(
        request,
        snapshot,
        bound_query,
        planning_metrics
    )
    if typed_plan == nil then
        return error_result(error_prefix .. "_070",
            "Typed planning failed: " .. tostring(typed_plan_error) .. ".")
    end

    local function plan_envelope(materialization_decision, selected_materialization,
        relationship_paths)
        materialization_decision = materialization_decision or {
            candidate_count = 0,
            rejected_materializations = typed_plan.plan_kind == "MULTI_BRANCH"
                and {{reason_code = "MATERIALIZATION_BRANCH_INELIGIBLE"}} or {},
            selected_materialization = JSON_NULL,
        }
        local plan = {
            plan_version = metric_plan_runtime.PLAN_VERSION,
            logical_plan = typed_plan,
            model = model.model_name,
            version_id = model.version_id,
            version_number = model.version_number,
            object = ctx.object.name,
            metrics = {},
            metric_details = {},
            dimensions = {},
            filters = filters,
            relationship_paths = relationship_paths or {},
            selected_materialization = JSON_NULL,
            selected_materializations = materialization_decision.selected_materializations
                or {},
            materialization_decision = materialization_decision,
            validation_run_id = validation_run_id,
            warnings = relationship_path_warnings(ctx, typed_plan),
            selected_representations = {},
        }
        if #(ctx.relationship_identity_remaps or {}) > 0 then
            plan.relationship_identity_remaps = ctx.relationship_identity_remaps
        end
        if #(ctx.relationship_candidate_rejections or {}) > 0 then
            plan.relationship_candidate_rejections =
                ctx.relationship_candidate_rejections
        end
        if selected_materialization ~= nil then
            plan.selected_materialization = {
                materialization_id = selected_materialization.materialization_id,
                materialization_name = selected_materialization.materialization_name,
                physical_schema = selected_materialization.physical_schema,
                physical_object = selected_materialization.physical_object,
                materialization_type = selected_materialization.materialization_type,
                rollup_required = selected_materialization.rollup_required,
            }
        end
        for _, metric in ipairs(selected_metrics) do
            plan.metrics[#plan.metrics + 1] = metric.name
            local detail = {
                name = metric.name,
                metric_kind = metric.metric_kind or metric.metric_type,
                metric_type = metric.metric_type,
                input_roles = {},
            }
            for _, row in ipairs(query([[
                SELECT INPUT_ROLE, INPUT_OBJECT_TYPE, EXPRESSION_ALIAS
                FROM SEMANTIC_SOURCE.METRIC_INPUTS
                WHERE METRIC_ID = :metric_id
                ORDER BY ORDINAL_POSITION
            ]], {metric_id = metric.id}) or {}) do
                detail.input_roles[#detail.input_roles + 1] = {
                    role = row_value(row, "INPUT_ROLE", 1),
                    object_type = row_value(row, "INPUT_OBJECT_TYPE", 2),
                    alias = row_value(row, "EXPRESSION_ALIAS", 3),
                }
            end
            plan.metric_details[#plan.metric_details + 1] = detail
        end
        for _, dimension in ipairs(selected_dimensions) do
            plan.dimensions[#plan.dimensions + 1] = dimension.name
        end
        local representation_entity_ids = {}
        for entity_id, _ in pairs(needed_entities) do
            representation_entity_ids[#representation_entity_ids + 1] = entity_id
        end
        table.sort(representation_entity_ids, function(left, right)
            return key(left) < key(right)
        end)
        for _, entity_id in ipairs(representation_entity_ids) do
            local entity = ctx.entity_by_id[key(entity_id)]
            local selection = entity and ctx.selected_representations[key(entity.id)] or nil
            local representation = selection and selection.representation
                or entity and entity.primary_representation or nil
            if representation ~= nil then
                local selected_bindings = {}
                for attribute_key, binding in pairs(selection and selection.bindings or {}) do
                    local attribute_type, attribute_id = string.match(
                        attribute_key, "^([^:]+):(.+)$")
                    local attribute = attribute_type == "DIMENSION"
                        and ctx.dimension_by_id[key(attribute_id)]
                        or ctx.fact_by_id[key(attribute_id)]
                    selected_bindings[#selected_bindings + 1] = {
                        attribute = attribute_key,
                        attribute_binding_id = binding.id or JSON_NULL,
                        binding_role = binding.role,
                        binding_priority = binding.priority,
                        source_expression = binding.expression,
                        legacy = binding.legacy == true,
                        fusion_strategy = attribute and attribute.fusion_strategy or "PREFER",
                        fusion_contributors = attribute
                            and attribute.fusion_contributors or {},
                    }
                end
                table.sort(selected_bindings, function(left, right)
                    return left.attribute < right.attribute
                end)
                plan.selected_representations[#plan.selected_representations + 1] = {
                    entity_id = entity.id,
                    entity_name = entity.name,
                    representation_id = representation.id,
                    representation_name = representation.name,
                    source_kind = representation.source_kind,
                    source_schema = representation.source_schema,
                    source_object = representation.source_object,
                    selection_reason = (selection == nil or selection.legacy_only)
                        and "STATIC_PRIMARY"
                        or selection.fallback_count > 0 and "ATTRIBUTE_FALLBACK"
                        or "ATTRIBUTE_PREFER",
                    fallback_binding_count = selection and selection.fallback_count or 0,
                    binding_priority = selection and selection.binding_priority or 0,
                    selected_bindings = selected_bindings,
                    fusion_strategy = selection and selection.fusion_strategy or JSON_NULL,
                    partitions = {},
                }
                local selected_entry = plan.selected_representations[
                    #plan.selected_representations]
                for _, candidate in ipairs(selection and selection.candidates or {}) do
                    local candidate_representation = candidate.representation
                    selected_entry.partitions[#selected_entry.partitions + 1] = {
                        representation_id = candidate_representation.id,
                        representation_name = candidate_representation.name,
                        source_kind = candidate_representation.source_kind,
                        source_schema = candidate_representation.source_schema,
                        source_object = candidate_representation.source_object,
                        coverage_predicate = candidate_representation.coverage_predicate,
                        valid_from = candidate_representation.valid_from or JSON_NULL,
                        valid_to = candidate_representation.valid_to or JSON_NULL,
                    }
                end
            end
        end
        return plan
    end

    local function plan_error(code, message)
        local result = error_result(error_prefix .. code, message)
        result.plan_json = json.encode(plan_envelope())
        return result
    end

    if typed_plan.failure ~= nil then
        local reason = typed_plan.failure.reason_code or "TYPED_PLANNING_FAILED"
        local code = string.find(reason, "METRIC_", 1, true) == 1
            and "_070" or "_074"
        return plan_error(code, envelope.typed_failure_message(typed_plan.failure))
    end
    if typed_plan.plan_kind == "MULTI_BRANCH" then
        if ctx.has_fact_fusion then
            return plan_error("_074",
                "Fact reconciliation is not supported in a multi-fact branch plan; split the request or model a pre-reconciled canonical measure source.")
        end
        -- Safeguards tighten only: min() with the deployment default, so a
        -- request can ask to fail earlier but never later.
        local request_options = type(request.options) == "table" and request.options or {}
        local requested_branches = tonumber(request_options.max_branches)
        local requested_bytes = tonumber(request_options.max_bytes)
        local physical_plan, physical_error = physical_plan_runtime.build(
            typed_plan,
            snapshot,
            {
                output_order_by = order_by,
                limit = limit,
                max_branches = requested_branches ~= nil
                    and math.min(requested_branches,
                        physical_plan_runtime.DEFAULT_MAX_BRANCHES) or nil,
                max_sql_bytes = requested_bytes ~= nil
                    and math.min(requested_bytes,
                        physical_plan_runtime.DEFAULT_MAX_SQL_BYTES) or nil,
            }
        )
        if physical_plan == nil then
            typed_plan.failure = physical_error
            return plan_error("_075", "Physical planning failed: "
                .. tostring(physical_error.reason_code) .. ".")
        end
        local fused_plan, fusion_error = physical_plan_runtime.apply_partitioned_sources(
            physical_plan, snapshot)
        if fused_plan == nil then
            typed_plan.failure = fusion_error
            return plan_error("_075", "Fusion planning failed: "
                .. tostring(fusion_error.reason_code) .. ".")
        end
        physical_plan = fused_plan
        local branch_decision = nil
        if materialization_runtime ~= nil
            and type(materialization_runtime.select_branch_sources) == "function" then
            local selections
            selections, branch_decision =
                materialization_runtime.select_branch_sources(ctx, physical_plan)
            local rebound_plan, rebound_error =
                physical_plan_runtime.apply_branch_sources(physical_plan, selections)
            if rebound_plan == nil then
                typed_plan.failure = rebound_error
                return plan_error("_075", "Physical planning failed: "
                    .. tostring(rebound_error.reason_code) .. ".")
            end
            physical_plan = rebound_plan
            physical_plan.source_selection = branch_decision
        end
        typed_plan.physical_plan = physical_plan
        local internal_sql = grain_sql_runtime.render_multi_branch(physical_plan)
        local within_limit, size_error = physical_plan_runtime.check_sql_size(
            physical_plan,
            internal_sql
        )
        if not within_limit then
            typed_plan.failure = size_error
            return plan_error("_075", "Physical planning failed: "
                .. tostring(size_error.reason_code) .. ".")
        end
        typed_plan.execution = {status = "EXECUTABLE"}
        physical_plan.execution = {status = "EXECUTABLE"}
        local plan = envelope.with_governance(plan_envelope(branch_decision),
            model, internal_sql)
        local governance_refusal = envelope.governance_refusal(model, plan, error_prefix)
        if governance_refusal ~= nil then
            return governance_refusal, request, model
        end
        local result = envelope.attach_planning_runtime(
            envelope.ok_result(internal_sql, plan, validation_run_id), planning_started_ms)
        if cache_key ~= nil then
            compile_cache.cache_store(model.version_id, cache_key, result)
        end
        return result, request, model
    end
    if request.proof_mode == "STRICT_GRAIN" then
        for _, proof in ipairs(typed_plan.relationship_proofs or {}) do
            if proof.status ~= "PROVEN" then
                return plan_error("_072", "Strict grain proof failed: "
                    .. tostring(proof.reason_code or proof.reason) .. ".")
            end
        end
    end

    local matrix_err = validate_metric_dimensions(ctx, selected_metrics, all_dimensions)
    if matrix_err ~= nil then
        return matrix_err
    end

    local selected_materialization = nil
    local materialization_decision = {
        candidate_count = 0,
        rejected_materializations = {},
        selected_materialization = JSON_NULL,
    }
    -- Aggregate materializations exist to serve metric aggregations. A
    -- dimension-only discovery request (#selected_metrics == 0) bypasses
    -- the selector and falls through to base-source SQL so distinct
    -- dimension values come from the authoritative source.
    if materialization_runtime ~= nil
        and type(materialization_runtime.select_materialization) == "function"
        and #having_predicates == 0
        and #selected_metrics > 0
        and not ctx.has_attribute_fusion then
        selected_materialization, materialization_decision = materialization_runtime.select_materialization(
            ctx,
            selected_dimensions,
            selected_metrics,
            filter_dimensions
        )
    end

    local sql_text
    if selected_materialization ~= nil then
        sql_text = build_materialized_sql(ctx, selected_dimensions, selected_metrics, filters, order_by, limit, selected_materialization)
    else
        sql_text = build_sql(ctx, selected_dimensions, selected_metrics, filters, joins, order_by, limit, having_predicates)
    end

    local plan = envelope.with_governance(
        plan_envelope(materialization_decision, selected_materialization, relationship_paths),
        model, sql_text)
    -- Refused before the result is cached, so a refusal is never stored and a
    -- model returning to OPEN does not have to outlive one.
    local governance_refusal = envelope.governance_refusal(model, plan, error_prefix)
    if governance_refusal ~= nil then
        return governance_refusal, request, model
    end
    local result = envelope.attach_planning_runtime(
        envelope.ok_result(sql_text, plan, validation_run_id), planning_started_ms)
    if cache_key ~= nil then
        compile_cache.cache_store(model.version_id, cache_key, result)
    end
    return result, request, model
end

local function compile_internal(request_json)
    local decoded, request = pcall(json.decode, request_json)
    if not decoded then
        return error_result("SEMANTIC_REQUEST_001", "Invalid request JSON: " .. tostring(request) .. ".")
    end
    if type(request) ~= "table" or json.is_array(request) then
        return error_result("SEMANTIC_REQUEST_001", "Request JSON must be an object.")
    end
    local request_key_error = compile_cache.validate_structured_request_keys(request)
    if request_key_error ~= nil then
        return request_key_error, request, nil
    end
    -- Compile reuses the latest successful validation run for the active model version.
    -- PUBLISH_MODEL (and VALIDATE_MODEL) own the writes to VALIDATION_RUNS,
    -- METRIC_DEPENDENCIES, and METRIC_DIMENSION_MATRIX. Re-running them on every
    -- compile produced transaction collisions under concurrent load (BUG-001).
    return compile_request_table(request, {validate = false, error_prefix = "SEMANTIC_REQUEST"})
end

local function token_identifier_value(token)
    if token == nil then
        return nil
    end
    if token.kind == "identifier" or token.kind == "word" then
        return token.value or token.text
    end
    return nil
end

local function split_top_level(tokens, start_index, end_index, separator)
    local parts = {}
    local current = {}
    local depth = 0
    for i = start_index, end_index do
        local token = tokens[i]
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        end
        if depth == 0 and token.text == separator then
            parts[#parts + 1] = current
            current = {}
        else
            current[#current + 1] = token
        end
    end
    if #current > 0 then
        parts[#parts + 1] = current
    end
    return parts
end

-- Databricks metric views wrap measures in MEASURE(...) (or its agg() synonym)
-- in SELECT / HAVING / ORDER BY. Unwrap that call to the bare semantic field name
-- so the rest of the parser treats it like any other metric reference. Returns the
-- (possibly rewritten) token list and whether a wrapper was actually removed.
-- Wrappers a select item may put around a metric. MEASURE/AGG say "give me this
-- metric" and carry no aggregation of their own. A named aggregate is accepted
-- only when it is the one the metric declares -- see the select-list loop -- so
-- that SUM(a_ratio) refuses instead of quietly returning the ratio.
local METRIC_WRAPPERS = {
    MEASURE = true, AGG = true,
    SUM = true, COUNT = true, MIN = true, MAX = true, AVG = true,
}

-- Is this `WRAPPER(field)` one the layer refuses, and why?
--
-- On the module table rather than as a local because both lanes need it and the
-- chunk is at its 200-local ceiling; the whole-statement lane calls it while
-- resolving a select item, reference expansion while inferring a projection.
-- One routine, because the two lanes disagreeing about which aggregates a metric
-- accepts is precisely how the guard was lost once already.
--
-- Returns nil when the wrapper is acceptable.
function M.aggregate_wrapper_refusal(wrapper, field_name, field_kind, declared)
    if wrapper == nil or not METRIC_WRAPPERS[wrapper] then
        return nil
    end
    if upper(tostring(field_kind or "")) ~= "METRIC" then
        -- Literal, not built from a prefix: tests/test_conventions.py counts how
        -- many distinct conditions each code carries by reading the sources, and
        -- a code assembled at run time is invisible to it. Both callers are the
        -- SQL lane anyway.
        return error_result("SEMANTIC_QUERY_006",
            "MEASURE()/agg() may only wrap a metric, not '" .. tostring(field_name) .. "'.")
    end
    if wrapper == "MEASURE" or wrapper == "AGG" then
        return nil
    end
    -- A named aggregate is honoured only when it is the aggregation the metric
    -- declares. BI tools write SUM(metric) over what they believe is a column,
    -- and for an additive metric that reading is exactly right -- but SUM of a
    -- ratio is not the ratio, and answering it anyway would return a number
    -- under a label that lies about how it was computed.
    local declared_upper = upper(tostring(declared or ""))
    if declared_upper == wrapper then
        return nil
    end
    return error_result("SEMANTIC_QUERY_007",
        wrapper .. "(" .. tostring(field_name) .. ") is not how that metric"
            .. " aggregates" .. (declared_upper == "" and "" or "; it declares " .. declared_upper)
            .. ". Use MEASURE(" .. tostring(field_name) .. ") to select it as defined.")
end

local function unwrap_measure_part(part)
    if part == nil or #part < 4 then
        return part, false, nil
    end
    local head = sql_text.token_upper(part[1])
    if not METRIC_WRAPPERS[head] or part[2].text ~= "(" then
        return part, false, nil
    end
    local depth = 0
    local close_index = nil
    for i = 2, #part do
        local text = part[i].text
        if text == "(" then
            depth = depth + 1
        elseif text == ")" then
            depth = depth - 1
            if depth == 0 then
                close_index = i
                break
            end
        end
    end
    -- Require a non-empty argument and a matching close paren.
    if close_index == nil or close_index <= 3 then
        return part, false, nil
    end
    local rewritten = {}
    for i = 3, close_index - 1 do
        rewritten[#rewritten + 1] = part[i]
    end
    for i = close_index + 1, #part do
        rewritten[#rewritten + 1] = part[i]
    end
    return rewritten, true, head
end

local function identifier_from_part(part)
    part = unwrap_measure_part(part)
    if #part == 0 then
        return nil
    end
    local end_index = #part
    for i, token in ipairs(part) do
        if sql_text.token_upper(token) == "AS" then
            end_index = i - 1
            break
        end
    end
    if end_index >= 3 and part[end_index - 1].text == "." then
        return token_identifier_value(part[end_index])
    end
    if end_index == 1 then
        return token_identifier_value(part[1])
    end
    if end_index >= 1 and (part[1].kind == "word" or part[1].kind == "identifier") then
        if end_index == 2 and (part[2].kind == "word" or part[2].kind == "identifier") then
            return token_identifier_value(part[1])
        end
    end
    return nil
end

local function alias_from_select_part(part)
    for i, token in ipairs(part) do
        if sql_text.token_upper(token) == "AS" and part[i + 1] ~= nil then
            return token_identifier_value(part[i + 1])
        end
    end
    if #part == 2 and (part[1].kind == "word" or part[1].kind == "identifier") and (part[2].kind == "word" or part[2].kind == "identifier") then
        return token_identifier_value(part[2])
    end
    return nil
end

local function literal_from_tokens(tokens)
    if #tokens == 1 then
        local token = tokens[1]
        if token.kind == "literal" then
            local raw = string.sub(token.text, 2, -2)
            return string.gsub(raw, "''", "'")
        elseif token.kind == "number" then
            return tonumber(token.text) or token.text
        elseif token.kind == "word" then
            return token.value
        end
    elseif #tokens == 2 and sql_text.token_upper(tokens[1]) == "DATE" and tokens[2].kind == "literal" then
        local raw = string.sub(tokens[2].text, 2, -2)
        return string.gsub(raw, "''", "'")
    elseif #tokens == 2 and sql_text.token_upper(tokens[1]) == "TIMESTAMP" and tokens[2].kind == "literal" then
        local raw = string.sub(tokens[2].text, 2, -2)
        return string.gsub(raw, "''", "'")
    end
    return nil
end

local function find_top_level_clauses(tokens)
    local clauses = {}
    local depth = 0
    for i, token in ipairs(tokens) do
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        elseif depth == 0 then
            local u = sql_text.token_upper(token)
            if u == "FROM" or u == "WHERE" or u == "LIMIT" or u == "HAVING" then
                clauses[u] = clauses[u] or i
            elseif u == "GROUP" and sql_text.token_upper(tokens[i + 1]) == "BY" then
                clauses.GROUP_BY = clauses.GROUP_BY or i
            elseif u == "ORDER" and sql_text.token_upper(tokens[i + 1]) == "BY" then
                clauses.ORDER_BY = clauses.ORDER_BY or i
            end
        end
    end
    return clauses
end

local function clause_end(tokens, clauses, current_name)
    local start_index = clauses[current_name]
    local best = #tokens + 1
    for _, candidate in ipairs({"FROM", "WHERE", "GROUP_BY", "HAVING", "ORDER_BY", "LIMIT"}) do
        local pos = clauses[candidate]
        if pos ~= nil and pos > start_index and pos < best then
            best = pos
        end
    end
    return best - 1
end

local function token_slice(tokens, first, last)
    local out = {}
    for i = first, last do
        out[#out + 1] = tokens[i]
    end
    return out
end

local function render_token_slice(tokens)
    local parts = {}
    for _, token in ipairs(tokens or {}) do
        parts[#parts + 1] = token.text
    end
    return table.concat(parts, " ")
end

local binary_predicate_operators = {
    ["IN"] = true, ["BETWEEN"] = true, ["LIKE"] = true,
    ["="] = true, ["!="] = true, ["<>"] = true,
    [">"] = true, [">="] = true, ["<"] = true, ["<="] = true,
}

local function predicate_operator_at(tokens, index)
    local current = sql_text.token_upper(tokens[index])
    if current == "IS" then
        if sql_text.token_upper(tokens[index + 1]) == "NULL" then
            return "IS NULL"
        end
        if sql_text.token_upper(tokens[index + 1]) == "NOT"
            and sql_text.token_upper(tokens[index + 2]) == "NULL" then
            return "IS NOT NULL"
        end
        return "IS"
    end
    if binary_predicate_operators[current] then
        return current
    end
    return nil
end

-- Strip parentheses that wrap a whole predicate. BI tools emit
-- `WHERE ("t"."STATUS" = 'X')`, and without this the trailing `)` was carried
-- into the predicate's value and rendered straight into the generated SQL,
-- producing a statement Exasol will not parse. It went unnoticed because those
-- queries were refused earlier, for using SUM() around a metric, before the
-- renderer ever saw them.
local function strip_outer_parens(tokens, first, last)
    while first < last and tokens[first].text == "(" do
        local depth = 0
        local match = nil
        for i = first, last do
            local text = tokens[i].text
            if text == "(" then
                depth = depth + 1
            elseif text == ")" then
                depth = depth - 1
                if depth == 0 then
                    match = i
                    break
                end
            end
        end
        if match ~= last then
            return first, last
        end
        first, last = first + 1, last - 1
    end
    return first, last
end

-- Evaluate `<number> <op> <number>`, the only predicate shape that names no
-- field. Returns true/false for a constant comparison and nil for anything else,
-- so a real predicate falls through untouched.
local function constant_comparison(tokens, first, last, op_index, op)
    local left = token_slice(tokens, first, op_index - 1)
    local right = token_slice(tokens, op_index + 1, last)
    if #left ~= 1 or #right ~= 1 then return nil end
    if left[1].kind ~= "number" or right[1].kind ~= "number" then return nil end
    local a, b = tonumber(left[1].text), tonumber(right[1].text)
    if a == nil or b == nil then return nil end
    if op == "=" then return a == b end
    if op == "!=" or op == "<>" then return a ~= b end
    if op == ">" then return a > b end
    if op == ">=" then return a >= b end
    if op == "<" then return a < b end
    if op == "<=" then return a <= b end
    return nil
end

-- One predicate parser for both WHERE and HAVING.
--
-- These were two ~110-line functions whose diff was 72 lines of 123, and almost
-- all of it was the clause noun in three messages. The top-level AND split that
-- skips BETWEEN's own AND, the operator scan, IS NULL / IS NOT NULL / IN /
-- BETWEEN, the literal-or-raw-SQL fallback -- all of it was written twice, so a
-- predicate form added to one and forgotten in the other passed every test.
--
-- The real differences are two, and they are what `clause` carries: HAVING
-- resolves the field and refuses anything that is not a metric, and stores the
-- resolved name where WHERE stores what the author typed.
local function parse_predicates(ctx, tokens, start_index, end_index, clause)
    local filters = {}
    local empty_result = false
    local chunks = {}
    -- Split on top-level AND conjunctions, but skip the AND that belongs to a
    -- BETWEEN...AND range (e.g. "field BETWEEN v1 AND v2").
    -- `WHERE (a = 1 AND b = 2)` wraps the whole clause; unwrap before splitting
    -- so the conjunction is still seen at the top level.
    start_index, end_index = strip_outer_parens(tokens, start_index, end_index)
    local current_start = start_index
    local depth = 0
    local after_between = false
    local i = start_index
    while i <= end_index do
        local token = tokens[i]
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        elseif depth == 0 then
            local u = sql_text.token_upper(token)
            if u == "BETWEEN" then
                after_between = true
            elseif u == "AND" then
                if after_between then
                    after_between = false
                else
                    chunks[#chunks + 1] = {current_start, i - 1}
                    current_start = i + 1
                end
            end
        end
        i = i + 1
    end
    chunks[#chunks + 1] = {current_start, end_index}

    for _, chunk in ipairs(chunks) do
        -- and `(a = 1) AND (b = 2)` wraps each conjunct separately.
        local first, last = strip_outer_parens(tokens, chunk[1], chunk[2])
        -- A conjunct carrying its own SELECT is a subquery predicate -- `EXISTS
        -- (...)`, `IN (SELECT ...)` -- which this lane does not model. It used
        -- to find the `=` *inside* the subquery, treat the whole thing as one
        -- comparison, and emit `WHERE c.region = t0 . CUSTOMER_REGION )`: SQL
        -- that does not parse, reported to the caller as a syntax error at a
        -- line of text they never wrote. Refusing here hands the statement to
        -- reference expansion, which leaves the subquery to Exasol.
        local conjunct_depth = tokens[first] ~= nil and tokens[first].depth or 0
        for idx = first, last do
            if tokens[idx].kind == "word" and sql_text.token_upper(tokens[idx]) == "SELECT" then
                return nil, error_result("SEMANTIC_QUERY_030", clause.unsupported)
            end
        end
        local op_index = nil
        local op = nil
        for idx = first, last do
            -- At the conjunct's own depth: an operator nested inside parentheses
            -- belongs to something this predicate is not.
            if tokens[idx].depth == conjunct_depth then
                local candidate = predicate_operator_at(tokens, idx)
                if candidate ~= nil then
                    op_index = idx
                    op = candidate
                    break
                end
            end
        end
        if op_index == nil then
            return nil, error_result("SEMANTIC_QUERY_030", clause.unsupported)
        end
        -- `WHERE 1 = 0` is how JDBC/ODBC drivers ask for a result's shape
        -- without its rows, and `WHERE 1 = 1` is how some tools spell "no
        -- filter". Neither names a field, so evaluate the comparison rather than
        -- refusing it for having no subject. A false one makes the whole
        -- conjunction empty, which LIMIT 0 expresses exactly.
        local constant = constant_comparison(tokens, first, last, op_index, op)
        if constant ~= nil then
            if constant == false then
                empty_result = true
            end
            goto continue_chunk
        end
        local field = identifier_from_part(token_slice(tokens, first, op_index - 1))
        if field == nil then
            return nil, error_result("SEMANTIC_QUERY_031", clause.subject_required)
        end
        -- WHERE keeps the author's spelling and resolves later, against the
        -- dimensions actually selected; HAVING has to resolve here, because a
        -- non-metric predicate is a different refusal rather than a lookup miss.
        if clause.resolve ~= nil then
            local resolved, resolve_error = clause.resolve(ctx, field)
            if resolve_error ~= nil then return nil, resolve_error end
            field = resolved
        end
        if op == "IS NULL" or op == "IS NOT NULL" then
            local expected_last = op_index + (op == "IS NULL" and 1 or 2)
            if last ~= expected_last then
                return nil, error_result("SEMANTIC_QUERY_036",
                    "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
            end
            filters[#filters + 1] = {field = field, op = op}
        elseif op == "IS" then
            return nil, error_result("SEMANTIC_QUERY_036",
                "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
        elseif op == "IN" then
            if tokens[op_index + 1] == nil or tokens[op_index + 1].text ~= "("
                or tokens[last].text ~= ")" then
                return nil, error_result("SEMANTIC_QUERY_032",
                    "IN predicate requires a literal list.")
            end
            local values = {}
            for _, part in ipairs(split_top_level(tokens, op_index + 2, last - 1, ",")) do
                local value = literal_from_tokens(part)
                if value == nil then
                    return nil, error_result("SEMANTIC_QUERY_033",
                        "IN predicate supports literal values only.")
                end
                values[#values + 1] = value
            end
            filters[#filters + 1] = {field = field, op = "IN", value = values}
        elseif op == "BETWEEN" then
            local and_index = nil
            for idx = op_index + 1, last do
                if sql_text.token_upper(tokens[idx]) == "AND" then
                    and_index = idx
                    break
                end
            end
            if and_index == nil then
                return nil, error_result("SEMANTIC_QUERY_034",
                    "BETWEEN predicate requires 'field BETWEEN value1 AND value2'.")
            end
            local v1 = literal_from_tokens(token_slice(tokens, op_index + 1, and_index - 1))
            local v2 = literal_from_tokens(token_slice(tokens, and_index + 1, last))
            if v1 == nil or v2 == nil then
                return nil, error_result("SEMANTIC_QUERY_035",
                    "BETWEEN predicate requires two literal values.")
            end
            filters[#filters + 1] = {field = field, op = "BETWEEN", value = {v1, v2}}
        else
            local value_tokens = token_slice(tokens, op_index + 1, last)
            local value = literal_from_tokens(value_tokens)
            if value == nil then
                local value_sql = trim(render_token_slice(value_tokens))
                if value_sql == "" then
                    return nil, error_result("SEMANTIC_QUERY_033", clause.missing_value)
                end
                filters[#filters + 1] = {field = field, op = op, value = null,
                    value_sql = value_sql}
            else
                filters[#filters + 1] = {field = field, op = op, value = value}
            end
        end
        ::continue_chunk::
    end
    return filters, nil, empty_result
end

-- The whole difference between the two clauses, in one place. It used to be
-- three interpolated nouns scattered through two copies of the same 110 lines.
local WHERE_CLAUSE = {
    unsupported = "Unsupported WHERE predicate.",
    subject_required = "WHERE predicate must start with a semantic dimension.",
    missing_value = "WHERE predicate requires a right-hand value.",
}

local HAVING_CLAUSE = {
    unsupported = "Unsupported HAVING predicate.",
    subject_required = "HAVING predicate must start with a semantic metric.",
    missing_value = "HAVING predicate requires a right-hand value.",
    resolve = function(ctx, field)
        local resolved, resolve_error = resolve_field(ctx, field, nil)
        if resolve_error ~= nil then
            return nil, envelope.recode_error_prefix(resolve_error, "SEMANTIC_QUERY")
        end
        if resolved.kind ~= "METRIC" then
            return nil, error_result("SEMANTIC_QUERY_040",
                "HAVING supports metric predicates only. Use WHERE for dimension filters.")
        end
        return resolved.name, nil
    end,
}

local function parse_where_filters(tokens, start_index, end_index)
    return parse_predicates(nil, tokens, start_index, end_index, WHERE_CLAUSE)
end

local function parse_having_filters(ctx, tokens, start_index, end_index)
    return parse_predicates(ctx, tokens, start_index, end_index, HAVING_CLAUSE)
end

local function parse_order_by(tokens, start_index, end_index, select_aliases, selected_output)
    local order_by = {}
    for _, part in ipairs(split_top_level(tokens, start_index, end_index, ",")) do
        local direction = "ASC"
        if #part > 1 then
            local last = sql_text.token_upper(part[#part])
            if last == "ASC" or last == "DESC" then
                direction = last
                table.remove(part, #part)
            end
        end
        local field = identifier_from_part(part)
        if field == nil and #part == 1 and part[1].kind == "number" then
            local ordinal = tonumber(part[1].text)
            if selected_output ~= nil then
                field = selected_output[ordinal]
            end
        end
        if field == nil then
            return nil, error_result("SEMANTIC_QUERY_060", "ORDER BY supports selected semantic fields only.")
        end
        if select_aliases ~= nil and select_aliases[upper(field)] ~= nil then
            field = select_aliases[upper(field)]
        end
        order_by[#order_by + 1] = {field = field, direction = direction}
    end
    return order_by, nil
end

local function parse_semantic_sql(statement_text, options)
    options = options or {}
    local tokens = sql_text.tokenize(statement_text, SEMANTIC_SQL_LEXER)
    if #tokens == 0 then
        if options.unchanged_nonsemantic then
            return envelope.unchanged_result(statement_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_001", "SQL text is required.")
    end
    if sql_text.token_upper(tokens[1]) ~= "SELECT" then
        if options.unchanged_nonsemantic then
            return envelope.unchanged_result(statement_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_009", "Only top-level SELECT semantic SQL is supported.")
    end
    local clauses = find_top_level_clauses(tokens)
    if clauses.FROM == nil then
        return nil, error_result("SEMANTIC_QUERY_002", "Semantic SQL requires a FROM clause.")
    end
    local select_end = clauses.FROM - 1
    local from_end = clause_end(tokens, clauses, "FROM")
    local from_tokens = token_slice(tokens, clauses.FROM + 1, from_end)
    if #from_tokens < 3 or from_tokens[2].text ~= "." then
        if options.unchanged_unknown_schema then
            return envelope.unchanged_result(statement_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_003", "FROM must reference one published semantic object as schema.object.")
    end
    local published_schema = token_identifier_value(from_tokens[1])
    local object_name = token_identifier_value(from_tokens[3])
    if published_schema == nil or object_name == nil then
        if options.unchanged_unknown_schema then
            return envelope.unchanged_result(statement_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_003", "FROM must reference one published semantic object as schema.object.")
    end
    local model = load_model_by_published_schema(published_schema, object_name)
    if model == nil then
        if options.unchanged_unknown_schema then
            -- The preprocessor is active and declined, so the query falls
            -- through to the published view's own guard, which can only advise
            -- enabling the preprocessor -- telling the user to do the thing they
            -- just did. A schema that carries the SEMANTIC_DISCOVERY table
            -- PUBLISH_MODEL creates, but resolves to no active model, is an
            -- orphaned publication: name it as such instead.
            if orphaned_published_schema(published_schema) then
                return nil, error_result("SEMANTIC_QUERY_005",
                    "Published schema " .. tostring(published_schema)
                        .. " has no active model in the catalog: it is an orphaned"
                        .. " publication left by a dropped or reset model. The"
                        .. " preprocessor is active and declined to rewrite. Re-create"
                        .. " and publish the model, or drop schema "
                        .. tostring(published_schema) .. ".")
            end
            return envelope.unchanged_result(statement_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_004", "No semantic model is published to schema " .. tostring(published_schema) .. ".")
    end
    if options.unchanged_unknown_schema and upper(object_name) == "SEMANTIC_DISCOVERY" then
        return envelope.unchanged_result(statement_text), nil, model
    end
    if #from_tokens > 3 then
        local alias_ok = #from_tokens == 4 and token_identifier_value(from_tokens[4]) ~= nil
        local as_alias_ok = #from_tokens == 5 and sql_text.token_upper(from_tokens[4]) == "AS" and token_identifier_value(from_tokens[5]) ~= nil
        if not alias_ok and not as_alias_ok then
            return nil, error_result("SEMANTIC_QUERY_003", "FROM must reference one published semantic object as schema.object.")
        end
    end

    -- Consult the cache before loading the catalog, not after. Everything below
    -- this point exists to turn field names into a request, and a hit does not
    -- need the request -- only the SQL that was compiled from it last time.
    -- Confined to callers that do not log (the preprocessor lane), because a hit
    -- returns before the request exists and a logging caller needs it.
    local meta = {cache_key = nil, ctx = nil}
    if options.sql_cache and not missing(model.version_id) then
        meta.cache_key = compile_cache.compile_cache_key(compile_cache.canonical_sql_text(tokens))
        if meta.cache_key ~= nil then
            local cached = compile_cache.cache_lookup(model.version_id, meta.cache_key)
            if cached ~= nil then
                compile_cache.cache_touch(model.version_id, meta.cache_key)
                meta.cached = compile_cache.cached_ok_result(cached)
                envelope.recode_error_prefix(meta.cached, "SEMANTIC_QUERY")
                return nil, nil, model, meta
            end
        end
    end

    local ctx, load_code, load_message = load_catalog(model, object_name)
    if ctx == nil then
        return nil, envelope.recode_error_prefix(error_result(load_code, load_message), "SEMANTIC_QUERY")
    end
    meta.ctx = ctx

    local request = {
        model = model.model_name,
        object = object_name,
        metrics = {},
        dimensions = {},
        filters = {},
        having = {},
        order_by = {},
        client = "semantic-sql",
        purpose = "semantic_sql",
    }
    local selected_output = {}
    local select_aliases = {}
    local selected_dimension_seen = {}
    local selected_metric_seen = {}
    local select_parts = split_top_level(tokens, 2, select_end, ",")
    local wildcard_select = #select_parts == 1 and #select_parts[1] == 1 and select_parts[1][1].text == "*"
    -- The names and order the caller asked for. The planner orders columns its
    -- own way and names them after the semantic field; a SQL client needs its
    -- own select list back. Unaliased columns take the published SQL name, which
    -- is what the view's metadata advertises.
    local output_columns = {}
    local function request_output(field, alias)
        output_columns[#output_columns + 1] = {
            source = field.name,
            output = alias or upper(field.name),
        }
    end
    if wildcard_select then
        for _, field in ipairs(ctx.dimensions) do
            selected_output[#selected_output + 1] = field.name
            request_output(field, nil)
            request.dimensions[#request.dimensions + 1] = field.name
            selected_dimension_seen[upper(field.name)] = true
        end
        for _, field in ipairs(ctx.metrics) do
            selected_output[#selected_output + 1] = field.name
            request_output(field, nil)
            request.metrics[#request.metrics + 1] = field.name
            selected_metric_seen[upper(field.name)] = true
        end
    end
    for _, part in ipairs(wildcard_select and {} or select_parts) do
        local inner, measure_wrapped, wrapper = unwrap_measure_part(part)
        -- COUNT(*) counts rows of a result whose grain the layer chose, not
        -- anything the caller named. Refuse rather than answer a question the
        -- number would not actually be an answer to.
        if wrapper == "COUNT" and #inner == 1 and inner[1].text == "*" then
            return nil, error_result("SEMANTIC_QUERY_010",
                "COUNT(*) over a semantic object is not supported: the row count"
                    .. " depends on the grain the layer selects. Count a metric,"
                    .. " or select the dimensions the count should be over.")
        end
        local field_name = identifier_from_part(part)
        if field_name == nil then
            return nil, error_result("SEMANTIC_QUERY_005", "SELECT supports semantic field names, MEASURE(metric), or *.")
        end
        local field, bind_err = resolve_field(ctx, field_name, nil)
        if bind_err ~= nil then
            return nil, envelope.recode_error_prefix(bind_err, "SEMANTIC_QUERY")
        end
        if measure_wrapped then
            local wrapper_refusal = M.aggregate_wrapper_refusal(
                wrapper, field.name, field.kind, field.aggregation_function)
            if wrapper_refusal ~= nil then
                return nil, wrapper_refusal
            end
        end
        selected_output[#selected_output + 1] = field.name
        local output_alias = alias_from_select_part(part)
        request_output(field, output_alias)
        if output_alias ~= nil then
            select_aliases[upper(output_alias)] = field.name
        end
        if field.kind == "DIMENSION" then
            if not selected_dimension_seen[upper(field.name)] then
                request.dimensions[#request.dimensions + 1] = field.name
                selected_dimension_seen[upper(field.name)] = true
            end
        elseif field.kind == "METRIC" then
            if not selected_metric_seen[upper(field.name)] then
                request.metrics[#request.metrics + 1] = field.name
                selected_metric_seen[upper(field.name)] = true
            end
        else
            return nil, error_result("SEMANTIC_QUERY_006", "Unsupported semantic field kind in SELECT.")
        end
    end

    if clauses.WHERE ~= nil then
        local raw_filters, filter_err, where_empty = parse_where_filters(tokens, clauses.WHERE + 1, clause_end(tokens, clauses, "WHERE"))
        if filter_err ~= nil then
            return nil, filter_err
        end
        -- A constant-false conjunct empties the result. Say so as LIMIT 0, which
        -- is the same shape-without-rows the driver asked for and needs no new
        -- concept in the planner.
        if where_empty then
            request.limit = 0
        end
        for _, filter in ipairs(raw_filters) do
            local field, _ = resolve_field(ctx, filter.field, nil)
            if field ~= nil and field.kind == "METRIC" then
                request.having[#request.having + 1] = filter
            else
                request.filters[#request.filters + 1] = filter
            end
        end
    end

    -- Databricks idiom: GROUP BY ALL groups by every non-aggregated SELECT column.
    -- Detect the single-token ALL form and let the selected dimensions stand in for
    -- the explicit grouping list.
    local is_group_by_all = false
    if clauses.GROUP_BY ~= nil then
        local gb_start = clauses.GROUP_BY + 2
        local gb_end = clause_end(tokens, clauses, "GROUP_BY")
        is_group_by_all = (gb_end == gb_start) and sql_text.token_upper(tokens[gb_start]) == "ALL"
    end

    if #request.dimensions > 0 and not wildcard_select then
        -- GROUP BY is optional: when omitted, it is inferred from the selected
        -- dimensions (build_sql emits GROUP BY from request.dimensions regardless
        -- of the typed clause). When a GROUP BY *is* supplied, it must be either
        -- GROUP BY ALL or exactly cover the selected dimensions.
        if clauses.GROUP_BY ~= nil and not is_group_by_all then
            local grouped = {}
            for _, part in ipairs(split_top_level(tokens, clauses.GROUP_BY + 2, clause_end(tokens, clauses, "GROUP_BY"), ",")) do
                local field_name = identifier_from_part(part)
                if field_name == nil and #part == 1 and part[1].kind == "number" then
                    local ordinal = tonumber(part[1].text)
                    field_name = selected_output[ordinal]
                end
                if field_name == nil then
                    return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY supports selected dimensions by name or ordinal.")
                end
                local field, bind_err = resolve_field(ctx, field_name, "DIMENSION")
                if bind_err ~= nil then
                    return nil, envelope.recode_error_prefix(bind_err, "SEMANTIC_QUERY")
                end
                grouped[upper(field.name)] = true
            end
            for _, dimension_name in ipairs(request.dimensions) do
                if not grouped[upper(dimension_name)] then
                    return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY must cover selected dimension " .. tostring(dimension_name) .. ".")
                end
            end
            local group_count = 0
            for _, _ in pairs(grouped) do
                group_count = group_count + 1
            end
            if group_count ~= #request.dimensions then
                return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY must not contain dimensions outside the SELECT list.")
            end
        end
    elseif #request.dimensions == 0 and clauses.GROUP_BY ~= nil and not is_group_by_all then
        return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY is only supported for selected dimensions.")
    end

    if clauses.HAVING ~= nil then
        local having_filters, having_err, having_empty = parse_having_filters(ctx, tokens, clauses.HAVING + 1, clause_end(tokens, clauses, "HAVING"))
        if having_empty then
            request.limit = 0
        end
        if having_err ~= nil then
            return nil, having_err
        end
        for _, f in ipairs(having_filters) do
            request.having[#request.having + 1] = f
        end
    end

    if clauses.ORDER_BY ~= nil then
        local order_by, order_err = parse_order_by(tokens, clauses.ORDER_BY + 2, clause_end(tokens, clauses, "ORDER_BY"), select_aliases, selected_output)
        if order_err ~= nil then
            return nil, order_err
        end
        request.order_by = order_by
    end

    if clauses.LIMIT ~= nil then
        local limit_start = clauses.LIMIT + 1
        local limit_end = clause_end(tokens, clauses, "LIMIT")
        if limit_start ~= limit_end or tokens[limit_start].kind ~= "number" then
            return nil, error_result("SEMANTIC_QUERY_050", "LIMIT must be a non-negative integer literal.")
        end
        request.limit = tonumber(tokens[limit_start].text)
    end
    -- meta carries the catalog context, not just a request: resolving field
    -- names above already cost a full load_catalog, and compile_request_table
    -- would otherwise issue the same 17 statements again for the same object.
    meta.output_columns = output_columns
    return request, nil, model, meta
end

local function compile_sql_internal(sql_text, options)
    options = options or {}
    local request, parse_err, model, meta = parse_semantic_sql(sql_text, {
        unchanged_nonsemantic = options.unchanged_nonsemantic,
        unchanged_unknown_schema = options.unchanged_unknown_schema,
        sql_cache = options.sql_cache,
    })
    if parse_err ~= nil then
        return parse_err, nil, nil
    end
    if meta ~= nil and meta.cached ~= nil then
        return meta.cached, nil, model
    end
    if request ~= nil and request.status == "UNCHANGED" then
        return request, nil, nil
    end
    local result, compiled_request, compiled_model = compile_request_table(request, {
        model = model,
        ctx = meta and meta.ctx or nil,
        validate = options.validate,
        error_prefix = "SEMANTIC_QUERY",
        source = "SEMANTIC_SQL",
    })
    if result ~= nil and result.status == "OK" and meta ~= nil then
        -- ESV_SQL_TEXT, not the `sql_text` alias: this function's first
        -- parameter is named sql_text and shadows it.
        result.generated_sql = ESV_SQL_TEXT.output_projection(result.generated_sql,
                                                              meta.output_columns)
    end
    if meta ~= nil and meta.cache_key ~= nil then
        -- Cache the projected form: the SQL-text key already covers the select
        -- list's names and order, so a hit must return what that statement asked
        -- for. cache_store ignores anything that is not a successful compile.
        compile_cache.cache_store(model.version_id, meta.cache_key, result)
    end
    if result ~= nil and result.status ~= "OK" then
        envelope.recode_error_prefix(result, "SEMANTIC_QUERY")
    end
    return result, compiled_request, compiled_model
end

local function collision_error(msg)
    -- SEMANTIC_REQUEST_100 / SEMANTIC_QUERY_100: transient transaction collision - safe to retry.
    return string.find(msg, "GlobalTransactionRollback", 1, true) ~= nil
        or string.find(msg, "Transaction collision", 1, true) ~= nil
end

-- Bounded retry for transient transaction collisions. After the validator-skip
-- fix (BUG-001) the residual contention is the AGENT_REQUEST_LOG / QUERY_LOG
-- insert. Two retries with a tiny busy backoff are sufficient in practice.
-- Exasol Lua has no sleep, so we burn a small amount of CPU to let the
-- competing transaction commit before retrying.
local COLLISION_RETRIES = 2

local function busy_backoff()
    local budget = 0
    for _ = 1, 200000 do
        budget = budget + 1
    end
    return budget
end

function M.compile_sql(sql_text)
    -- See compile_internal: reuse the latest successful validation run instead of
    -- re-running the validator on every compile (BUG-001).
    local ok, result, request, model
    for attempt = 0, COLLISION_RETRIES do
        ok, result, request, model = pcall(compile_sql_internal, sql_text, {validate = false})
        if ok then break end
        if not collision_error(tostring(result)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_QUERY_100" or "SEMANTIC_QUERY_999"
        return error_result(code, msg), nil, nil
    end
    -- Expansion's result describes a statement the whole-statement planner never
    -- built, so the request and model from its failed attempt would misdescribe
    -- it. Nil is the honest answer until the expanded lane reports its own.
    local answer = M.with_expansion_fallthrough(sql_text, result)
    if answer ~= result then
        return answer, nil, nil
    end
    return result, request, model
end

function M.compile_sql_debug(sql_text, client_name)
    local result, request, model = M.compile_sql(sql_text)
    log_query_result(result, sql_text, request, model, client_name)
    return result, request, model
end

-- ── BI reference expansion ───────────────────────────────────────────────────
--
-- A statement the whole-statement lane cannot compile may still *reference* a
-- semantic object it can. Expansion replaces the reference with a derived table
-- rather than compiling the statement around it, which leaves joins, CTEs,
-- unions, windows, TopN wrappers and arbitrary select-list expressions to
-- Exasol, where they already work. A BI tool's generated SQL is almost never a
-- bare `SELECT fields FROM object`, and before this it was almost never
-- accepted: 3 of 24 corpus statements.
--
-- Everything here lives behind one namespace table inside a `do` block. That is
-- load-bearing, not tidiness: COMPILER_RUNTIME is nine concatenated sources
-- sharing one 200-local chunk and had 14 locals of headroom when this was
-- written. See CLAUDE.md.
-- The refusals expansion owns. Everything else it reports is a failure to read
-- the statement, and there the whole-statement lane's message is the better one
-- because it got further into understanding it.
-- Which lane's answer survives, in one table. Three separate locals would read
-- the same and cost three of the chunk's 200; adding the third is what pushed
-- this over the limit, and they are one decision anyway.
local refusal_rules = {}
refusal_rules.expansion_wins = {
    SEMANTIC_QUERY_006 = true,   -- MEASURE()/agg() over something that is not a metric
    SEMANTIC_QUERY_007 = true,   -- an aggregate the metric does not declare
    SEMANTIC_QUERY_012 = true,   -- composition the layer does not supervise
    SEMANTIC_QUERY_013 = true,   -- more references than one statement should carry
    SEMANTIC_QUERY_028 = true,   -- the model does not vouch for what this reads
}

-- There is deliberately no third set for "lane refusals expansion may not
-- override". One was written while fixing the aggregate guard and then removed:
-- reference expansion raises SEMANTIC_QUERY_006 and _007 itself now, through the
-- same routine the whole-statement lane uses, so the protective set could not be
-- made to fire. Reverting the expansion-side guard fails five checks in
-- tools/verify_sql_lane_parity.py; reverting the protective set failed none.
-- A rule that cannot fire is worse than no rule, because it reads like coverage.

-- `SEMANTIC_QUERY_011` -- "cannot tell which columns of X this statement needs"
-- -- is expansion's own refusal too, but it is about the statement as a whole,
-- and the whole-statement lane often has something better to say about the same
-- text: `Unknown semantic field: bogus. Did you mean: customer_region?` names
-- what the author wrote and offers the correction. So it wins only where that
-- lane had no opinion at all.
refusal_rules.expansion_wins_when_unjudged = {
    SEMANTIC_QUERY_011 = true,
    -- Expansion names an unknown field too, for the statements the other lane
    -- never looks at -- `SELECT bogus FROM obj` inside a subquery. Where both
    -- lanes see it, they now produce the same code, which is what
    -- verify_sql_lane_parity.py holds.
    SEMANTIC_QUERY_020 = true,
    -- Re-aggregation, likewise. Where the other lane read the statement it says
    -- something sharper about the same mistake -- which dimensions an explicit
    -- GROUP BY failed to cover (`_008`), that HAVING needs a metric (`_026`),
    -- that COUNT(*) depends on a grain nobody named (`_010`). `_015` is the
    -- answer for the statements it never looked at, such as a grouped SELECT on
    -- one side of a UNION.
    SEMANTIC_QUERY_015 = true,
}

local bi_expansion = {}
do
    -- Each reference is a separate compile, so a statement naming many of them
    -- is a statement that should be looked at rather than silently multiplied.
    bi_expansion.MAX_REFERENCES = 8

    -- A relation reference can only follow one of these.
    local RELATION_INTRO = {FROM = true, JOIN = true}

    -- Words that end a from-clause item, so cannot be an alias.
    local NOT_AN_ALIAS = {
        ON = true, WHERE = true, GROUP = true, ORDER = true, HAVING = true,
        LIMIT = true, UNION = true, JOIN = true, INNER = true, LEFT = true,
        RIGHT = true, FULL = true, CROSS = true, NATURAL = true, AS = true,
        SELECT = true, FROM = true, WITH = true, QUALIFY = true, CONNECT = true,
        PREFERRING = true, INTO = true, VALUES = true, USING = true,
    }

    -- Words that close the from-clause when scanning for a second relation.
    local ENDS_FROM = {
        WHERE = true, GROUP = true, HAVING = true, ORDER = true, LIMIT = true,
        UNION = true, INTERSECT = true, EXCEPT = true, QUALIFY = true,
        CONNECT = true, WINDOW = true, PREFERRING = true,
    }

    local JOIN_WORDS = {
        JOIN = true, INNER = true, LEFT = true, RIGHT = true, FULL = true,
        CROSS = true, NATURAL = true,
    }

    -- The published column list, read from the cheap source.
    --
    -- SEMANTIC_AGENT.FIELDS_FOR_AGENT answers the same question and cost 166 ms
    -- doing it, which was the whole of the expansion prototype's overhead;
    -- OBJECT_COLUMNS answers it in about ten. Principal-scoped, so an object in
    -- a model the caller is not granted resolves to no columns and expansion
    -- declines rather than leaking that the object exists.
    -- Scoped by the resolved model's id, not by its published schema.
    --
    -- More than one model can carry the same PUBLISHED_SCHEMA -- the OSI import
    -- round-trip creates three beside the example model, all publishing to
    -- SEMANTIC_SALES -- so matching on the schema name alone returned every
    -- object called SALES in any of them. That produced a column list with each
    -- name repeated once per model and a derived table with four columns called
    -- CUSTOMER_REGION, which Exasol rejects as ambiguous. The reference's model
    -- is resolved once, by the same lookup the inner compile uses, and the
    -- columns are read against it.
    function bi_expansion.published_columns(model, object_name)
        if model == nil or missing(model.model_id) then
            return nil
        end
        local rows = query([[
            SELECT oc.COLUMN_NAME, oc.COLUMN_KIND, mt.AGGREGATION_FUNCTION
              FROM SEMANTIC_SOURCE.OBJECT_COLUMNS oc
              JOIN SEMANTIC_SOURCE.SEMANTIC_OBJECTS so
                ON so.OBJECT_ID = oc.OBJECT_ID
              LEFT JOIN SEMANTIC_SOURCE.METRICS mt
                ON oc.COLUMN_KIND = 'METRIC' AND mt.METRIC_ID = oc.OBJECT_REF_ID
             WHERE so.MODEL_ID = :model_id
               AND so.VERSION_ID = :version_id
               AND UPPER(so.OBJECT_NAME) = UPPER(:object_name)
               AND so.STATUS = 'ACTIVE'
               AND oc.IS_VISIBLE = TRUE
             ORDER BY oc.ORDINAL_POSITION
        ]], {model_id = model.model_id, version_id = model.version_id,
             object_name = object_name})
        if rows == nil or #rows == 0 then
            return nil
        end
        local columns, by_name = {}, {}
        for index, row in ipairs(rows) do
            local name = tostring(row_value(row, "COLUMN_NAME", 1))
            columns[index] = {
                name = name,
                kind = tostring(row_value(row, "COLUMN_KIND", 2)),
                -- Only a metric has one; a dimension's stays nil and the
                -- wrapper check refuses on kind before it is read.
                aggregation_function = row_value(row, "AGGREGATION_FUNCTION", 3),
            }
            by_name[upper(name)] = columns[index]
        end
        return columns, by_name
    end

    -- Every `<schema>.<object>` that sits where a relation may sit.
    function bi_expansion.find_references(tokens)
        local found = {}
        for index = 1, #tokens - 3 do
            local intro = tokens[index]
            if intro.kind == "word" and RELATION_INTRO[sql_text.token_upper(intro)] then
                local head, dot, tail = tokens[index + 1], tokens[index + 2], tokens[index + 3]
                local head_name = token_identifier_value(head)
                local tail_name = token_identifier_value(tail)
                if head_name ~= nil and tail_name ~= nil
                    and dot.kind == "symbol" and dot.text == "." then
                    local reference = {
                        first = index + 1, last = index + 3,
                        published_schema = head_name, object_name = tail_name,
                        depth = intro.depth,
                    }
                    -- `X.Y alias` and `X.Y AS alias`; anything else has none.
                    local after = tokens[index + 4]
                    -- The alias is carried as the author spelled it, not
                    -- re-quoted. `t0` unquoted is folded to T0 by Exasol and
                    -- matches `t0.CUSTOMER_REGION` elsewhere in the statement;
                    -- re-emitting it as "t0" makes a lower-case alias that the
                    -- same reference no longer resolves against.
                    if after ~= nil and sql_text.token_upper(after) == "AS" then
                        after = tokens[index + 5]
                        if after ~= nil and token_identifier_value(after) ~= nil then
                            reference.alias = token_identifier_value(after)
                            reference.alias_text = after.text
                            reference.last = index + 5
                        end
                    elseif after ~= nil and (after.kind == "word" or after.kind == "identifier")
                        and not NOT_AN_ALIAS[sql_text.token_upper(after)] then
                        reference.alias = token_identifier_value(after)
                        reference.alias_text = after.text
                        reference.last = index + 4
                    end
                    found[#found + 1] = reference
                end
            end
        end
        return found
    end

    -- Which published columns the statement actually uses.
    --
    -- This is the correctness surface of the whole feature, so it refuses
    -- rather than guesses. An earlier prototype fell back to "all columns" when
    -- it could not tell, and returned seven rows where three were correct --
    -- with correct totals, which is the most dangerous shape of wrong, because
    -- the number a human checks first agrees.
    -- Words a SELECT statement carries that are syntax, not field names. The
    -- list exists because the near-match rule is deliberately generous --
    -- substring in either direction -- and would otherwise answer "Unknown
    -- semantic field: SELECT. Did you mean: selection?" for a model that
    -- happens to have a column whose name starts the same way. Only words that
    -- can stand unqualified in the statements this lane sees need to be here.
    local STATEMENT_WORDS = {}
    for word in ([[SELECT DISTINCT ALL FROM WHERE GROUP BY HAVING ORDER ASC DESC
        LIMIT OFFSET FETCH FIRST NEXT ROWS ONLY JOIN INNER LEFT RIGHT FULL OUTER
        CROSS NATURAL ON USING UNION INTERSECT EXCEPT MINUS AS AND OR NOT IN
        EXISTS BETWEEN LIKE IS NULL TRUE FALSE CASE WHEN THEN ELSE END WITH
        OVER PARTITION LATERAL VALUES]]):gmatch("%S+") do
        STATEMENT_WORDS[word] = true
    end

    -- Names the reference's own SELECT list uses as if they were its fields,
    -- but which the object does not publish. Returns a ready refusal per name so
    -- the caller does not rebuild the message.
    --
    -- Scoped to that SELECT list on purpose. Every other word in the statement
    -- is somebody else's: `SELECT * FROM (SELECT bogus FROM obj) w` also
    -- contains `w`, and a wider scan reported the wrapper's alias as an unknown
    -- field. The list between this block's `SELECT` and the `FROM` above the
    -- reference is exactly the set that has to resolve against it.
    -- The select list this reference is the FROM of: everything between its own
    -- block's SELECT and the FROM above it. Shared by the two checks that read
    -- it, because "which tokens belong to this reference's projection" is one
    -- question and scanning wider is how somebody else's alias gets reported as
    -- an unknown field of ours.
    function bi_expansion.select_list_range(tokens, reference)
        local from_index, select_index
        for index = reference.first - 1, 1, -1 do
            local token = tokens[index]
            if token.depth == reference.depth then
                local word = sql_text.token_upper(token)
                if from_index == nil and word == "FROM" then
                    from_index = index
                elseif from_index ~= nil and word == "SELECT" then
                    select_index = index
                    break
                end
            end
        end
        if select_index == nil or from_index == nil then return nil, nil end
        return select_index + 1, from_index - 1
    end

    -- `WRAPPER(field)` written over this reference, judged by the same routine
    -- the whole-statement lane uses.
    --
    -- Without this the guard was a property of *which lane read the statement*
    -- rather than of the statement: `SELECT SUM(gross_margin_pct) FROM obj` was
    -- refused, and the same thing inside a subquery, a CTE or one arm of a union
    -- returned the ratio itself -- a number under a label that lies about how it
    -- was computed. The wrapping is exactly what stopped the other lane seeing
    -- it, so expansion has to be able to say so on its own.
    function bi_expansion.wrapper_refusal(tokens, reference, by_name)
        local first, last = bi_expansion.select_list_range(tokens, reference)
        if first == nil then return nil end
        for index = first, last do
            local token = tokens[index]
            local following = tokens[index + 1]
            if (token.kind == "word" or token.kind == "identifier")
                and following ~= nil and following.kind == "symbol"
                and following.text == "(" then
                local wrapper = upper(token_identifier_value(token) or "")
                -- `WRAPPER ( name )` -- anything else is an expression this
                -- lane has no opinion about.
                local argument = tokens[index + 2]
                local closing = tokens[index + 3]
                if METRIC_WRAPPERS[wrapper] and argument ~= nil and closing ~= nil
                    and closing.kind == "symbol" and closing.text == ")" then
                    local name = token_identifier_value(argument)
                    local column = name ~= nil and by_name[upper(name)] or nil
                    if column ~= nil then
                        local refusal = M.aggregate_wrapper_refusal(
                            wrapper, column.name, column.kind,
                            column.aggregation_function)
                        if refusal ~= nil then return refusal end
                    end
                end
            end
        end
        return nil
    end

    function bi_expansion.unresolved_field_names(tokens, reference, by_name)
        local first, last = bi_expansion.select_list_range(tokens, reference)
        if first == nil then return {} end
        local select_index, from_index = first - 1, last + 1

        local candidates = {}
        for _, column in ipairs(reference.columns or {}) do
            candidates[#candidates + 1] = {
                key = string.lower(tostring(column.name)),
                display = column.name,
            }
        end

        local found, seen = {}, {}
        for index = select_index + 1, from_index - 1 do
            local token = tokens[index]
            local previous = tokens[index - 1]
            local following = tokens[index + 1]
            local is_bare_word = (token.kind == "word" or token.kind == "identifier")
                and (previous == nil or previous.kind ~= "symbol" or previous.text ~= ".")
                -- `x.y` -- a qualifier, not a field of ours.
                and (following == nil or following.kind ~= "symbol"
                     or (following.text ~= "." and following.text ~= "("))
                -- `f(` -- a function call, not a field.
            -- `x AS name` declares an output column; the name is not a field
            -- of the object and must not be reported as an unknown one. Nor is
            -- `x name`, the same declaration with AS left out -- two operands
            -- cannot sit side by side in a select list, so the second is always
            -- a label. Missing that reported `SELECT z.r FROM (SELECT
            -- t0.CUSTOMER_REGION r FROM obj t0) z` as naming an unknown field
            -- `r`, refusing a valid statement.
            local previous_is_operand = previous ~= nil
                and ((previous.kind == "word"
                      and not STATEMENT_WORDS[upper(token_identifier_value(previous) or "")])
                     or previous.kind == "identifier"
                     or previous.kind == "number"
                     or previous.kind == "string"
                     or (previous.kind == "symbol" and previous.text == ")"))
            if is_bare_word and previous ~= nil
                and (sql_text.token_upper(previous) == "AS" or previous_is_operand) then
                is_bare_word = false
            end
            if is_bare_word then
                local text = token_identifier_value(token) or ""
                local normalized = string.lower(text)
                if text ~= "" and not STATEMENT_WORDS[upper(text)]
                    and by_name[upper(text)] == nil and not seen[normalized] then
                    seen[normalized] = true
                    local near = near_field_names(normalized, candidates)
                    local detail = ""
                    local clarification = nil
                    -- An empty clarification would turn every typo into
                    -- NEEDS_CLARIFICATION with nothing to act on, which is the
                    -- same reason the whole-statement lane omits it.
                    if #near > 0 then
                        detail = " Did you mean: " .. table.concat(near, ", ") .. "?"
                        clarification = {
                            message = "Unknown semantic field.",
                            field = text,
                            object = tostring(reference.object_name),
                            candidates = near,
                            clarification_question = "Which field did you mean instead of "
                                .. text .. "?",
                        }
                    end
                    -- The SQL family, not SEMANTIC_REQUEST: expansion runs only
                    -- in the SQL lane, and this is the same refusal the bare form
                    -- of the statement gets there.
                    found[#found + 1] = error_result("SEMANTIC_QUERY_020",
                        "Unknown semantic field: " .. text .. "." .. detail, clarification)
                end
            end
        end
        return found
    end

    function bi_expansion.infer_columns(tokens, reference, columns, by_name)
        local wanted, seen = {}, {}
        local alias_upper = reference.alias and upper(reference.alias) or nil

        local function take_all()
            for _, column in ipairs(columns) do
                if not seen[upper(column.name)] then
                    seen[upper(column.name)] = true
                    wanted[#wanted + 1] = column.name
                end
            end
        end

        for index = 1, #tokens do
            local token = tokens[index]
            local previous = tokens[index - 1]
            local following = tokens[index + 1]
            local qualified_by_us = alias_upper ~= nil
                and (token.kind == "word" or token.kind == "identifier")
                and upper(token_identifier_value(token) or "") == alias_upper
                and following ~= nil and following.kind == "symbol" and following.text == "."

            if token.kind == "symbol" and token.text == "*" then
                -- A bare `*` means every column of this reference only when it
                -- is selected from the same query block. In
                -- `SELECT * FROM (SELECT t0.A FROM obj t0) x` the star belongs
                -- to `x`, and reading it as "every column of obj" silently
                -- changed the grain: the inner query named two columns and the
                -- expansion compiled nine, so the result grouped by four
                -- dimensions instead of one and North came back 0 instead of
                -- 3635. Comparing depth is what tells the two apart.
                --
                -- `COUNT(*)` names no column at all; if the statement names no
                -- other, the refusal below is the right answer rather than a
                -- guess at which columns were meant.
                local is_call_argument = previous ~= nil
                    and previous.kind == "symbol" and previous.text == "("
                if not is_call_argument and token.depth == reference.depth then
                    take_all()
                end
            elseif qualified_by_us then
                local named = tokens[index + 2]
                if named ~= nil and named.kind == "symbol" and named.text == "*" then
                    take_all()
                else
                    local column_name = token_identifier_value(named)
                    if column_name ~= nil then
                        local column = by_name[upper(column_name)]
                        if column == nil then
                            return nil, "unknown column " .. tostring(reference.alias)
                                .. "." .. tostring(column_name)
                        end
                        if not seen[upper(column.name)] then
                            seen[upper(column.name)] = true
                            wanted[#wanted + 1] = column.name
                        end
                    end
                end
            elseif (token.kind == "word" or token.kind == "identifier")
                and (previous == nil or previous.kind ~= "symbol" or previous.text ~= ".")
                and (following == nil or following.kind ~= "symbol" or following.text ~= ".") then
                local column = by_name[upper(token_identifier_value(token) or "")]
                if column ~= nil and not seen[upper(column.name)] then
                    seen[upper(column.name)] = true
                    wanted[#wanted + 1] = column.name
                end
            end
        end

        -- Checked whether or not anything resolved, because a *partial* match is
        -- the dangerous one. `SELECT CUSTOMER_REGION, TOTAL_FREIGHT FROM
        -- ORDER_HEADER` resolves the metric and not the dimension -- that
        -- dimension belongs to a different semantic view of the same model --
        -- and building the derived table from the half that resolved leaves the
        -- outer statement selecting a column the derived table does not have.
        -- Exasol then says `object CUSTOMER_REGION not found`, which is true of
        -- the generated text and useless about the query: the answer the author
        -- needs is that the field belongs to another view, and the
        -- whole-statement path already says exactly that. Silently dropping a
        -- requested column is the worse half -- it is how a statement comes back
        -- answering a question nobody asked.
        local unresolved = bi_expansion.unresolved_field_names(tokens, reference, by_name)
        if #unresolved > 0 then
            return nil, nil, unresolved[1]
        end

        if #wanted == 0 then
            return nil, "no column of " .. tostring(reference.published_schema) .. "."
                .. tostring(reference.object_name) .. " is referenced"
        end

        -- Published order, not order of appearance: the derived table is read by
        -- name, and a stable order keeps one statement's cache entry usable by
        -- another that names the same columns differently.
        local ordered = {}
        for _, column in ipairs(columns) do
            if seen[upper(column.name)] then
                ordered[#ordered + 1] = column.name
            end
        end
        return ordered
    end

    -- Is the reference joined to, or listed beside, another relation?
    --
    -- This is the fan-out: a semantic result composed with another table in
    -- ordinary SQL can repeat its rows, and re-aggregating the result then
    -- double-counts. The layer stops supervising at the edge of the derived
    -- table, and the number is wrong with nothing to show for it.
    -- Does the reference's own query block re-aggregate it?
    --
    -- A semantic object is already aggregated to the grain its fields imply.
    -- `SELECT region, COUNT(*) FROM obj GROUP BY region` groups that result
    -- again, and the number it returns is a count of already-grouped rows --
    -- which is not the count anyone asked for. Before the two lanes were joined
    -- the whole-statement lane refused this outright; expansion would have
    -- turned it into `SELECT region, COUNT(*) FROM (<compiled>) GROUP BY region`
    -- and answered with a plausible, wrong number, which is the worst shape a
    -- defect can take because the figure a reviewer checks first looks sane.
    --
    -- Depth is what separates this from the supported wrapper. In
    -- `SELECT COUNT(*) FROM (SELECT t0.REGION FROM obj t0) z` the aggregation
    -- sits in the *outer* block and the reference in the inner one, so the
    -- caller has named the grain explicitly -- that is the documented way to
    -- count a semantic result, and it stays supported. Only a GROUP BY or
    -- HAVING in the same block as the reference is re-aggregation.
    function bi_expansion.reaggregated_in_block(tokens, reference)
        for index = reference.last + 1, #tokens do
            local token = tokens[index]
            if token.depth < reference.depth then
                return false
            end
            if token.depth == reference.depth then
                local word = sql_text.token_upper(token)
                if word == "GROUP" or word == "HAVING" then
                    return true
                end
                -- A set operator starts a new query block; anything past it
                -- belongs to a different SELECT and is not this one's grain.
                if word == "UNION" or word == "INTERSECT"
                    or word == "EXCEPT" or word == "MINUS" then
                    return false
                end
            end
        end
        return false
    end

    function bi_expansion.composed_in_from(tokens, reference)
        -- Walked outward, not just across the reference's own FROM clause.
        --
        -- Expansion puts the derived table where the reference is. If that
        -- position is inside a subquery, the subquery is a relation in the
        -- enclosing FROM clause -- and a join *there* carries the same semantic
        -- result into the same fan-out. Stopping at the block boundary meant
        -- wrapping the object first walked straight past the guard: the join
        -- refused bare returned North 7270 against a truth of 3635 once the
        -- object sat in a subquery, which is the exact pair docs/bi-tools.md
        -- prints to justify the refusal.
        --
        -- Block scoping is right for the sibling guard `reaggregated_in_block`,
        -- because aggregating in an outer block is supported -- there the caller
        -- has named the grain. It is wrong for a join, which fans out wherever
        -- it sits.
        -- Where each enclosing block opens. Both parentheses of a group carry
        -- the outer depth, so the opener for the block at depth d+1 is the
        -- nearest `(` at depth d before the reference.
        local openers = {}
        do
            local want = reference.depth - 1
            for index = reference.first - 1, 1, -1 do
                if want < 0 then break end
                local token = tokens[index]
                if token.kind == "symbol" and token.text == "("
                    and token.depth == want then
                    openers[want] = index
                    want = want - 1
                end
            end
        end

        -- Is the block opened here a relation, or something else in parentheses?
        -- `FROM ( … ) y` is a relation and the FROM clause continues around it;
        -- `WITH q AS ( … )` is a CTE body and what follows the close is the main
        -- query's SELECT list, whose commas separate expressions. Reading those
        -- as relation separators refused `WITH q AS (…) SELECT a, b FROM q`,
        -- which has no join in it at all.
        local function opens_a_relation(opener_index)
            if opener_index == nil then return false end
            local previous = tokens[opener_index - 1]
            if previous == nil then return false end
            local word = sql_text.token_upper(previous)
            return (previous.kind == "word" and (word == "FROM" or JOIN_WORDS[word]))
                or (previous.kind == "symbol" and previous.text == ",")
        end

        local level = reference.depth
        -- The reference itself is in a FROM clause, so scanning starts on.
        local scanning = true
        for index = reference.last + 1, #tokens do
            local token = tokens[index]
            -- A token shallower than the level being scanned means the block
            -- closed. Keyed on depth rather than on seeing `)`, because a
            -- closing paren carries the depth it *returns to*.
            if token.depth < level then
                local left = level
                level = token.depth
                -- Inside the enclosing FROM clause already if the block was a
                -- relation there; otherwise wait for that block's own FROM.
                scanning = opens_a_relation(openers[left - 1])
            end
            if token.depth == level then
                local word = sql_text.token_upper(token)
                if scanning then
                    if token.kind == "symbol" and token.text == "," then
                        return true
                    end
                    if token.kind == "word" and JOIN_WORDS[word] then
                        return true
                    end
                    if token.kind == "word" and ENDS_FROM[word] then
                        scanning = false
                    end
                elseif token.kind == "word" and word == "FROM" then
                    -- The CTE's consumer: a join here carries the semantic
                    -- result just as one beside the reference would.
                    scanning = true
                end
            end
        end
        return false
    end

    -- Does this model accept ordinary-SQL semantics over its derived table?
    function bi_expansion.allows_composition(published_schema)
        local allowed = scalar([[
            SELECT ALLOW_DERIVED_COMPOSITION FROM SEMANTIC_SOURCE.MODELS
             WHERE UPPER(PUBLISHED_SCHEMA) = UPPER(:published_schema)
        ]], {published_schema = published_schema})
        return allowed == true or upper(tostring(allowed)) == "TRUE"
    end

    -- Replace each semantic reference with the compiled SQL for exactly the
    -- columns the statement uses.
    -- `CREATE VIEW x AS SELECT ... FROM <semantic object>` stores *compiled* SQL,
    -- so the view keeps answering after the model changes -- with the old
    -- answer, and no error. That is a capability and a liability in the same
    -- statement, so a freeze is recorded rather than left to be discovered.
    --
    -- Returns the target schema and name, or nil when the statement is not a
    -- view definition.
    function bi_expansion.frozen_view_target(tokens)
        local index = 1
        if sql_text.token_upper(tokens[index]) ~= "CREATE" then
            return nil
        end
        index = index + 1
        if sql_text.token_upper(tokens[index]) == "OR"
            and sql_text.token_upper(tokens[index + 1]) == "REPLACE" then
            index = index + 2
        end
        if sql_text.token_upper(tokens[index]) == "FORCE" then
            index = index + 1
        end
        if sql_text.token_upper(tokens[index]) ~= "VIEW" then
            return nil
        end
        index = index + 1
        if sql_text.token_upper(tokens[index]) == "IF"
            and sql_text.token_upper(tokens[index + 1]) == "NOT"
            and sql_text.token_upper(tokens[index + 2]) == "EXISTS" then
            index = index + 3
        end
        local first = token_identifier_value(tokens[index])
        if first == nil then
            return nil
        end
        if tokens[index + 1] ~= nil and tokens[index + 1].text == "."
            and token_identifier_value(tokens[index + 2]) ~= nil then
            return first, token_identifier_value(tokens[index + 2])
        end
        -- An unqualified view lands in whatever schema the session has open,
        -- which the preprocessor cannot see. Recorded with an empty schema
        -- rather than guessed at: a wrong schema in the catalog would be worse
        -- than an absent one, because it reads as a fact.
        return "", first
    end

    function bi_expansion.rewrite(statement_text)
        local tokens = sql_text.tokenize(statement_text, SEMANTIC_SQL_LEXER)
        if #tokens == 0 then
            return {status = "UNCHANGED", generated_sql = statement_text}
        end
        local references = bi_expansion.find_references(tokens)
        if #references == 0 then
            return {status = "UNCHANGED", generated_sql = statement_text}
        end

        local applicable = {}
        for _, reference in ipairs(references) do
            -- Resolved once and carried: the column list, the compile and the
            -- freeze record all have to mean the same model.
            reference.model = load_model_by_published_schema(
                reference.published_schema, reference.object_name)
            local columns, by_name =
                bi_expansion.published_columns(reference.model, reference.object_name)
            if columns ~= nil then
                reference.columns, reference.by_name = columns, by_name
                applicable[#applicable + 1] = reference
            end
        end
        if #applicable == 0 then
            return {status = "UNCHANGED", generated_sql = statement_text}
        end
        if #applicable > bi_expansion.MAX_REFERENCES then
            return error_result("SEMANTIC_QUERY_013",
                "This statement references " .. #applicable .. " semantic objects;"
                .. " at most " .. bi_expansion.MAX_REFERENCES .. " are expanded."
                .. " Each one is a separate compile.")
        end

        local view_schema, view_name = bi_expansion.frozen_view_target(tokens)
        local frozen = {}

        -- Reverse order, so an earlier reference's character offsets are still
        -- valid after a later one has been spliced.
        local rewritten = statement_text
        local expanded = 0
        local inner_plan_json, inner_model
        for index = #applicable, 1, -1 do
            local reference = applicable[index]

            -- Behind the same opt-in as the join guard, and for the same
            -- reason: SET_MODEL_DERIVED_COMPOSITION says this model accepts
            -- ordinary-SQL semantics over its published objects, and
            -- re-aggregation is ordinary-SQL semantics. Refusing it anyway would
            -- make the opt-in mean two different things depending on which
            -- hazard the statement happened to reach.
            if bi_expansion.reaggregated_in_block(tokens, reference)
                and not bi_expansion.allows_composition(reference.published_schema) then
                return error_result("SEMANTIC_QUERY_015",
                    "This statement groups " .. tostring(reference.published_schema) .. "."
                    .. tostring(reference.object_name) .. " again. The object is already"
                    .. " aggregated to the grain its fields imply, so grouping it a"
                    .. " second time counts rows that are themselves groups. Select the"
                    .. " fields you want the grain to be, or wrap the object in a"
                    .. " subquery and aggregate that, which names the grain explicitly."
                    .. " A model may accept ordinary-SQL semantics instead with"
                    .. " SET_MODEL_DERIVED_COMPOSITION.")
            end

            if bi_expansion.composed_in_from(tokens, reference)
                and not bi_expansion.allows_composition(reference.published_schema) then
                return error_result("SEMANTIC_QUERY_012",
                    "This statement joins " .. tostring(reference.published_schema) .. "."
                    .. tostring(reference.object_name) .. " to another relation. The"
                    .. " semantic layer stops supervising at the edge of the derived"
                    .. " table, so the join can repeat its rows and any re-aggregation"
                    .. " above it will double-count. Query the object on its own, or"
                    .. " accept ordinary-SQL semantics for this model with"
                    .. " SET_MODEL_DERIVED_COMPOSITION.")
            end

            -- Before anything else about this reference: an aggregate the metric
            -- does not declare is wrong however the statement is shaped, and
            -- wrapping is what stopped the other lane seeing it.
            local wrapper_refusal = bi_expansion.wrapper_refusal(
                tokens, reference, reference.by_name)
            if wrapper_refusal ~= nil then
                return wrapper_refusal
            end

            local wanted, why, named_refusal =
                bi_expansion.infer_columns(tokens, reference, reference.columns, reference.by_name)
            if named_refusal ~= nil then
                -- The author named a field this object does not have. Saying so
                -- beats saying the projection could not be inferred, and it is
                -- what the same statement gets without the wrapper.
                return named_refusal
            end
            if wanted == nil then
                return error_result("SEMANTIC_QUERY_011",
                    "Cannot tell which columns of " .. tostring(reference.published_schema)
                    .. "." .. tostring(reference.object_name) .. " this statement needs: "
                    .. tostring(why) .. ". Name them, or alias the reference and qualify"
                    .. " them with it.")
            end

            local parts = {}
            for position, column_name in ipairs(wanted) do
                parts[position] = sql_text.quote_ident(column_name)
            end
            local inner = "SELECT " .. table.concat(parts, ", ") .. " FROM "
                .. sql_text.quote_qualified(reference.published_schema, reference.object_name)
            local compiled = compile_sql_internal(inner, {
                validate = false,
                unchanged_nonsemantic = false,
                unchanged_unknown_schema = false,
                sql_cache = true,
            })
            if compiled == nil or compiled.status ~= "OK" then
                return compiled or error_result("SEMANTIC_QUERY_999",
                    "Expansion could not compile " .. inner)
            end

            -- Kept so the statement can be explained afterwards. The governance
            -- prose, the materialization and the requested fields are all read
            -- back out of PLAN_JSON, so a log row without one records that a
            -- query happened and answers nothing about it -- which is the state
            -- QUERY_LOG was in for this lane. Only a single-reference statement
            -- carries one: with two, there are two plans and no honest way to
            -- present them as the plan for the statement.
            if #applicable == 1 then
                inner_plan_json = compiled.plan_json
                inner_model = reference.model
            end

            -- Freezing: this statement is about to store the compiled SQL in a
            -- view, where it will keep answering after the model moves on.
            --
            -- There is no separate governance refusal here any more. The compile
            -- above is refused in GOVERNED mode when it reads a relation the
            -- model does not vouch for, and you cannot freeze SQL you cannot
            -- compile -- so the freeze-specific code tested the same condition
            -- one step later and could no longer fire. One condition, one code.
            if view_schema ~= nil then
                local model = reference.model
                if model ~= nil then
                    frozen[#frozen + 1] = {
                        model = model, reference = reference,
                        columns = table.concat(wanted, ","),
                        sql = compiled.generated_sql,
                        relations = compile_cache.qualified_relations(compiled.generated_sql),
                    }
                end
            end

            -- A derived table needs a name for the outer statement to qualify
            -- it. When the author gave none they cannot be referring to it by
            -- alias, so any name works and a generated one cannot collide with
            -- theirs -- but it has to be *quoted*: Exasol rejects a bare
            -- identifier beginning with an underscore, so the unquoted form
            -- turned every alias-free statement into generated SQL that did not
            -- parse. The caller then saw a syntax error pointing at a line of
            -- text they never wrote.
            local alias = reference.alias_text or ('"__esv_ref_' .. index .. '"')
            -- On one line, so the statement Exasol parses has the same line
            -- numbering as the statement the author wrote. Splicing eight lines
            -- of compiled SQL into the middle of a one-line query is what made
            -- every later error report a line that did not exist -- see
            -- sql_text.flatten_lines. The pretty form is still what a frozen
            -- view stores and what EXPLAIN shows; only the text handed back to
            -- the parser is folded.
            local replacement = "(" .. sql_text.flatten_lines(compiled.generated_sql)
                .. ") " .. alias
            rewritten = string.sub(rewritten, 1, tokens[reference.first].start_pos - 1)
                .. replacement
                .. string.sub(rewritten, tokens[reference.last].end_pos + 1)
            expanded = expanded + 1
        end

        -- Recorded after every reference compiled, so a statement that refuses
        -- half way leaves no record of a view it never created. Best effort:
        -- losing the record must not fail a CREATE VIEW that otherwise works,
        -- and VALIDATE_MODEL reconciles against EXA_ALL_VIEWS either way.
        for _, entry in ipairs(frozen) do
            pcall(query, [[
                INSERT INTO SYS_SEMANTIC.FROZEN_VIEWS (
                  MODEL_ID, VERSION_ID, VIEW_SCHEMA, VIEW_NAME, OBJECT_NAME,
                  FROZEN_COLUMNS, FROZEN_SQL, FROZEN_RELATIONS
                ) VALUES (
                  :model_id, :version_id, :view_schema, :view_name, :object_name,
                  :columns, :sql, :relations
                )
            ]], {
                model_id = entry.model.model_id,
                version_id = entry.model.version_id,
                view_schema = upper(view_schema),
                view_name = upper(view_name),
                object_name = entry.reference.object_name,
                columns = entry.columns,
                sql = entry.sql,
                relations = table.concat(entry.relations, ","),
            })
        end

        return {
            status = "OK",
            generated_sql = rewritten,
            expanded_references = expanded,
            plan_json = inner_plan_json,
            model = inner_model,
        }
    end
end

-- Ask reference expansion about a statement the whole-statement lane could not
-- compile, and decide which of the two answers the caller gets.
--
-- On the module table, and called through it, for two reasons that are both
-- about this chunk rather than about design. It has to be defined *after* the
-- expansion namespace, because a local declared later is not in scope for a
-- function defined earlier and the body would bind `bi_expansion` as a nil
-- global. And it cannot be a forward-declared local, because the chunk is at
-- the 200-local ceiling -- adding one failed the install with "too many local
-- variables in main function", 8000 lines away from the declaration. Reaching
-- it through `M` costs no local and resolves at call time.
--
-- Shared, and that is the point. This logic lived in the preprocessor entry
-- point alone, so the *same statement* got two answers depending on how the
-- caller reached the layer: `SELECT region FROM obj ORDER BY revenue DESC` ran
-- through the preprocessor and was refused by COMPILE_SQL, which is also what
-- EXPLAIN_COMPILED_SQL and COMPILE_SQL_DEBUG call -- so the surfaces an author
-- reaches for to find out *why* a query behaved a certain way disagreed with
-- the query. Joining the two SQL lanes is only true if every door opens on the
-- same one.
--
-- The rule that keeps precise refusals precise: expansion may turn a refusal
-- into a *success*, never into a different refusal. `SELECT bogus FROM obj`
-- keeps "Unknown semantic field: bogus. Did you mean: ...?" rather than being
-- re-described as a statement whose columns could not be inferred.
function M.with_expansion_fallthrough(sql_text, result)
    if result ~= nil and result.status == "OK" then
        return result
    end
    local lane_had_an_opinion = result ~= nil and result.status ~= "UNCHANGED"
    local expanded_ok, expanded = pcall(bi_expansion.rewrite, sql_text)
    if not expanded_ok then
        -- Expansion broke rather than refused. If the other lane read the
        -- statement and said why it would not compile it, that answer is still
        -- true and still the best one available -- replacing `COUNT(*) over a
        -- semantic object is refused` with `reference expansion failed` would
        -- hide a good reason behind a bad one.
        if lane_had_an_opinion then
            return result
        end
        -- With no such answer the alternative is passing the statement through
        -- untouched, so Exasol reports `object SEMANTIC_X.Y not found` -- which
        -- names the symptom and hides the cause. Surfaced rather than swallowed.
        return error_result("SEMANTIC_QUERY_014",
            "Reference expansion failed on this statement: " .. tostring(expanded))
    end
    -- Expansion's answer is taken when it compiled the statement, and also
    -- when it *refused on its own terms*: the composition guard, the
    -- projection it could not infer, and the governance refusal from the
    -- compile behind it are decisions about this statement, not a failure
    -- to read it. Returning the whole-statement lane's "FROM must reference
    -- one published semantic object" in place of "this joins the object to
    -- another relation and the re-aggregation will double-count" would
    -- describe the shape and lose the reason.
    if expanded ~= nil
        and (expanded.status == "OK"
             or refusal_rules.expansion_wins[expanded.error_code or ""]
             or (not lane_had_an_opinion
                 and refusal_rules.expansion_wins_when_unjudged[expanded.error_code or ""])) then
        return expanded
    end
    return result
end

function M.compile_sql_for_preprocessor(sql_text)
    local upper_sql = upper(sql_text or "")
    if string.find(upper_sql, "SELECT", 1, true) == nil or string.find(upper_sql, "FROM", 1, true) == nil then
        return {status = "UNCHANGED", generated_sql = sql_text}
    end
    local options = {
        validate = false,
        unchanged_nonsemantic = true,
        unchanged_unknown_schema = true,
        -- This lane builds no canonical request before answering, so it is the
        -- one that can serve from the cache before the request exists. See
        -- parse_semantic_sql. It does write QUERY_LOG, after the fact and from
        -- whatever the compile produced -- a cache hit has no `request`, and the
        -- fields that would have come from one are read back out of PLAN_JSON by
        -- EXPLAIN_COMPILED_SQL.
        sql_cache = true,
    }
    local ok, result, request, model
    for attempt = 0, COLLISION_RETRIES do
        ok, result, request, model = pcall(compile_sql_internal, sql_text, options)
        if ok then break end
        if not collision_error(tostring(result)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_QUERY_100" or "SEMANTIC_QUERY_999"
        return error_result(code, msg)
    end

    -- The whole-statement lane is tried first and kept: it is faster, and it
    -- already does `SELECT *` expansion and GROUP BY inference for the pure
    -- case. Expansion is what happens when that lane cannot compile the
    -- statement -- a join, a CTE, a union, a TopN wrapper, `CREATE VIEW`,
    -- arithmetic in the select list, `ORDER BY` a column it did not select,
    -- `OFFSET`, `IN (subquery)`, `SELECT DISTINCT`, a predicate over somebody
    -- else's table.
    --
    -- This used to fall through only for a short list of refusal codes, which
    -- meant a redundant subquery was the difference between a statement working
    -- and not: wrapping it routed it here, and nothing told the caller that. The
    -- bare form is the one the documentation teaches, so the two lanes are now
    -- one path -- whatever the first cannot compile, the second is asked about.
    --
    local answer = M.with_expansion_fallthrough(sql_text, result)

    -- The lane most queries take is the one that recorded nothing. QUERY_LOG was
    -- written only by COMPILE_SQL_DEBUG, so `MY_QUERY_LOG` stayed empty,
    -- EXPLAIN_COMPILED_SQL had no handle to explain, and the answer this project
    -- offers to "why is my number different from my colleague's" was reachable
    -- from every lane except the one BI tools use. SEMANTIC_USER was even
    -- granted INSERT on the table, for a writer that never ran.
    --
    -- Only statements this lane actually rewrote are recorded. UNCHANGED means
    -- the text was somebody else's ordinary SQL, and logging those would fill
    -- the table with rows the semantic layer had no part in -- with the
    -- preprocessor set database-wide, that is every statement in every session.
    --
    -- Best effort, and deliberately so: a query that answered correctly must not
    -- fail because the layer could not describe it afterwards.
    if answer ~= nil and answer.status == "OK" then
        local logged_model = answer.model or model
        pcall(log_query_result, answer, sql_text, request, logged_model,
            answer.expanded_references ~= nil and "PREPROCESSOR:EXPANSION"
                or "PREPROCESSOR",
            false)
    end
    return answer
end

function M.compile_request_json(request_json)
    local ok, result, request, model
    for attempt = 0, COLLISION_RETRIES do
        ok, result, request, model = pcall(compile_internal, request_json)
        if ok then break end
        if not collision_error(tostring(result)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_REQUEST_100" or "SEMANTIC_REQUEST_999"
        result = error_result(code, msg)
        request = nil
        model = nil
    end
    -- log_request inserts into AGENT_REQUEST_LOG and can itself collide under
    -- concurrent load. Retry the same way so the caller keeps STATUS=OK and a
    -- usable agent_request_id. If it still fails, leave the compile result
    -- intact - the generated SQL is still executable.
    for attempt = 0, COLLISION_RETRIES do
        local log_ok, log_err = pcall(log_request, result, request_json, request, model)
        if log_ok then break end
        if not collision_error(tostring(log_err)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    return result
end

-- Dry-run migration assistance for legacy primary-key and equality-join
-- metadata. Suggestions are deliberately limited to unambiguous column forms.
function M.suggest_grain_metadata(model_name)
    local model = load_model(normalize_name(model_name, "model"))
    if model == nil then
        return {{"ERROR", tostring(model_name), "MODEL_NOT_FOUND", null}}
    end
    local suggestions = {}
    local entities = query([[
        SELECT e.ENTITY_ID, e.ENTITY_NAME, er.SOURCE_ALIAS, e.PRIMARY_KEY_EXPR
        FROM SEMANTIC_SOURCE.ENTITIES e
        JOIN SEMANTIC_SOURCE.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        ORDER BY e.ENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    local alias_by_id = {}
    for _, row in ipairs(entities or {}) do
        local entity_id = row_value(row, "ENTITY_ID", 1)
        local entity_name = row_value(row, "ENTITY_NAME", 2)
        local alias = row_value(row, "SOURCE_ALIAS", 3)
        local expression = row_value(row, "PRIMARY_KEY_EXPR", 4)
        alias_by_id[key(entity_id)] = alias
        local clean = tostring(expression or ""):gsub('"', "")
        local expression_alias, column_name =
            string.match(clean, "^%s*([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)%s*$")
        if expression_alias ~= nil and upper(expression_alias) == upper(alias) then
            local existing = scalar([[
                SELECT COUNT(*)
                FROM SEMANTIC_SOURCE.UNIQUE_KEYS
                WHERE MODEL_ID = :model_id
                  AND VERSION_ID = :version_id
                  AND ENTITY_ID = :entity_id
                  AND STATUS = 'ACTIVE'
            ]], {
                model_id = model.model_id,
                version_id = model.version_id,
                entity_id = entity_id,
            })
            if tonumber(existing or 0) == 0 then
                suggestions[#suggestions + 1] = {
                    "UNIQUE_KEY",
                    entity_name,
                    "LEGACY_PRIMARY_KEY_EXPR",
                    json.encode({
                        key_name = tostring(entity_name) .. "_pk",
                        key_kind = "PRIMARY",
                        columns = {{ordinal_position = 1, column_name = column_name}},
                    }),
                }
            end
        end
    end

    local relationships = query([[
        SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
               JOIN_CONDITION
        FROM SEMANTIC_SOURCE.RELATIONSHIPS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY RELATIONSHIP_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(relationships or {}) do
        local relationship_id = row_value(row, "RELATIONSHIP_ID", 1)
        local relationship_name = row_value(row, "RELATIONSHIP_NAME", 2)
        local from_entity_id = row_value(row, "FROM_ENTITY_ID", 3)
        local to_entity_id = row_value(row, "TO_ENTITY_ID", 4)
        local condition = tostring(row_value(row, "JOIN_CONDITION", 5) or ""):gsub('"', "")
        local left_alias, left_column, right_alias, right_column =
            string.match(condition,
                "^%s*([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)%s*=%s*([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)%s*$")
        if left_alias ~= nil then
            local from_alias = alias_by_id[key(from_entity_id)]
            local to_alias = alias_by_id[key(to_entity_id)]
            local from_column
            local to_column
            if upper(left_alias) == upper(from_alias) and upper(right_alias) == upper(to_alias) then
                from_column, to_column = left_column, right_column
            elseif upper(right_alias) == upper(from_alias) and upper(left_alias) == upper(to_alias) then
                from_column, to_column = right_column, left_column
            end
            local existing = scalar([[
                SELECT COUNT(*)
                FROM SEMANTIC_SOURCE.RELATIONSHIP_KEY_MAPPINGS
                WHERE RELATIONSHIP_ID = :relationship_id
            ]], {relationship_id = relationship_id})
            if from_column ~= nil and tonumber(existing or 0) == 0 then
                suggestions[#suggestions + 1] = {
                    "RELATIONSHIP_MAPPING",
                    relationship_name,
                    "SIMPLE_EQUALITY_JOIN",
                    json.encode({
                        ordinal_position = 1,
                        from_column_name = from_column,
                        to_column_name = to_column,
                    }),
                }
            end
        end
    end
    if #suggestions == 0 then
        suggestions[1] = {"NONE", model.model_name, "NO_SAFE_SUGGESTIONS", null}
    end
    return suggestions
end

compile_request_json = M.compile_request_json
compile_sql = M.compile_sql
compile_sql_debug = M.compile_sql_debug
compile_sql_for_preprocessor = M.compile_sql_for_preprocessor
suggest_grain_metadata = M.suggest_grain_metadata

-- Database-free tests opt into this deliberately small pure-function surface.
-- Exasol never defines ESV_TEST_MODE, so the installed runtime's public API is
-- unchanged. Keeping the seam here lets the unit suite exercise parser,
-- normalization, expression, and predicate behavior without mocking a whole
-- database catalog.
if rawget(_G, "ESV_TEST_MODE") then
    ESV_COMPILER_TEST_API = {
        json_encode = json.encode,
        json_decode = json.decode,
        canonical_request_text = compile_cache.canonical_request_text,
        canonical_sql_text = compile_cache.canonical_sql_text,
        runtime_build = compile_cache.runtime_build,
        compile_cache_key = compile_cache.compile_cache_key,
        qualified_relations = compile_cache.qualified_relations,
        bi_find_references = bi_expansion.find_references,
        bi_infer_columns = bi_expansion.infer_columns,
        bi_composed_in_from = bi_expansion.composed_in_from,
        within_trust_boundary = compile_cache.within_trust_boundary,
        quote_ident = sql_text.quote_ident,
        quote_qualified = sql_text.quote_qualified,
        sql_literal = sql_text.sql_literal,
        resolve_field = resolve_field,
        relationship_edges = relationship_edges,
        find_path = find_path,
        strip_string_literals = sql_text.strip_string_literals,
        aliases_in_expression = aliases_in_expression,
        replace_identifiers = replace_identifiers,
        expand_metric = expand_metric,
        apply_metric_filter = apply_metric_filter,
        build_dimension_predicate = build_dimension_predicate,
        build_filters = build_filters,
        plan_joins = plan_joins,
        relationship_path_warnings = relationship_path_warnings,
        validate_structured_request_keys = compile_cache.validate_structured_request_keys,
        build_order_by = build_order_by,
        build_sql = build_sql,
        build_materialized_sql = build_materialized_sql,
        sql_tokens = function(text) return sql_text.tokenize(text, SEMANTIC_SQL_LEXER) end,
        split_top_level = split_top_level,
        unwrap_measure_part = unwrap_measure_part,
        identifier_from_part = identifier_from_part,
        alias_from_select_part = alias_from_select_part,
        literal_from_tokens = literal_from_tokens,
        find_top_level_clauses = find_top_level_clauses,
        render_token_slice = render_token_slice,
        parse_where_filters = parse_where_filters,
        parse_having_filters = parse_having_filters,
        parse_order_by = parse_order_by,
        collision_error = collision_error,
        typed_failure_message = envelope.typed_failure_message,
    }
end
