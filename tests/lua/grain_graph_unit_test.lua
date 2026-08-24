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
    assert_equal(all["3"][1].reason, "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED")

    -- A declared fanout policy is not an allocation proof: the bridge edge is
    -- visible in the complete graph for diagnostics and absent from the safe
    -- graph in both directions.
    assert_true(safe["5"] == nil)
    for _, edge in ipairs(safe["4"] or {}) do
        assert_true(edge.name ~= "bridge")
    end
    assert_equal(all["5"][1].name, "bridge")
    assert_equal(all["5"][1].reason, "MANY_TO_MANY_UNSUPPORTED")
    local bridge_reason = nil
    for _, edge in ipairs(all["4"] or {}) do
        if edge.name == "bridge" then bridge_reason = edge.reason end
    end
    assert_equal(bridge_reason, "MANY_TO_MANY_UNSUPPORTED")
end)

test("shared path proof handles self blocked missing and absent paths", function()
    local edges = {
        ["1"] = {
            {from_id = 1, to_id = 2, name = "safe", safe = true},
            {from_id = 1, to_id = 3, name = "blocked", safe = false,
                reason = "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED"},
        },
    }
    local self = graph.prove_path(edges, 1, 1, {require_safe = true})
    assert_true(self.ok)
    assert_equal(self.path, "SELF")

    local blocked = graph.prove_path(edges, 1, 3, {require_safe = true})
    assert_true(not blocked.ok)
    assert_equal(blocked.reason, "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED")

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

test("shared attempted path annotates the edge that blocked a safe walk", function()
    local relationships = {
        {id = 1, name = "line_to_order", from_entity_id = 1, to_entity_id = 2,
            cardinality = "MANY_TO_ONE"},
        {id = 2, name = "order_to_shipment", from_entity_id = 2, to_entity_id = 3,
            cardinality = "MANY_TO_MANY", fanout_policy = "ALLOCATE"},
    }
    local safe, all = graph.build_edges(relationships)

    -- Safe walk: nothing is annotated and no reason is reported.
    local path, reason = graph.attempted_path(all, 1, 2)
    assert_equal(path, "line_to_order")
    assert_equal(reason, nil)
    assert_true(graph.prove_path(safe, 1, 2, {require_safe = true}).ok)

    -- Blocked walk: the many-to-many edge is named with its rejection reason.
    local blocked_path, blocked_reason = graph.attempted_path(all, 1, 3)
    assert_equal(blocked_path,
        "line_to_order > order_to_shipment (rejected: MANY_TO_MANY_UNSUPPORTED)")
    assert_equal(blocked_reason, "MANY_TO_MANY_UNSUPPORTED")

    -- Unreachable target: no path text, and the walk's own reason is returned.
    local absent_path, absent_reason = graph.attempted_path(all, 3, 99)
    assert_equal(absent_path, nil)
    assert_equal(absent_reason, "NO_RELATIONSHIP_PATH")
    assert_equal(graph.rejected_path_text({}), nil)
end)

test("shared attempted path reports every candidate when the graph is ambiguous", function()
    local relationships = {
        {id = 1, name = "billing", from_entity_id = 1, to_entity_id = 2,
            cardinality = "MANY_TO_ONE"},
        {id = 2, name = "shipping", from_entity_id = 1, to_entity_id = 3,
            cardinality = "MANY_TO_ONE"},
        {id = 3, name = "billing_customer", from_entity_id = 2, to_entity_id = 4,
            cardinality = "MANY_TO_MANY", fanout_policy = "ALLOCATE"},
        {id = 4, name = "shipping_customer", from_entity_id = 3, to_entity_id = 4,
            cardinality = "MANY_TO_ONE"},
    }
    local _, all = graph.build_edges(relationships)
    local paths, reason = graph.attempted_path(all, 1, 4)
    assert_equal(reason, "AMBIGUOUS_RELATIONSHIP_PATH")
    assert_contains(paths, "billing > billing_customer (rejected: MANY_TO_MANY_UNSUPPORTED)")
    assert_contains(paths, "shipping > shipping_customer")
end)

test("safe path alternatives name a longer path the shortest one won against", function()
    -- A shortcut edge to beta plus the two-step walk through alpha. Both are
    -- safe, so prove_path selects the shortest and reports no ambiguity: the
    -- tie test never fires because the lengths differ. The alternative still
    -- attributes a fact row to a different row of beta.
    local relationships = {
        {id = 1, name = "fact_to_beta", from_entity_id = 1, to_entity_id = 3,
            cardinality = "MANY_TO_ONE"},
        {id = 2, name = "fact_to_alpha", from_entity_id = 1, to_entity_id = 2,
            cardinality = "MANY_TO_ONE"},
        {id = 3, name = "alpha_to_beta", from_entity_id = 2, to_entity_id = 3,
            cardinality = "MANY_TO_ONE"},
    }
    local safe = graph.build_edges(relationships)

    local selection = graph.prove_path(safe, 1, 3, {
        require_safe = true,
        reject_ambiguous = true,
    })
    assert_true(selection.ok)
    assert_true(not selection.ambiguous)
    assert_equal(selection.path, "fact_to_beta")

    local alternatives = graph.safe_path_alternatives(safe, 1, 3)
    assert_equal(alternatives.selected.path, "fact_to_beta")
    assert_equal(alternatives.selected.length, 1)
    assert_equal(#alternatives.alternates, 1)
    assert_equal(alternatives.alternates[1].path, "fact_to_alpha > alpha_to_beta")
    assert_equal(alternatives.alternates[1].length, 2)
    assert_true(not alternatives.truncated)
    assert_branch("grain_graph.safe_path_alternative_exists",
        #alternatives.alternates > 0, true)

    -- The selected path must be the one prove_path returns, or a caller would
    -- report a choice the compiler did not make.
    assert_equal(alternatives.selected.path, selection.path)

    -- One path only: nothing to report.
    local single = graph.safe_path_alternatives(safe, 2, 3)
    assert_equal(single.selected.path, "alpha_to_beta")
    assert_equal(#single.alternates, 0)
    assert_branch("grain_graph.safe_path_alternative_exists",
        #single.alternates > 0, false)

    -- Unreachable target: no selection, and no alternatives to claim.
    local absent = graph.safe_path_alternatives(safe, 3, 1)
    assert_equal(absent.selected, nil)
    assert_equal(#absent.alternates, 0)
end)

test("path enumeration caps report truncation instead of a false negative", function()
    local relationships = {
        {id = 1, name = "fact_to_beta", from_entity_id = 1, to_entity_id = 3,
            cardinality = "MANY_TO_ONE"},
        {id = 2, name = "fact_to_alpha", from_entity_id = 1, to_entity_id = 2,
            cardinality = "MANY_TO_ONE"},
        {id = 3, name = "alpha_to_beta", from_entity_id = 2, to_entity_id = 3,
            cardinality = "MANY_TO_ONE"},
    }
    local safe = graph.build_edges(relationships)

    -- Candidate cap: the walk keeps the shortest path and reports that it
    -- stopped, so "no alternative" cannot be read out of a capped search.
    local capped = graph.safe_path_alternatives(safe, 1, 3, {max_candidates = 1})
    assert_equal(capped.selected.path, "fact_to_beta")
    assert_equal(#capped.alternates, 0)
    assert_true(capped.truncated)

    -- Visit cap: the same, bounded by work done rather than results kept.
    local visit_capped = graph.prove_path(safe, 1, 3, {
        require_safe = true,
        reject_any_ambiguity = true,
        max_visits = 1,
    })
    assert_true(visit_capped.truncated)

    -- Depth cap keeps the shortest path and drops the longer one entirely.
    local shallow = graph.safe_path_alternatives(safe, 1, 3, {max_depth = 1})
    assert_equal(shallow.selected.path, "fact_to_beta")
    assert_equal(#shallow.alternates, 0)
end)
