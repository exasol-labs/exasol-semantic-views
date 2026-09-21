-- Unit tests for the tier-2 fusion document.
--
-- The live verifier (tools/verify_fusion_declaration.py) proves the end-to-end
-- claims: one document lands on a published model, dry run commits nothing,
-- re-applying is a no-op, export/apply/export round-trips. These cover the
-- parts a live test reaches only expensively -- the closed-contract refusals,
-- the operation *order*, and the fact that the rollback reads its column lists
-- from the catalog rather than restating them.

local api = assert(ESV_FUSION_DECLARATION_TEST_API,
    "fusion declaration test API is required")

local function fake_query(handler)
    return function(sql, params) return handler(tostring(sql), params or {}) end
end

-- The export entrypoints read the script-context `query` global rather than
-- taking it as an argument, because that is how they run inside Exasol.
local function with_query(mock, fn)
    local original_query = query
    query = mock
    local ok, result = xpcall(fn, debug.traceback)
    query = original_query
    if not ok then error(result, 0) end
    return result
end

test("fusion document refuses keys it does not know, by name", function()
    -- A silently-dropped `authority` is a governance change nobody sees, so an
    -- unknown key has to be an error rather than a no-op.
    local ok, err = pcall(api.reject_unknown, {authority = "PREFER", authorityy = "X"},
        {authority = true, coverage = true}, "representation")
    assert_branch("fusion.document.closed_contract", ok, false)
    assert_contains(tostring(err), "SEMANTIC_FUSION_011")
    assert_contains(tostring(err), "authorityy")
    -- The message lists what *is* allowed, so the caller does not have to guess.
    assert_contains(tostring(err), "Allowed: authority, coverage")

    -- An array where an object belongs is its own diagnostic: without this the
    -- first element reports as an unknown key named "1".
    local array_ok, array_err = pcall(api.reject_unknown, {"a"},
        {authority = true}, "representation")
    assert_true(not array_ok)
    assert_contains(tostring(array_err), "not an array")

    local good = pcall(api.reject_unknown, {authority = "PREFER"},
        {authority = true, coverage = true}, "representation")
    assert_branch("fusion.document.closed_contract", good, true)
end)

test("fusion document plans operations in dependency order", function()
    -- Order is not cosmetic. The identity must exist before a representation
    -- binds to it, the representation before an attribute binds to it, and on a
    -- published model every intermediate state is validated -- so the alternate
    -- has to arrive complete, through the collapsed form, rather than as four
    -- separately-refused calls.
    local document = {entities = {customer = {
        identity = {name = "cid", kind = "GLOBAL", data_type = "DECIMAL(18,0)"},
        representations = {{
            name = "crm", source_schema = "CRM", source_object = "C",
            priority = 20, authority = "AUTHORITATIVE",
            identity_binding = {source_expression = "c.account_id",
                binding_kind = "MAPPED",
                mapping = {source_schema = "CRM", source_object = "XREF",
                    source_local_column = "ACCOUNT_ID",
                    semantic_key_column = "CUSTOMER_ID"}},
        }},
        attribute_bindings = {{attribute_type = "DIMENSION",
            attribute_name = "cname", representation = "crm",
            source_expression = "TRIM(c.name)"}},
        attribute_policies = {{attribute_type = "DIMENSION",
            attribute_name = "cname", strategy = "RECONCILE"}},
    }}}
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "PUBLISHED"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1}}
        end
        return {}
    end)
    local _, operations = api.plan_document(query, "sales",
        encode_json(document))
    local labels = {}
    for _, operation in ipairs(operations) do labels[#labels + 1] = operation.label end
    assert_equal(#labels, 4)
    assert_contains(labels[1], "ADD_SEMANTIC_IDENTITY")
    assert_contains(labels[2], "ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS")
    assert_contains(labels[3], "attribute binding")
    assert_contains(labels[4], "SET_ATTRIBUTE_FUSION_POLICY")
    -- The alternate carries authority, coverage and identity in one call rather
    -- than as separate operations that would each be refused.
    assert_contains(operations[2].params.declarations_json, "AUTHORITATIVE")
    assert_contains(operations[2].params.declarations_json, "MAPPED")
end)

test("a representation carries its own attribute bindings into one call", function()
    -- The canonical F4 shape: a supplemental source narrower than the primary.
    -- Entity-level bindings arrive after the representation has been registered
    -- and validated, so on a published model they are always too late; scoping
    -- them to the representation is what puts them in the same candidate.
    local document = {entities = {customer = {
        representations = {{
            name = "crm", source_schema = "CRM", source_object = "C",
            priority = 20, authority = "AUTHORITATIVE",
            attribute_bindings = {{attribute_type = "DIMENSION",
                attribute_name = "customer_region",
                source_expression = "CAST(NULL AS VARCHAR(20))",
                binding_role = "FALLBACK", binding_priority = 2}},
        }},
    }}}
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "PUBLISHED"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1}}
        end
        return {}
    end)
    local planned, operations = api.plan_document(query, "sales", encode_json(document))
    assert_branch("fusion.document.representation_bindings", planned ~= nil, true)
    -- One operation, not two: the bindings ride along rather than following.
    assert_equal(#operations, 1)
    assert_contains(operations[1].label, "ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS")
    assert_contains(operations[1].params.declarations_json, "attribute_bindings")
    assert_contains(operations[1].params.declarations_json, "CAST(NULL AS VARCHAR(20))")

    -- Naming the representation again inside its own binding is refused: the
    -- enclosing object already says which representation this is.
    local redundant = {entities = {customer = {representations = {{
        name = "crm", source_schema = "CRM", source_object = "C",
        attribute_bindings = {{attribute_type = "DIMENSION",
            attribute_name = "customer_region", representation = "crm",
            source_expression = "CAST(NULL AS VARCHAR(20))"}},
    }}}}}
    local ok, err = pcall(api.plan_document, query, "sales", encode_json(redundant))
    assert_branch("fusion.document.representation_bindings", ok, false)
    assert_contains(tostring(err), "SEMANTIC_FUSION_011")

    local empty = {entities = {customer = {representations = {{
        name = "crm", source_schema = "CRM", source_object = "C",
        attribute_bindings = {},
    }}}}}
    local empty_ok, empty_err = pcall(api.plan_document, query, "sales",
        encode_json(empty))
    assert_true(not empty_ok)
    assert_contains(tostring(empty_err), "SEMANTIC_FUSION_017")
end)

test("representation-scoped coverage becomes one call for the entity", function()
    -- It used to become none at all. The batch entry was built without naming
    -- the representation it was about, so every representation-scoped `coverage`
    -- was refused with "COVERAGE_JSON[1].representation_name is required" -- for
    -- a field the document schema does not have.
    --
    -- And one entry per representation could not have worked either:
    -- SET_REPRESENTATION_COVERAGE_BATCH refuses a list that does not name every
    -- active representation, which is what makes a partitioned set
    -- initializable at all. So the entries are collected for the entity.
    local document = {entities = {customer = {
        representations = {
            {name = "primary", source_schema = "MDM", source_object = "C_MDM",
             priority = 10,
             coverage = {valid_to = "2026-01-01 00:00:00",
                         predicate = "c.opened_at < TIMESTAMP '2026-01-01 00:00:00'"}},
            {name = "crm", source_schema = "CRM", source_object = "C_CRM",
             priority = 20,
             coverage = {valid_from = "2026-01-01 00:00:00",
                         predicate = "c.opened_at >= TIMESTAMP '2026-01-01 00:00:00'"}},
        },
    }}}
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "PUBLISHED"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1}}
        end
        return {}
    end)
    local planned, operations = api.plan_document(query, "sales", encode_json(document))
    assert_branch("fusion.document.representation_coverage", planned ~= nil, true)

    local coverage_ops = {}
    for _, operation in ipairs(operations) do
        if tostring(operation.label):find("SET_REPRESENTATION_COVERAGE_BATCH", 1, true) then
            coverage_ops[#coverage_ops + 1] = operation
        end
    end
    -- One, for the entity -- not one per representation.
    assert_equal(#coverage_ops, 1)
    assert_contains(coverage_ops[1].label, "customer")
    -- Each entry names its own representation, which is the assignment that was
    -- missing, and both are in the one payload.
    assert_contains(coverage_ops[1].params.coverage_json, "\"representation_name\"")
    assert_contains(coverage_ops[1].params.coverage_json, "primary")
    assert_contains(coverage_ops[1].params.coverage_json, "crm")

    -- Coverage is applied last: it turns the set into a partition, and a
    -- partition is validated attribute by attribute, so it has to follow any
    -- bindings the same document adds.
    assert_equal(operations[#operations].params.coverage_json ~= nil, true)

    -- A scalar where the object belongs is refused by name. Without the check it
    -- reached `coverage.valid_from` and failed as "attempt to index a string
    -- value", which names the runtime rather than the document.
    local scalar = {entities = {customer = {representations = {{
        name = "crm", source_schema = "CRM", source_object = "C",
        coverage = "2026-01-01",
    }}}}}
    local ok, err = pcall(api.plan_document, query, "sales", encode_json(scalar))
    assert_branch("fusion.document.representation_coverage", ok, false)
    assert_contains(tostring(err), "SEMANTIC_FUSION_019")
end)

test("fusion document refuses an identity binding with no identity", function()
    local document = {entities = {customer = {representations = {{
        name = "crm", source_schema = "CRM", source_object = "C",
        identity_binding = {source_expression = "c.account_id"},
    }}}}}
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "DRAFT"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1}}
        end
        return {}
    end)
    local ok, err = pcall(api.plan_document, query, "sales", encode_json(document))
    assert_true(not ok)
    assert_contains(tostring(err), "SEMANTIC_FUSION_014")
end)

test("fusion document refuses an entity the model does not have", function()
    -- A typo'd entity name is the likeliest error in a hand-edited document, and
    -- it used to report success having done nothing. Unknown *keys* were already
    -- refused by name; the closed contract had a hole exactly where a human
    -- pokes it.
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "DRAFT"}}
        end
        -- No entity rows: nothing resolves.
        return {}
    end)
    local ok, err = pcall(api.plan_document, query, "sales",
        encode_json({entities = {nosuchentity = {representations = {}}}}))
    assert_branch("fusion.document.entity_resolves", ok, false)
    assert_contains(tostring(err), "SEMANTIC_FUSION_018")
    assert_contains(tostring(err), "nosuchentity")

    local resolving = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "DRAFT"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1}}
        end
        return {}
    end)
    local good = pcall(api.plan_document, resolving, "sales",
        encode_json({entities = {customer = {representations = {}}}}))
    assert_branch("fusion.document.entity_resolves", good, true)
end)

test("fusion document refuses a document that names another model", function()
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "DRAFT"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1}}
        end
        return {}
    end)
    local ok, err = pcall(api.plan_document, query, "sales",
        encode_json({model = "other", entities = {}}))
    assert_branch("fusion.document.model_agreement", ok, false)
    assert_contains(tostring(err), "SEMANTIC_FUSION_015")

    -- Omitting `model` is fine; the argument decides.
    local silent_ok = pcall(api.plan_document, query, "sales",
        encode_json({entities = {}}))
    assert_branch("fusion.document.model_agreement", silent_ok, true)
end)

test("fusion rollback reads its column lists from the catalog", function()
    -- Restating seven tables' columns here is how a rollback silently stops
    -- carrying whatever column was added last. EXA_ALL_COLUMNS is asked instead.
    local asked, inserted, deleted = {}, {}, {}
    local query = fake_query(function(sql, params)
        if sql:find("FROM SYS.EXA_ALL_COLUMNS", 1, true) then
            asked[#asked + 1] = params.table_name
            return {{"MODEL_ID"}, {"VERSION_ID"}, {"A_COLUMN"}}
        elseif sql:find("^SELECT MODEL_ID, VERSION_ID, A_COLUMN") then
            return {{7, 9, "kept"}}
        elseif sql:find("DELETE FROM SYS_SEMANTIC.", 1, true) then
            deleted[#deleted + 1] = sql:match("DELETE FROM SYS_SEMANTIC%.([A-Z_]+)")
            return {}
        elseif sql:find("INSERT INTO SYS_SEMANTIC.", 1, true) then
            inserted[#inserted + 1] = sql:match("INSERT INTO SYS_SEMANTIC%.([A-Z_]+)")
            return {}
        end
        return {}
    end)
    local model = {model_id = 7, version_id = 9, model_name = "sales"}
    local snapshot = api.snapshot_fusion_state(query, model)
    assert_equal(#snapshot, 7)
    assert_equal(asked[1], "ENTITY_REPRESENTATIONS")
    assert_equal(asked[#asked], "ATTRIBUTE_FUSION_POLICIES")
    assert_equal(snapshot[1].columns[3], "A_COLUMN")

    api.restore_fusion_state(query, model, snapshot)
    -- Deleted children-first, reinserted parents-first, or a restore trips over
    -- its own rows.
    assert_equal(deleted[1], "ATTRIBUTE_FUSION_POLICIES")
    assert_equal(deleted[7], "ENTITY_REPRESENTATIONS")
    assert_equal(inserted[1], "ENTITY_REPRESENTATIONS")
    assert_equal(#inserted, 7)
    -- And the compile cache goes with it. The dispatched scripts clear it when
    -- they mutate, but this restore writes SYS_SEMANTIC directly -- so an entry
    -- compiled during the abandoned attempt would otherwise outlive it and
    -- answer from a plan built on fusion metadata that no longer exists.
    assert_equal(deleted[#deleted], "COMPILE_CACHE")
end)

test("fusion export leaves out entities that have nothing fused", function()
    -- The document should be proportional to the fusion, not to the model: a
    -- single-source entity with no identity and no declarations says nothing.
    assert_branch("fusion.export.is_fused",
        api.is_fused({representations = {{name = "primary"}}}), false)
    assert_branch("fusion.export.is_fused",
        api.is_fused({representations = {{name = "primary"}, {name = "crm"}}}), true)
    assert_true(api.is_fused({representations = {{name = "primary"}},
        identity = {name = "cid"}}))
    -- One representation is enough when it carries a declaration of its own.
    assert_true(api.is_fused({representations = {{name = "primary",
        authority = "AUTHORITATIVE"}}}))
    assert_true(api.is_fused({representations = {{name = "primary",
        coverage = {valid_to = "2026-01-01"}}}}))
end)

test("the exported document is one object that always names its model", function()
    -- Two shapes the round trip depends on. `entities` must be a JSON *object*
    -- even when empty -- an empty Lua table serialises as `[]`, which would make
    -- a consumer handle two types for one field. And `model` must always be
    -- present: SEMANTIC_FUSION_015 reads it to refuse a document applied to the
    -- wrong model, and the first version emitted it only when there was no
    -- fusion, so the guard could never fire on an exported file.
    local empty_query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "DRAFT"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1}}
        end
        return {}
    end)
    local empty
    with_query(empty_query, function()
        empty = export_document_json("sales", nil)
    end)
    assert_equal(empty, '{"entities":{},"model":"sales"}')

    local fused_query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "DRAFT"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r", 1, true) then
            return {{"customer", 1, "primary", "RELATION", "MDM", "C", "c",
                     "PRIMARY", 10, null, null, null, null, null},
                    {"customer", 2, "crm", "RELATION", "CRM", "C", "c",
                     "ALTERNATE", 20, "MANUAL", null, null, null, "AUTHORITATIVE"}}
        end
        return {}
    end)
    local fused
    with_query(fused_query, function()
        fused = export_document_json("sales", nil)
    end)
    assert_contains(fused, '"model":"sales"')
    assert_contains(fused, '"entities":{"customer":')
    -- Never an array once populated either.
    assert_true(not fused:find('"entities":%['))
end)

test("an attribute policy that already matches is not re-applied", function()
    -- This was the one operation of six with no comparison, so an exported
    -- document never converged: five reported "already matches" and this kept
    -- APPLIED_COUNT at 1 forever, turning a CI drift check into a permanent
    -- false positive.
    local document = {entities = {customer = {
        attribute_policies = {{attribute_type = "DIMENSION",
            attribute_name = "customer_region", strategy = "RECONCILE"}},
    }}}
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "PUBLISHED"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1}}
        end
        return {}
    end)
    local model, operations = api.plan_document(query, "sales", encode_json(document))
    assert_equal(#operations, 1)
    assert_contains(operations[1].label, "SET_ATTRIBUTE_FUSION_POLICY")
    assert_true(operations[1].skip_fn ~= nil)

    local stored = fake_query(function(sql)
        if sql:find("ATTRIBUTE_FUSION_POLICIES", 1, true) then return {{1}} end
        return {}
    end)
    local absent = fake_query(function() return {} end)
    assert_branch("fusion.document.policy_matches",
        operations[1].skip_fn(stored, model), true)
    assert_branch("fusion.document.policy_matches",
        operations[1].skip_fn(absent, model), false)
end)

test("fusion export omits absent values instead of writing nulls", function()
    -- The round-trip compares documents, so `{"a": null}` and `{}` must not be
    -- two spellings of the same model.
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "DRAFT"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r", 1, true) then
            return {{"customer", 1, "primary", "RELATION", "MDM", "C", "c",
                     "PRIMARY", 10, null, null, null, null, null}}
        elseif sql:find("FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES i", 1, true) then
            return {{"customer", "cid", "GLOBAL", "DECIMAL(18,0)", null}}
        end
        return {}
    end)
    local document = api.build_document(query, "sales", nil)
    local entity = document.entities.customer
    assert_equal(entity.identity.name, "cid")
    -- DESCRIPTION was NULL, so the key is absent rather than present-and-null.
    assert_true(entity.identity.description == nil)
    local representation = entity.representations[1]
    assert_true(representation.coverage == nil)
    assert_true(representation.authority == nil)
    assert_equal(representation.priority, 10)
end)

test("fusion document reads an explicit JSON null as absent, not as a value", function()
    -- This module used to reach an encoder by importing SEMANTIC_DEFINITION_RUNTIME,
    -- so it decoded documents with a sentinel it had no name for: its own
    -- missing() checked nil and Exasol's `null` but not the decoder's null,
    -- whose tostring is "table: 0x...". An explicit `"source_alias": null` was
    -- therefore a *present* value, and the address went to the catalog. Sharing
    -- one codec is what makes the sentinel nameable here.
    assert_true(ESV_JSON.decode('{"k":null}').k == ESV_JSON.NULL)

    -- Absent, so the same as an omitted key wherever a value is optional.
    assert_equal(api.is_fused ~= nil, true)
    local document = ESV_JSON.decode([[
        {"model": null,
         "entities": {"CUSTOMER": {"identity": null}}}
    ]])
    assert_equal(document.model, ESV_JSON.NULL)

    -- A null `model` is an omitted model, not a model named "table: 0x...", so
    -- the document applies to the model it was addressed to.
    local model_rows = function(sql)
        if string.find(sql, "FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{MODEL_ID = 1, ACTIVE_VERSION_ID = 2, MODEL_NAME = "sales",
                STATUS = "DRAFT"}}
        end
        return {}
    end
    local ok, err = pcall(api.plan_document, fake_query(model_rows), "sales",
        ESV_JSON.encode({model = ESV_JSON.NULL, entities = {}}))
    assert_true(ok, tostring(err))

    -- But a null where an object belongs is malformed, not an empty object: a
    -- declaration read as "declare nothing" is the silent drop the closed
    -- contract exists to prevent.
    local null_ok, null_err = pcall(api.reject_unknown, ESV_JSON.NULL,
        {authority = true}, "representation")
    assert_true(not null_ok)
    assert_contains(tostring(null_err), "SEMANTIC_FUSION_010")
    assert_contains(tostring(null_err), "must be a JSON object")
    assert_branch("fusion.document.closed_contract", null_ok, false)
end)

-- A mock catalog that answers just enough for apply_fusion_declaration to run:
-- one model, one entity, catalog columns for the rollback, and a validation
-- result the caller chooses. Statements are recorded in order so a test can say
-- what ran and what ran after a failure.
local function applying_catalog(options)
    local log = {}
    local validation_calls = 0
    local mock = function(sql, params)
        local text = tostring(sql)
        log[#log + 1] = text
        if text:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{MODEL_ID = 1, ACTIVE_VERSION_ID = 2, MODEL_NAME = "sales",
                STATUS = options.status or "DRAFT"}}
        elseif text:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1}}
        elseif text:find("FROM SYS.EXA_ALL_COLUMNS", 1, true) then
            return {{COLUMN_NAME = "MODEL_ID"}, {COLUMN_NAME = "VERSION_ID"},
                {COLUMN_NAME = "A_COLUMN"}}
        elseif text:find("VALIDATE_MODEL", 1, true) then
            validation_calls = validation_calls + 1
            return options.validation or {}
        elseif text:find("^SELECT MODEL_ID, VERSION_ID, A_COLUMN") then
            return {{1, 2, "captured"}}
        elseif options.fail_on ~= nil and text:find(options.fail_on, 1, true) then
            error("SEMANTIC_ADMIN_099: refused by the dispatched script")
        end
        return {}
    end
    return mock, log
end

local function with_global_query(mock, fn)
    local original = query
    query = mock
    local ok, result = xpcall(fn, debug.traceback)
    query = original
    if not ok then error(result, 0) end
    return result
end

local DOCUMENT = ESV_JSON.encode({
    model = "sales",
    entities = {CUSTOMER = {representations = {{name = "crm",
        source_kind = "RELATION", source_schema = "MART",
        source_object = "CRM_CUSTOMERS", authority = "AUTHORITATIVE"}}}},
})

test("fusion apply restores the catalog when validation refuses the result", function()
    -- The document is applied first and judged second, because fusion validation
    -- runs *data* probes -- overlap, conflict, key coverage -- that cannot be
    -- answered from metadata. So a rejected declaration is one that has already
    -- been written, and the restore is the only thing standing between a refusal
    -- and a half-applied governance change.
    local mock, log = applying_catalog({validation = {
        {"ERROR", "ENTITY", "CUSTOMER", "SEMANTIC_MODEL_047",
         "identity binding is incomplete"},
    }})
    local rows = with_global_query(mock, function()
        return apply_fusion_declaration("sales", DOCUMENT, false)
    end)
    assert_equal(rows[1][1], "ERROR")
    assert_equal(rows[1][2], "SEMANTIC_FUSION_091")
    -- The refusal quotes the rule that blocked it, not just that something did.
    assert_contains(rows[1][3], "SEMANTIC_MODEL_047")
    assert_contains(rows[1][3], "identity binding is incomplete")
    assert_contains(rows[1][3], "Catalog state was restored")
    assert_branch("fusion.apply.validated", rows[1][1] == "OK", false)

    local validated, deleted, inserted, cache_cleared = false, false, false, false
    for _, statement in ipairs(log) do
        if statement:find("VALIDATE_MODEL", 1, true) then validated = true
        elseif validated and statement:find("DELETE FROM SYS_SEMANTIC.", 1, true) then
            deleted = true
            if statement:find("COMPILE_CACHE", 1, true) then cache_cleared = true end
        elseif validated and statement:find("INSERT INTO SYS_SEMANTIC.", 1, true) then
            inserted = true
        end
    end
    assert_true(deleted, "nothing was cleared after validation failed")
    assert_true(inserted, "the captured rows were not written back")
    -- The dispatched scripts invalidate the compile cache when they mutate, but
    -- the restore writes SYS_SEMANTIC directly, so it has to do it itself.
    assert_true(cache_cleared, "the compile cache survived the rollback")
end)

test("fusion apply reports what it ran, and a dry run commits none of it", function()
    local mock = applying_catalog({})
    local applied = with_global_query(mock, function()
        return apply_fusion_declaration("sales", DOCUMENT, false)
    end)
    assert_equal(applied[1][1], "OK")
    assert_equal(applied[1][2], null)
    assert_contains(applied[1][3], "Fusion declaration applied")
    assert_true(applied[1][4] > 0, "no operations were planned")
    assert_equal(applied[1][5], applied[1][4])
    assert_branch("fusion.apply.validated", applied[1][1] == "OK", true)

    local dry_mock, dry_log = applying_catalog({})
    local dry = with_global_query(dry_mock, function()
        return apply_fusion_declaration("sales", DOCUMENT, "TRUE")
    end)
    assert_equal(dry[1][1], "DRY_RUN")
    assert_contains(dry[1][3], "no catalog changes were committed")
    -- A dry run is an apply followed by a restore, so it must both validate and
    -- put the rows back -- a dry run that skipped the apply would not be able to
    -- answer the data probes it exists to answer.
    local validated, restored = false, false
    for _, statement in ipairs(dry_log) do
        if statement:find("VALIDATE_MODEL", 1, true) then validated = true
        elseif validated and statement:find("INSERT INTO SYS_SEMANTIC.", 1, true) then
            restored = true
        end
    end
    assert_true(validated, "a dry run must still validate")
    assert_true(restored, "a dry run must put the captured rows back")
end)

test("fusion apply unwinds when a dispatched script refuses mid-sequence", function()
    -- The scripts each unwind only themselves, so a sequence that stops halfway
    -- leaves the model in a state no single script owns.
    local mock, log = applying_catalog({fail_on = "ADD_ENTITY_REPRESENTATION"})
    local rows = with_global_query(mock, function()
        return apply_fusion_declaration("sales", DOCUMENT, false)
    end)
    assert_equal(rows[1][1], "ERROR")
    -- The dispatched script's own code is carried through rather than replaced
    -- by a generic fusion code, so the caller sees why it was refused.
    assert_equal(rows[1][2], "SEMANTIC_ADMIN_099")
    assert_equal(rows[1][5], 0, "nothing should be reported as applied")
    local restored = false
    for _, statement in ipairs(log) do
        if statement:find("INSERT INTO SYS_SEMANTIC.", 1, true) then restored = true end
    end
    assert_true(restored, "the captured rows were not written back")
end)

test("fusion apply reports a malformed document in STATUS, not as a raise", function()
    -- A caller checks one column for every kind of failure; splitting parse
    -- errors out would mean a caller that checks STATUS still misses them.
    local mock = applying_catalog({})
    local rows = with_global_query(mock, function()
        return apply_fusion_declaration("sales", "{not json", false)
    end)
    assert_equal(rows[1][1], "ERROR")
    assert_equal(rows[1][2], "SEMANTIC_FUSION_010")
    assert_equal(rows[1][4], 0)
    assert_equal(rows[1][5], 0)
end)

test("fusion export assembles a full document from named catalog rows", function()
    -- Named rows, on purpose. Every read in the export path carries a column
    -- name *and* a hand-counted ordinal, and shared/rows.lua now refuses a named
    -- row that has to answer by ordinal -- so this fixture is simultaneously a
    -- test of the document and a check that the names and ordinals agree with
    -- the SELECTs above them. A renamed column in one of those queries fails
    -- here rather than exporting a document with a field silently missing.
    local mock = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{MODEL_ID = 1, ACTIVE_VERSION_ID = 2, MODEL_NAME = "sales",
                STATUS = "PUBLISHED"}}
        elseif sql:find("FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS", 1, true) then
            return {{ENTITY_NAME = "customer", REPRESENTATION_ID = 11,
                REPRESENTATION_NAME = "crm", SOURCE_KIND = "RELATION",
                SOURCE_SCHEMA = "MART", SOURCE_OBJECT = "CRM_CUSTOMERS",
                SOURCE_ALIAS = "crm", REPRESENTATION_ROLE = "SUPPLEMENTAL",
                PRIORITY = 20, FRESHNESS_POLICY = "DAILY",
                COVERAGE_PREDICATE = "crm.region = 'EMEA'",
                VALID_FROM = null, VALID_TO = null,
                AUTHORITY_ROLE = "AUTHORITATIVE"}}
        elseif sql:find("FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES", 1, true) then
            return {{ENTITY_NAME = "customer", IDENTITY_NAME = "customer_key",
                IDENTITY_KIND = "NATURAL", DATA_TYPE = "VARCHAR(64)",
                DESCRIPTION = "the shared customer key"}}
        elseif sql:find("FROM SYS_SEMANTIC.IDENTITY_BINDINGS", 1, true) then
            return {{ENTITY_NAME = "customer", REPRESENTATION_NAME = "crm",
                SOURCE_EXPRESSION = "crm.account_id", BINDING_KIND = "MAPPED",
                SOURCE_SCHEMA = "MART", SOURCE_OBJECT = "CRM_MAP",
                SOURCE_LOCAL_COLUMN = "account_id",
                SEMANTIC_KEY_COLUMN = "customer_key",
                CERTIFICATION_STATUS = "CERTIFIED"}}
        elseif sql:find("FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS", 1, true) then
            return {{ENTITY_NAME = "customer", ATTRIBUTE_TYPE = "DIMENSION",
                ATTRIBUTE_NAME = "customer_region", REPRESENTATION_NAME = "crm",
                SOURCE_EXPRESSION = "crm.region", BINDING_ROLE = "PREFER",
                BINDING_PRIORITY = 5}}
        elseif sql:find("FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES", 1, true) then
            return {{ENTITY_NAME = "customer", ATTRIBUTE_TYPE = "DIMENSION",
                ATTRIBUTE_NAME = "customer_region", FUSION_STRATEGY = "PREFER"}}
        end
        return {}
    end)

    local document = api.build_document(mock, "sales", nil)
    assert_equal(document.model, "sales")
    local entity = document.entities.customer
    assert_true(entity ~= nil, "the entity was not assembled")

    local representation = entity.representations[1]
    assert_equal(representation.name, "crm")
    assert_equal(representation.role, "SUPPLEMENTAL")
    assert_equal(representation.source_schema, "MART")
    assert_equal(representation.source_object, "CRM_CUSTOMERS")
    assert_equal(representation.source_alias, "crm")
    assert_equal(representation.priority, 20)
    assert_equal(representation.freshness_policy, "DAILY")
    assert_equal(representation.authority, "AUTHORITATIVE")
    assert_equal(representation.coverage.predicate, "crm.region = 'EMEA'")

    assert_equal(entity.identity.name, "customer_key")
    assert_equal(entity.identity.kind, "NATURAL")
    assert_equal(entity.identity.data_type, "VARCHAR(64)")

    -- The mapped binding and its two-column mapping relation, which is what F5
    -- needs to reach a semantic key at all.
    local binding = representation.identity_binding
    assert_equal(binding.binding_kind, "MAPPED")
    assert_equal(binding.source_expression, "crm.account_id")
    assert_equal(binding.mapping.source_object, "CRM_MAP")
    assert_equal(binding.mapping.source_local_column, "account_id")
    assert_equal(binding.mapping.semantic_key_column, "customer_key")
    assert_equal(binding.mapping.certification_status, "CERTIFIED")

    assert_equal(entity.attribute_bindings[1].attribute_name, "customer_region")
    assert_equal(entity.attribute_bindings[1].binding_priority, 5)
    assert_equal(entity.attribute_policies[1].strategy, "PREFER")

    -- And the document round-trips through the codec that writes it.
    local encoded = api.build_document(mock, "sales", nil)
    assert_equal(ESV_JSON.encode(document), ESV_JSON.encode(encoded))
end)
