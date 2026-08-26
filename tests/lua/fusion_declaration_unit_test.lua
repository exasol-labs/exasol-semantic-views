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

test("fusion document refuses an identity binding with no identity", function()
    local document = {entities = {customer = {representations = {{
        name = "crm", source_schema = "CRM", source_object = "C",
        identity_binding = {source_expression = "c.account_id"},
    }}}}}
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "DRAFT"}}
        end
        return {}
    end)
    local ok, err = pcall(api.plan_document, query, "sales", encode_json(document))
    assert_true(not ok)
    assert_contains(tostring(err), "SEMANTIC_FUSION_014")
end)

test("fusion document refuses a document that names another model", function()
    local query = fake_query(function(sql)
        if sql:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{7, 9, "sales", "DRAFT"}}
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
