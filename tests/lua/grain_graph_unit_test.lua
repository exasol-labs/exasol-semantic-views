local graph = ESV_GRAIN_GRAPH

test("shared grain graph builds cardinality-preserving directions", function()
    local relationships = {
        {id = 1, name = "one", from_entity_id = 1, to_entity_id = 2,
            cardinality = "ONE_TO_ONE", path_priority = 20},
        {id = 2, name = "many_one", from_entity_id = 2, to_entity_id = 3,
            cardinality = "MANY_TO_ONE", path_priority = 10},
        {id = 3, name = "one_many", from_entity_id = 3, to_entity_id = 4,
            cardinality = "ONE_TO_MANY"},
        {id = 4, name = "bridge", from_entity_id = 4, to_entity_id = 5,
            cardinality = "MANY_TO_MANY", fanout_policy = "ALLOCATE"},
    }
    local safe, all = graph.build_edges(relationships)
    assert_equal(safe["1"][1].to_id, 2)
    assert_equal(safe["2"][1].name, "many_one")
    assert_equal(safe["4"][1].name, "one_many")
    assert_true(safe["5"] ~= nil)
    assert_equal(all["3"][1].reason, "FANOUT_REQUIRES_POLICY")

    local strict = graph.build_edges(relationships, {allow_many_to_many = false})
    assert_true(strict["5"] == nil)
end)

test("shared path proof handles self blocked missing and absent paths", function()
    local edges = {
        ["1"] = {
            {from_id = 1, to_id = 2, name = "safe", safe = true},
            {from_id = 1, to_id = 3, name = "blocked", safe = false,
                reason = "FANOUT_REQUIRES_POLICY"},
        },
    }
    local self = graph.prove_path(edges, 1, 1, {require_safe = true})
    assert_true(self.ok)
    assert_equal(self.path, "SELF")

    local blocked = graph.prove_path(edges, 1, 3, {require_safe = true})
    assert_true(not blocked.ok)
    assert_equal(blocked.reason, "FANOUT_REQUIRES_POLICY")

    local absent = graph.prove_path(edges, 2, 3, {require_safe = true})
    assert_equal(absent.reason, "NO_RELATIONSHIP_PATH")
    local missing = graph.prove_path(edges, nil, 3, {require_safe = true})
    assert_equal(missing.reason, "MISSING_ENTITY")
end)

test("shared path proof detects semantic ambiguity deterministically", function()
    local edges = {
        ["1"] = {
            {from_id = 1, to_id = 2, name = "billing", safe = true},
            {from_id = 1, to_id = 3, name = "shipping", safe = true},
        },
        ["2"] = {{from_id = 2, to_id = 4, name = "billing_customer", safe = true}},
        ["3"] = {{from_id = 3, to_id = 4, name = "shipping_customer", safe = true}},
    }
    local rejected = graph.prove_path(edges, 1, 4, {
        require_safe = true,
        reject_ambiguous = true,
    })
    assert_true(not rejected.ok)
    assert_true(rejected.ambiguous)
    assert_equal(rejected.reason, "AMBIGUOUS_RELATIONSHIP_PATH")
    assert_equal(#rejected.candidate_paths, 2)

    local legacy = graph.prove_path(edges, 1, 4, {
        require_safe = true,
        reject_ambiguous = false,
    })
    assert_true(legacy.ok)
    assert_true(legacy.ambiguous)
    assert_equal(legacy.path, "billing > billing_customer")
end)

test("canonical composite keys match ordered relationship mappings", function()
    local unique_key = graph.canonical_key({
        id = 7,
        entity_id = 4,
        name = "customer_tenant",
        kind = "primary",
        columns = {
            {ordinal_position = 2, column_name = "customer_id"},
            {ordinal_position = 1, column_name = "tenant_id"},
        },
    })
    assert_equal(unique_key.kind, "PRIMARY")
    assert_equal(unique_key.columns[1].column_name, "tenant_id")
    local mappings = {
        {to_column_name = "tenant_id"},
        {to_column_name = "customer_id"},
    }
    assert_true(graph.mapping_matches_key(mappings, "to", unique_key))
    mappings[2].to_column_name = "account_id"
    assert_true(not graph.mapping_matches_key(mappings, "to", unique_key))

    local expression_key = graph.canonical_key({
        columns = {{ordinal_position = 1, expression = "UPPER(c.email)"}},
    })
    assert_true(graph.mapping_matches_key(
        {{to_expression = "UPPER(c.email)"}}, "to", expression_key
    ))
end)

test("F5.1 direct relationship remap requires a scalar anchored identity", function()
    local key = graph.canonical_key({id = 50, entity_id = 2, name = "customer_pk",
        columns = {{ordinal_position = 1, column_name = "CUSTOMER_ID"}}})
    local mappings = {{ordinal_position = 1, from_column_name = "CUSTOMER_ID",
        to_column_name = "CUSTOMER_ID"}}
    local matched = graph.scalar_mapping_key({key}, mappings, "to")
    assert_equal(matched.id, 50)

    local primary = {id = 10, alias = "c"}
    local mongo = {id = 11, alias = "c"}
    local identity = {binding_by_representation = {
        ['10'] = {id = 20, kind = "DIRECT", expression = "c.CUSTOMER_ID"},
        ['11'] = {id = 21, kind = "DIRECT",
            expression = 'CAST(c."customer_id" AS DECIMAL(18,0))'},
    }}
    local remap = graph.direct_identity_remap(identity, primary, mongo, key)
    assert_equal(remap.binding.id, 21)

    identity.binding_by_representation['10'].expression = "c.EMAIL"
    local rejected, reason = graph.direct_identity_remap(identity, primary, mongo, key)
    assert_equal(rejected, nil)
    assert_equal(reason, "SEMANTIC_IDENTITY_NOT_ANCHORED_TO_RELATIONSHIP_KEY")

    local composite = graph.scalar_mapping_key({key}, {mappings[1], mappings[1]}, "to")
    assert_equal(composite, nil)
end)

test("validator and compiler expose the same canonical path proof", function()
    local relationships = {
        {id = 1, name = "orders_customer", from_entity_id = 1, to_entity_id = 2,
            cardinality = "MANY_TO_ONE", path_priority = 100},
        {id = 2, name = "customer_region", from_entity_id = 2, to_entity_id = 3,
            cardinality = "MANY_TO_ONE", path_priority = 100},
    }
    local validator_edges = ESV_VALIDATOR_TEST_API.relationship_edges({
        relationships = relationships,
        entity_name_by_id = {['1'] = "orders", ['2'] = "customers", ['3'] = "regions"},
        entity_alias_by_id = {['1'] = "O", ['2'] = "C", ['3'] = "R"},
        issues = {},
        issue_seen = {},
        error_count = 0,
        warning_count = 0,
    })
    local validator_ok, validator_reason, validator_path =
        ESV_VALIDATOR_TEST_API.find_path(validator_edges, 1, 3, true)
    local compiler_ctx = {relationships = relationships}
    local compiler_path = ESV_COMPILER_TEST_API.find_path(compiler_ctx, 1, 3)
    assert_true(validator_ok)
    assert_equal(validator_reason, "OK")
    assert_equal(validator_path, "orders_customer > customer_region")
    assert_equal(compiler_path[1].relationship.name, "orders_customer")
    assert_equal(compiler_path[2].relationship.name, "customer_region")
end)
