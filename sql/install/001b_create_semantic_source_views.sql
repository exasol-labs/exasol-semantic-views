-- SEMANTIC_SOURCE — the catalog, as the calling principal may see it.
--
-- Why this schema exists. The compiler runs as the caller: an Exasol scripting
-- script has the caller's rights, not the script owner's. So for a non-SYS
-- principal to compile anything at all, it needed SELECT on SYS_SEMANTIC — and
-- that is the whole catalog. Verified as a restricted analyst holding a grant on
-- exactly one model: every other model's metric definitions, every other user's
-- logged requests, and a map of the physical estate. A read surface that wide
-- cannot be narrowed by the compiler, because the caller can simply query the
-- tables without it.
--
-- So the surface itself is narrowed. SEMANTIC_SOURCE is one thin view per
-- SYS_SEMANTIC table the compiler reads, filtered to the models the caller is
-- authorized for. Callers are granted SELECT here and nowhere in SYS_SEMANTIC,
-- and a view is owner-rights, so the filter is enforced by the database rather
-- than by the compiler agreeing to apply it.
--
-- Thin is a contract, not a preference. SEMANTIC_CATALOG already has a view per
-- table, but those are denormalized for people — three to five joins each — and
-- load_catalog runs seventeen statements on a cold compile. These carry the
-- authorization filter and nothing else.
--
-- The generated block below is derived from the compiler's own Lua: every
-- `SEMANTIC_SOURCE.<TABLE>` it reads gets a view, so a new catalog read either
-- has one or fails the build. Regenerate with tools/package_lua_scripts.py.

-- Who the caller is, resolved once and read by everything that needs it.
--
-- ESV used to match principals as `IN (CURRENT_USER, 'PUBLIC')`, which misses
-- every inherited role: a user granted REGIONAL_ANALYST, which itself holds
-- SEMANTIC_READER, was not a SEMANTIC_READER as far as ESV was concerned.
-- Exasol answers this properly in EXA_SESSION_ROLES, which reports the
-- transitive closure; ESV simply did not ask.
CREATE OR REPLACE VIEW SEMANTIC_SOURCE.EFFECTIVE_PRINCIPAL AS
SELECT UPPER(CURRENT_USER) AS PRINCIPAL_NAME, 'USER' AS PRINCIPAL_KIND FROM DUAL
UNION ALL
SELECT UPPER(ROLE_NAME), 'ROLE' FROM EXA_SESSION_ROLES
UNION ALL
SELECT 'PUBLIC', 'PUBLIC' FROM DUAL;

-- Which models that principal may read.
--
-- Authorization is opt-in per model, and that is a deliberate default rather
-- than an oversight: a model nobody has granted stays visible to everyone, which
-- is exactly the behaviour every existing installation has today, so upgrading
-- changes nothing until someone calls GRANT_MODEL_ROLE. Granting the first role
-- is what turns the model private. The cost of that choice is worth stating
-- plainly: a newly created model is not private by default.
CREATE OR REPLACE VIEW SEMANTIC_SOURCE.AUTHORIZED_MODELS AS
SELECT m.MODEL_ID, m.MODEL_NAME, m.ACTIVE_VERSION_ID
FROM SYS_SEMANTIC.MODELS m
WHERE NOT EXISTS (
        SELECT 1 FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS g
        WHERE g.MODEL_ID = m.MODEL_ID AND g.STATUS = 'ACTIVE')
   OR EXISTS (
        SELECT 1 FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS g
        JOIN SEMANTIC_SOURCE.EFFECTIVE_PRINCIPAL p
          ON p.PRINCIPAL_NAME = UPPER(g.ROLE_NAME)
        WHERE g.MODEL_ID = m.MODEL_ID AND g.STATUS = 'ACTIVE')
   OR EXISTS (
        SELECT 1 FROM SEMANTIC_SOURCE.EFFECTIVE_PRINCIPAL p
        WHERE p.PRINCIPAL_NAME = UPPER(m.OWNER_ROLE))
   OR EXISTS (
        SELECT 1 FROM SEMANTIC_SOURCE.EFFECTIVE_PRINCIPAL p
        WHERE p.PRINCIPAL_NAME = 'DBA');

-- The baseline a caller needs, named once so a deployment does not have to
-- discover it by trial and error.
--
-- Note what is and is not in here. SELECT on SEMANTIC_SOURCE and EXECUTE on
-- SEMANTIC_ADMIN are the read and call surface. The three SYS_SEMANTIC tables
-- are the ones the compiler *writes* as the caller -- the compile cache and the
-- two logs -- and granting write on them is a real exposure, not a tidy-up: it
-- is what makes cache poisoning possible at all, which is why a cached
-- statement is checked against the model's declared relations before it is
-- served. Taking that write surface away from callers is its own piece of work;
-- until then this role states the exposure instead of hiding it.
--
-- Not included, deliberately: SELECT on the physical source schemas. Those are
-- the deployment's own data and the deployment's own grant to make -- and it is
-- where row-level security actually lives, so ESV handing it out would be ESV
-- deciding who sees which rows.
-- The role itself is created by tools/install.py: Exasol has no
-- `CREATE ROLE IF NOT EXISTS`, and this file re-runs on every install.
GRANT SELECT ON SCHEMA SEMANTIC_SOURCE TO SEMANTIC_USER;
GRANT SELECT ON SCHEMA SEMANTIC_CATALOG TO SEMANTIC_USER;
GRANT SELECT ON SCHEMA SEMANTIC_AGENT TO SEMANTIC_USER;
GRANT EXECUTE ON SCHEMA SEMANTIC_ADMIN TO SEMANTIC_USER;
GRANT SELECT, INSERT, UPDATE, DELETE ON SYS_SEMANTIC.COMPILE_CACHE TO SEMANTIC_USER;
-- INSERT but not SELECT on the two logs. The compiler reads back only the row
-- it just wrote, and both reads already said WHERE USER_NAME = CURRENT_USER, so
-- the grant was simply wider than the need: SELECT here would have handed every
-- caller every other caller's logged questions.
GRANT INSERT ON SYS_SEMANTIC.AGENT_REQUEST_LOG TO SEMANTIC_USER;
GRANT INSERT ON SYS_SEMANTIC.QUERY_LOG TO SEMANTIC_USER;

-- A caller's own log rows, and only its own. These are scoped by user rather
-- than by model: a logged request belongs to whoever asked it.
CREATE OR REPLACE VIEW SEMANTIC_SOURCE.MY_AGENT_REQUESTS AS
SELECT * FROM SYS_SEMANTIC.AGENT_REQUEST_LOG WHERE USER_NAME = CURRENT_USER;

CREATE OR REPLACE VIEW SEMANTIC_SOURCE.MY_QUERY_LOG AS
SELECT * FROM SYS_SEMANTIC.QUERY_LOG WHERE USER_NAME = CURRENT_USER;

-- The settings in force for the caller's session: the deployment's, and the
-- session's own override.
CREATE OR REPLACE VIEW SEMANTIC_SOURCE.MY_SETTINGS AS
SELECT * FROM SYS_SEMANTIC.SETTINGS WHERE SESSION_ID IS NULL OR SESSION_ID = CURRENT_SESSION;

-- @generated SEMANTIC_SOURCE_VIEWS








-- SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL is created here, not with the other
-- catalog views in 002, because it reads SEMANTIC_SOURCE.AUTHORIZED_MODELS and
-- 002 runs before this file exists. Putting it in 002 installed fine over an
-- existing deployment and failed on every clean install, which is the kind of
-- ordering fault only a full reset finds.
--
-- What this model promises, what it can vouch for, and where it stops.
--
-- One row per model, and one surface rather than two: the governance state and
-- the capability state are the same question asked twice -- "can I rely on this
-- number" -- and answering them in separate views would let them disagree.
-- Everything here is derived from what the other surfaces already hold, so
-- nothing is declared twice.
--
-- SUMMARY is the sentence. An operator who reads nothing else should still learn
-- whether the model is enforcing anything, whether anything is unvouched for,
-- and whether a frozen view is carrying an old answer.
-- Which SQL shapes this layer accepts, and what it says when it does not.
--
-- A tool integrator should not discover the boundary by hitting it. This is the
-- companion to GOVERNANCE_FOR_MODEL below and deliberately the same kind of
-- answer: that view says what the layer vouches for, this one says what it
-- accepts, and between them "can I rely on this number" has one place to go.
--
-- Declared rather than derived, because there is nothing to derive it from --
-- the shapes live in a parser. The refusal codes are the check: each one is a
-- code the compiler actually emits, and tests/unit/test_conventions.py already
-- forbids a code from meaning two things, so a row naming a code that has gone
-- away is visible.
CREATE OR REPLACE VIEW SEMANTIC_CATALOG.QUERY_CAPABILITIES AS
SELECT * FROM (VALUES
  ('SELECT over a published object', 'SUPPORTED',
   'Semantic field names, SELECT *, and MEASURE(metric) / agg(metric).', NULL, NULL),
  ('WHERE on dimensions', 'SUPPORTED',
   '=, !=, <>, <, <=, >, >=, LIKE, IN, BETWEEN, IS NULL, IS NOT NULL. Text comparisons are case-insensitive.', NULL, NULL),
  ('HAVING on metrics', 'SUPPORTED',
   'A metric predicate written in WHERE is routed to HAVING during parsing. HAVING without a metric to group by is refused.', 'SEMANTIC_QUERY_026', NULL),
  ('GROUP BY', 'SUPPORTED',
   'Optional. Inferred from the selected dimensions when omitted; an explicit list must cover them exactly.', 'SEMANTIC_QUERY_008', NULL),
  ('ORDER BY and LIMIT', 'SUPPORTED',
   'Selected output fields, output aliases, or ordinals, each with ASC/DESC and NULLS FIRST/LAST. An ordinal outside the select list is refused with SEMANTIC_QUERY_064. LIMIT 0 returns the shape with no rows.', NULL, NULL),
  ('ORDER BY a field that is not selected', 'SUPPORTED',
   'Also OFFSET, SELECT DISTINCT, arithmetic and CASE in the select list, IN (subquery) and correlated EXISTS on a selected dimension.', NULL, NULL),
  ('Catalog-qualified names', 'SUPPORTED',
   'EXA_DB.<schema>.<object>, as Power BI writes every relation, is the same reference as <schema>.<object>. EXA_DB is the only catalog Exasol has; any other is left for Exasol to report as not found.', NULL, NULL),
  ('Statements that wrap the object', 'SUPPORTED',
   'Subquery, CTE, union, window, TopN wrapper, CAST, arithmetic and COUNT(*) around a reference, by expanding the reference into a derived table.', NULL, NULL),
  ('The shape of the statement around the object', 'DOES NOT MATTER',
   'A construct is accepted or refused the same way whether the object is referenced bare or wrapped in a subquery. Wrapping a statement is never a workaround for a refusal.', NULL, NULL),
  ('CREATE VIEW over an object', 'SUPPORTED',
   'The stored text is compiled SQL, so the view answers with no preprocessor. Recorded in SEMANTIC_CATALOG.FROZEN_VIEWS and checked by CHECK_FROZEN_VIEWS.', NULL, NULL),
  ('Joining an object to another relation', 'REFUSED BY DEFAULT',
   'The join can repeat the semantic result''s rows and re-aggregation then double-counts. Opt in per model with SET_MODEL_DERIVED_COMPOSITION.', 'SEMANTIC_QUERY_012', NULL),
  ('A wrapped block that aggregates the object', 'SUPPORTED',
   'A derived table or CTE that is itself a semantic query over one object -- GROUP BY, HAVING, or an aggregate over its fields, as Power BI DirectQuery sends for table visuals, Top N and filters -- is compiled as that query, at the grain it names, and the result replaces the block. Everything outside it stays ordinary SQL. The aggregate and grouping checks are the ones a bare statement gets.', NULL, NULL),
  ('Grouping the object where the layer cannot read the statement', 'REFUSED BY DEFAULT',
   'The object is already aggregated to the grain its fields imply, so GROUP BY or HAVING beside the reference groups a grouped result. A wrapped block that is a semantic query on its own is compiled as one; this remains for a grouped block that cannot be, such as one that also reads another semantic object. Where the statement is one the whole-statement path reads, it says something sharper. Opt in with SET_MODEL_DERIVED_COMPOSITION.', 'SEMANTIC_QUERY_015', NULL),
  ('Selecting a field the model withholds', 'REFUSED',
   'IS_PRIVATE on a metric or IS_HIDDEN on a dimension removes the field from discovery and from queries, filters included.', 'SEMANTIC_QUERY_027', 'SEMANTIC_REQUEST_027'),
  ('Selecting a masked field', 'REFUSED',
   'DISPLAY_POLICY = ''MASK'' withholds the value from results. Filtering on it still works.', 'SEMANTIC_QUERY_024', 'SEMANTIC_REQUEST_024'),
  ('Naming a field the object does not publish', 'REFUSED',
   'The refusal names the field and, where one is close enough to suggest, what it might have meant.', 'SEMANTIC_QUERY_020', 'SEMANTIC_REQUEST_020'),
  ('Filtering on a dimension the statement does not select', 'SUPPORTED',
   'The filter is applied before aggregation, as it is on a bare statement, however the object is wrapped. Where it cannot be -- it contains a subquery the compile does not support, reads another semantic object, or sits beside a join -- the statement is refused rather than grouped by the filtered dimension. Filter with literal values, or select the dimension.', 'SEMANTIC_QUERY_017', NULL),
  ('An outer SUM or AVG over a metric that does not add up', 'REFUSED',
   'Aggregating the object in an outer block is supported. For a metric that does not add up across groups -- an average, a ratio, a distinct count -- a sum or average of its per-group values is not the metric at any grain, so it is refused unless the outer block groups by every dimension the subquery is compiled at. MIN, MAX and COUNT are accepted. Opt in with SET_MODEL_DERIVED_COMPOSITION.', 'SEMANTIC_QUERY_016', NULL),
  ('An aggregate the metric does not declare', 'REFUSED',
   'MEASURE() and agg() may only wrap a metric, and a named aggregate only with the aggregate that metric declares. The exception is MIN, MAX, SUM or AVG where each group holds one row of the object: the aggregate of one value is that value, so they select the metric''s value (Tableau ATTR, Power BI''s SUM), and the plan records the lowering. COUNT is always refused.', 'SEMANTIC_QUERY_007', NULL),
  ('An aggregate of a metric where a group holds several rows', 'REFUSED',
   'MIN, MAX, SUM and AVG around a metric that declares another aggregation are accepted only where each group of the statement is one row of the object. Where the grouping does not cover every dimension the object is compiled at, they would combine several values instead of selecting the metric, so they are refused.', 'SEMANTIC_QUERY_018', NULL),
  ('A SELECT list that names no field', 'REFUSED',
   'SELECT supports semantic field names, MEASURE(metric), or *.', 'SEMANTIC_QUERY_005', NULL),
  ('A wrapper naming no column of the object', 'REFUSED',
   'Which columns to compile cannot be inferred, and defaulting to all of them would change the grain silently.', 'SEMANTIC_QUERY_011', NULL),
  ('COUNT(*) over a semantic object', 'REFUSED',
   'With no dimension selected its answer depends on a grain the caller never named. Wrap the object in a subquery and count that. Beside a selected dimension each group is one row, so COUNT(*) or COUNT(1) returns 1 (Power BI''s filter domain).', 'SEMANTIC_QUERY_010', NULL),
  ('Reading a relation the model does not vouch for', 'REFUSED',
   'In GOVERNED mode every representation must resolve through a relation that can carry row and column policy.', 'SEMANTIC_QUERY_028', 'SEMANTIC_REQUEST_028'),
  ('Malformed or non-Exasol SQL around the object', 'REPORTED BY THE DATABASE',
   'A statement the layer rewrote but Exasol then rejects -- a syntax error, DISTINCT ON, LIMIT -1 -- comes back with Exasol''s own message naming the problem, not a rule code. The line it reports is a line of your statement; the column counts the rewritten text, so read the line and ignore the column.', NULL, NULL)
) AS t (SHAPE, SUPPORT, DETAIL, SQL_REFUSAL_CODE, REQUEST_REFUSAL_CODE);

CREATE OR REPLACE VIEW SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL AS
WITH trust AS (
  SELECT MODEL_ID,
         COUNT(CASE WHEN TRUST_CLASS = 'GOVERNED' THEN 1 END) AS GOVERNED_SOURCES,
         COUNT(CASE WHEN TRUST_CLASS = 'RAW' THEN 1 END) AS RAW_SOURCES,
         COUNT(CASE WHEN TRUST_CLASS = 'DIVERGENT' THEN 1 END) AS DIVERGENT_SOURCES,
         COUNT(CASE WHEN TRUST_CLASS = 'UNKNOWN' THEN 1 END) AS UNKNOWN_SOURCES,
         MAX(DERIVED_AT) AS TRUST_DERIVED_AT
    FROM SYS_SEMANTIC.SOURCE_TRUST
   GROUP BY MODEL_ID
),
frozen AS (
  SELECT fv.MODEL_ID, COUNT(*) AS FROZEN_VIEWS
    FROM SYS_SEMANTIC.FROZEN_VIEWS fv
    JOIN SYS.EXA_ALL_VIEWS v
      ON UPPER(v.VIEW_SCHEMA) = UPPER(fv.VIEW_SCHEMA)
     AND UPPER(v.VIEW_NAME) = UPPER(fv.VIEW_NAME)
   GROUP BY fv.MODEL_ID
)
SELECT
  m.MODEL_NAME,
  m.GOVERNANCE_MODE,
  m.ALLOW_DERIVED_COMPOSITION,
  CASE WHEN a.MODEL_ID IS NULL THEN FALSE ELSE TRUE END AS VISIBLE_TO_CALLER,
  COALESCE(t.GOVERNED_SOURCES, 0) AS GOVERNED_SOURCES,
  COALESCE(t.RAW_SOURCES, 0) AS RAW_SOURCES,
  COALESCE(t.DIVERGENT_SOURCES, 0) AS DIVERGENT_SOURCES,
  COALESCE(t.UNKNOWN_SOURCES, 0) AS UNKNOWN_SOURCES,
  COALESCE(f.FROZEN_VIEWS, 0) AS FROZEN_VIEWS,
  t.TRUST_DERIVED_AT,
  CASE
    WHEN t.MODEL_ID IS NULL THEN
      'Not classified. VALIDATE_MODEL derives which sources this model can vouch'
      || ' for, and has not run since the last change that could affect them.'
    WHEN UPPER(m.GOVERNANCE_MODE) = 'GOVERNED' THEN
      'Governed: every representation must resolve through a view that can carry'
      || ' row and column policy, and ' || COALESCE(t.GOVERNED_SOURCES, 0)
      || ' of ' || (COALESCE(t.GOVERNED_SOURCES,0) + COALESCE(t.RAW_SOURCES,0)
                    + COALESCE(t.DIVERGENT_SOURCES,0) + COALESCE(t.UNKNOWN_SOURCES,0))
      || ' sources do. '
      || CASE WHEN COALESCE(t.DIVERGENT_SOURCES,0) + COALESCE(t.UNKNOWN_SOURCES,0) > 0
              THEN 'It will refuse to compile or to freeze a view until the '
                   || (COALESCE(t.DIVERGENT_SOURCES,0) + COALESCE(t.UNKNOWN_SOURCES,0))
                   || ' it cannot vouch for are rebuilt or retired.'
              ELSE 'Nothing is unvouched for.' END
    ELSE
      'Open: the layer reports on its sources but enforces nothing about them. '
      || COALESCE(t.RAW_SOURCES, 0) || ' read base tables directly'
      || CASE WHEN COALESCE(t.DIVERGENT_SOURCES,0) > 0
              THEN ' and ' || t.DIVERGENT_SOURCES
                   || ' substitute for a representation without carrying its policy'
              ELSE '' END
      || '. Row and column policy has to live in the sources themselves.'
  END
  || CASE WHEN COALESCE(f.FROZEN_VIEWS, 0) > 0
          THEN ' ' || f.FROZEN_VIEWS || ' database view(s) hold SQL compiled from this'
               || ' model and keep answering with it; CHECK_FROZEN_VIEWS says whether'
               || ' they still match.'
          ELSE '' END
  || CASE WHEN m.ALLOW_DERIVED_COMPOSITION
          THEN ' Composition is allowed: a published object may be joined to another'
               || ' relation, which the layer does not supervise.'
          ELSE '' END AS SUMMARY
FROM SYS_SEMANTIC.MODELS m
LEFT JOIN trust t ON t.MODEL_ID = m.MODEL_ID
LEFT JOIN frozen f ON f.MODEL_ID = m.MODEL_ID
LEFT JOIN SEMANTIC_SOURCE.AUTHORIZED_MODELS a ON a.MODEL_ID = m.MODEL_ID;

-- What each field computes, as a hash a consumer can store and compare.
--
-- A model has one version that authoring mutates in place, so VERSION_ID and
-- VERSION_NUMBER never move, and LATEST_VALIDATION_RUN_ID moves on a no-op
-- validation. A dashboard therefore could not record which definition it was
-- built against, or notice that it had changed: rolling one back silently
-- restored a pre-fix number with every check green. This is that record.
--
-- Derived from the catalog on every read, never stored, so it cannot lag
-- authoring. FIELDS_FOR_AGENT, MODELS_FOR_AGENT and the compiler's PLAN_JSON
-- all read these two views, so the three can never disagree.
--
-- They read SYS_SEMANTIC, as GOVERNANCE_FOR_MODEL does, and filter the result
-- to AUTHORIZED_MODELS once at the end. Reading through SEMANTIC_SOURCE applied
-- the authorization filter in every one of some twenty references and tripled
-- the cost. Nothing leaks: every join stays inside one model, and only an
-- authorized model's rows come out.
--
-- What a field hash covers is what the field computes, not what it is called
-- or how it is shown:
--
-- * a dimension or fact: its expression and type, its bindings and fusion
--   policy, and its entity -- representations, coverage, authority, unique
--   keys and identity bindings;
-- * a metric: its own definition, filters and inputs, its base entity, and the
--   hash of everything it is built from, transitively, so changing a fact's
--   expression changes every metric over it;
-- * every field: the model's relationship graph. That over-reports a graph
--   edit, which is rare, and never misses one.
--
-- Its own name, display name, description, format, unit and certification are
-- left out: a rename keeps the hash, so a consumer can tell "renamed" from
-- "redefined". The model hash adds the names, which object exposes which field,
-- and synonyms. Materializations are left out of both: substituting one is
-- proven not to change the answer.
--
-- Rows are hashed as tuples with multi-argument HASH_SHA256, which separates
-- its arguments and distinguishes NULL; sets are hashed in hash order, so they
-- do not depend on ids or insertion order. The leading 'esv-definition-1' names
-- the recipe: changing what is covered changes it, and every hash with it.
CREATE OR REPLACE VIEW SEMANTIC_CATALOG.FIELD_DEFINITION_HASHES AS
WITH
key_columns AS (
  SELECT UNIQUE_KEY_ID,
         GROUP_CONCAT(HASH_SHA256('key_column', TO_CHAR(ORDINAL_POSITION), COLUMN_NAME, EXPRESSION)
                      ORDER BY ORDINAL_POSITION SEPARATOR ',') AS COLUMNS_HASHES
    FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
   GROUP BY UNIQUE_KEY_ID
),
entity_parts AS (
  SELECT r.ENTITY_ID,
         HASH_SHA256('representation', r.REPRESENTATION_NAME, r.SOURCE_KIND, r.SOURCE_SCHEMA,
                     r.SOURCE_OBJECT, r.SOURCE_ALIAS, r.REPRESENTATION_ROLE, TO_CHAR(r.PRIORITY),
                     r.FRESHNESS_POLICY, r.COVERAGE_PREDICATE,
                     TO_CHAR(r.VALID_FROM, 'YYYY-MM-DD HH24:MI:SS.FF6'),
                     TO_CHAR(r.VALID_TO, 'YYYY-MM-DD HH24:MI:SS.FF6'), a.AUTHORITY_ROLE) AS PART_HASH
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
    LEFT JOIN SYS_SEMANTIC.REPRESENTATION_AUTHORITIES a
      ON a.REPRESENTATION_ID = r.REPRESENTATION_ID AND a.STATUS = 'ACTIVE'
   WHERE r.STATUS = 'ACTIVE'
  UNION ALL
  SELECT k.ENTITY_ID,
         HASH_SHA256('unique_key', k.KEY_NAME, k.KEY_KIND, c.COLUMNS_HASHES)
    FROM SYS_SEMANTIC.UNIQUE_KEYS k
    LEFT JOIN key_columns c ON c.UNIQUE_KEY_ID = k.UNIQUE_KEY_ID
   WHERE k.STATUS = 'ACTIVE'
  UNION ALL
  SELECT b.ENTITY_ID,
         HASH_SHA256('identity_binding', i.IDENTITY_NAME, i.IDENTITY_KIND, i.DATA_TYPE,
                     r.REPRESENTATION_NAME, b.SOURCE_EXPRESSION, b.BINDING_KIND,
                     m.SOURCE_SCHEMA, m.SOURCE_OBJECT, m.SOURCE_LOCAL_COLUMN,
                     m.SEMANTIC_KEY_COLUMN, m.CERTIFICATION_STATUS)
    FROM SYS_SEMANTIC.IDENTITY_BINDINGS b
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES i ON i.IDENTITY_ID = b.IDENTITY_ID
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r ON r.REPRESENTATION_ID = b.REPRESENTATION_ID
    LEFT JOIN SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS m
      ON m.IDENTITY_BINDING_ID = b.IDENTITY_BINDING_ID AND m.STATUS = 'ACTIVE'
   WHERE b.STATUS = 'ACTIVE' AND i.STATUS = 'ACTIVE'
),
entity_hashes AS (
  SELECT e.ENTITY_ID, e.ENTITY_NAME,
         HASH_SHA256('entity', e.PRIMARY_KEY_EXPR,
                     GROUP_CONCAT(p.PART_HASH ORDER BY p.PART_HASH SEPARATOR ',')) AS ENTITY_HASH
    FROM SYS_SEMANTIC.ENTITIES e
    LEFT JOIN entity_parts p ON p.ENTITY_ID = e.ENTITY_ID
   WHERE e.STATUS = 'ACTIVE'
   GROUP BY e.ENTITY_ID, e.ENTITY_NAME, e.PRIMARY_KEY_EXPR
),
key_mappings AS (
  SELECT RELATIONSHIP_ID,
         GROUP_CONCAT(HASH_SHA256('key_mapping', TO_CHAR(ORDINAL_POSITION), FROM_COLUMN_NAME,
                                  FROM_EXPRESSION, TO_COLUMN_NAME, TO_EXPRESSION)
                      ORDER BY ORDINAL_POSITION SEPARATOR ',') AS MAPPING_HASHES
    FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
   GROUP BY RELATIONSHIP_ID
),
relationship_rows AS (
  SELECT r.VERSION_ID,
         HASH_SHA256('relationship', r.RELATIONSHIP_NAME, fe.ENTITY_NAME, te.ENTITY_NAME,
                     r.JOIN_CONDITION, r.RELATIONSHIP_CARDINALITY, r.JOIN_TYPE,
                     CASE WHEN r.IS_REQUIRED THEN 'Y' ELSE 'N' END, r.FANOUT_POLICY,
                     TO_CHAR(r.PATH_PRIORITY), km.MAPPING_HASHES) AS ROW_HASH
    FROM SYS_SEMANTIC.RELATIONSHIPS r
    LEFT JOIN SYS_SEMANTIC.ENTITIES fe ON fe.ENTITY_ID = r.FROM_ENTITY_ID
    LEFT JOIN SYS_SEMANTIC.ENTITIES te ON te.ENTITY_ID = r.TO_ENTITY_ID
    LEFT JOIN key_mappings km ON km.RELATIONSHIP_ID = r.RELATIONSHIP_ID
   WHERE r.STATUS = 'ACTIVE'
),
graph_hashes AS (
  SELECT v.MODEL_ID, v.VERSION_ID,
         HASH_SHA256('graph', GROUP_CONCAT(rr.ROW_HASH ORDER BY rr.ROW_HASH SEPARATOR ','))
           AS GRAPH_HASH
    FROM SYS_SEMANTIC.MODEL_VERSIONS v
    LEFT JOIN relationship_rows rr ON rr.VERSION_ID = v.VERSION_ID
   GROUP BY v.MODEL_ID, v.VERSION_ID
),
binding_rows AS (
  SELECT b.ATTRIBUTE_TYPE, b.ATTRIBUTE_ID,
         HASH_SHA256('binding', r.REPRESENTATION_NAME, b.SOURCE_EXPRESSION, b.BINDING_ROLE,
                     TO_CHAR(b.BINDING_PRIORITY),
                     CASE WHEN b.IS_DEFAULT THEN 'Y' ELSE 'N' END) AS ROW_HASH
    FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS b
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r ON r.REPRESENTATION_ID = b.REPRESENTATION_ID
   WHERE b.STATUS = 'ACTIVE'
),
bindings AS (
  SELECT ATTRIBUTE_TYPE, ATTRIBUTE_ID,
         GROUP_CONCAT(ROW_HASH ORDER BY ROW_HASH SEPARATOR ',') AS BINDING_HASHES
    FROM binding_rows
   GROUP BY ATTRIBUTE_TYPE, ATTRIBUTE_ID
),
attributes AS (
  SELECT 'DIMENSION' AS FIELD_KIND, d.DIMENSION_ID AS FIELD_ID, d.MODEL_ID, d.VERSION_ID,
         d.DIMENSION_NAME AS FIELD_NAME,
         HASH_SHA256('dimension', eh.ENTITY_NAME, eh.ENTITY_HASH, d.EXPRESSION, d.DATA_TYPE,
                     b.BINDING_HASHES, fp.FUSION_STRATEGY, g.GRAPH_HASH) AS OWN_HASH
    FROM SYS_SEMANTIC.DIMENSIONS d
    JOIN entity_hashes eh ON eh.ENTITY_ID = d.ENTITY_ID
    JOIN graph_hashes g ON g.VERSION_ID = d.VERSION_ID
    LEFT JOIN bindings b ON b.ATTRIBUTE_TYPE = 'DIMENSION' AND b.ATTRIBUTE_ID = d.DIMENSION_ID
    LEFT JOIN SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES fp
      ON fp.ATTRIBUTE_TYPE = 'DIMENSION' AND fp.ATTRIBUTE_ID = d.DIMENSION_ID
     AND fp.STATUS = 'ACTIVE'
   WHERE d.STATUS = 'ACTIVE'
  UNION ALL
  SELECT 'FACT', f.FACT_ID, f.MODEL_ID, f.VERSION_ID, f.FACT_NAME,
         HASH_SHA256('fact', eh.ENTITY_NAME, eh.ENTITY_HASH, f.EXPRESSION, f.DATA_TYPE,
                     f.ADDITIVE_POLICY, b.BINDING_HASHES, fp.FUSION_STRATEGY, g.GRAPH_HASH)
    FROM SYS_SEMANTIC.FACTS f
    JOIN entity_hashes eh ON eh.ENTITY_ID = f.ENTITY_ID
    JOIN graph_hashes g ON g.VERSION_ID = f.VERSION_ID
    LEFT JOIN bindings b ON b.ATTRIBUTE_TYPE = 'FACT' AND b.ATTRIBUTE_ID = f.FACT_ID
    LEFT JOIN SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES fp
      ON fp.ATTRIBUTE_TYPE = 'FACT' AND fp.ATTRIBUTE_ID = f.FACT_ID AND fp.STATUS = 'ACTIVE'
   WHERE f.STATUS = 'ACTIVE'
),
metric_part_rows AS (
  SELECT mf.METRIC_ID, 'FILTER' AS PART,
         HASH_SHA256('metric_filter', mf.FILTER_KIND, mf.FILTER_EXPR, mf.RESOLVED_SQL_EXPR,
                     d.DIMENSION_NAME, e.ENTITY_NAME, TO_CHAR(mf.ORDINAL_POSITION)) AS ROW_HASH
    FROM SYS_SEMANTIC.METRIC_FILTERS mf
    LEFT JOIN SYS_SEMANTIC.DIMENSIONS d ON d.DIMENSION_ID = mf.REQUIRED_DIMENSION_ID
    LEFT JOIN SYS_SEMANTIC.ENTITIES e ON e.ENTITY_ID = mf.REQUIRED_ENTITY_ID
  UNION ALL
  SELECT mi.METRIC_ID, 'INPUT',
         HASH_SHA256('metric_input', mi.INPUT_ROLE, mi.INPUT_OBJECT_TYPE,
                     COALESCE(f.FACT_NAME, m.METRIC_NAME), mi.EXPRESSION_ALIAS,
                     mi.OFFSET_WINDOW, mi.FILTER_EXPR, TO_CHAR(mi.ORDINAL_POSITION))
    FROM SYS_SEMANTIC.METRIC_INPUTS mi
    LEFT JOIN SYS_SEMANTIC.FACTS f
      ON mi.INPUT_OBJECT_TYPE = 'FACT' AND f.FACT_ID = mi.INPUT_OBJECT_ID
    LEFT JOIN SYS_SEMANTIC.METRICS m
      ON mi.INPUT_OBJECT_TYPE = 'METRIC' AND m.METRIC_ID = mi.INPUT_OBJECT_ID
),
metric_parts AS (
  SELECT METRIC_ID,
         GROUP_CONCAT(ROW_HASH ORDER BY ROW_HASH SEPARATOR ',') AS PART_HASHES
    FROM metric_part_rows
   GROUP BY METRIC_ID
),
metric_own AS (
  SELECT m.METRIC_ID, m.MODEL_ID, m.VERSION_ID, m.METRIC_NAME,
         HASH_SHA256('metric', m.EXPRESSION, m.FILTER_EXPR, m.METRIC_TYPE, m.METRIC_KIND,
                     m.DATA_TYPE, m.AGGREGATION_FUNCTION, m.MEASURE_EXPR,
                     m.SEMANTIC_FILTER_EXPR, m.SQL_FILTER_EXPR, m.DISTINCT_KEY_EXPR,
                     m.WINDOW_SPEC_JSON, m.TYPE_PARAMS_JSON, nd.DIMENSION_NAME,
                     be.ENTITY_NAME, be.ENTITY_HASH, mp.PART_HASHES, g.GRAPH_HASH) AS OWN_HASH
    FROM SYS_SEMANTIC.METRICS m
    JOIN graph_hashes g ON g.VERSION_ID = m.VERSION_ID
    LEFT JOIN entity_hashes be ON be.ENTITY_ID = m.BASE_ENTITY_ID
    LEFT JOIN SYS_SEMANTIC.DIMENSIONS nd ON nd.DIMENSION_ID = m.NON_ADDITIVE_DIMENSION_ID
    LEFT JOIN metric_parts mp ON mp.METRIC_ID = m.METRIC_ID
   WHERE m.STATUS = 'ACTIVE'
),
-- What a metric is built from: the edges VALIDATE_MODEL derives from its
-- expression, and the inputs the Semantic DDL declares. The compiler reads the
-- same two tables to plan it.
metric_edges AS (
  SELECT METRIC_ID, DEPENDS_ON_OBJECT_TYPE AS OBJECT_TYPE, DEPENDS_ON_OBJECT_ID AS OBJECT_ID
    FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
  UNION
  SELECT METRIC_ID, INPUT_OBJECT_TYPE, INPUT_OBJECT_ID
    FROM SYS_SEMANTIC.METRIC_INPUTS
   WHERE INPUT_OBJECT_ID IS NOT NULL
),
metric_closure AS (
  SELECT CONNECT_BY_ROOT METRIC_ID AS METRIC_ID, OBJECT_TYPE, OBJECT_ID
    FROM metric_edges
 CONNECT BY NOCYCLE PRIOR OBJECT_ID = METRIC_ID AND PRIOR OBJECT_TYPE = 'METRIC'
),
metric_hashes AS (
  SELECT o.METRIC_ID, o.MODEL_ID, o.VERSION_ID, o.METRIC_NAME,
         HASH_SHA256('metric_closure', o.OWN_HASH,
                     GROUP_CONCAT(DISTINCT COALESCE(a.OWN_HASH, dm.OWN_HASH)
                                  ORDER BY COALESCE(a.OWN_HASH, dm.OWN_HASH) SEPARATOR ','))
           AS DEFINITION_HASH
    FROM metric_own o
    LEFT JOIN metric_closure c ON c.METRIC_ID = o.METRIC_ID
    LEFT JOIN attributes a ON a.FIELD_KIND = c.OBJECT_TYPE AND a.FIELD_ID = c.OBJECT_ID
    LEFT JOIN metric_own dm ON c.OBJECT_TYPE = 'METRIC' AND dm.METRIC_ID = c.OBJECT_ID
   GROUP BY o.METRIC_ID, o.MODEL_ID, o.VERSION_ID, o.METRIC_NAME, o.OWN_HASH
)
SELECT MODEL_ID, VERSION_ID, FIELD_KIND, FIELD_ID, FIELD_NAME, DEFINITION_HASH
  FROM (
    SELECT MODEL_ID, VERSION_ID, FIELD_KIND, FIELD_ID, FIELD_NAME,
           HASH_SHA256('esv-definition-1', OWN_HASH) AS DEFINITION_HASH
      FROM attributes
    UNION ALL
    SELECT MODEL_ID, VERSION_ID, 'METRIC', METRIC_ID, METRIC_NAME,
           HASH_SHA256('esv-definition-1', DEFINITION_HASH)
      FROM metric_hashes
  )
 WHERE MODEL_ID IN (SELECT MODEL_ID FROM SEMANTIC_SOURCE.AUTHORIZED_MODELS);

-- The model as a whole: what each semantic object exposes -- its name, root
-- entity, and each column's name, kind, position, visibility and definition
-- hash -- plus synonyms. Unexposed facts and private metrics reach it through
-- the metrics built on them. Any change a consumer could observe in the
-- model's definitions moves it; a validation run, a republish or a
-- presentation edit does not.
--
-- FIELD_DEFINITION_HASHES is read once: Exasol expands a view at every
-- reference, so a second read would compute every field hash twice.
CREATE OR REPLACE VIEW SEMANTIC_CATALOG.MODEL_DEFINITION_HASHES AS
WITH
parts AS (
  SELECT so.VERSION_ID,
         HASH_SHA256('object_column', so.OBJECT_NAME, re.ENTITY_NAME, oc.COLUMN_KIND,
                     oc.COLUMN_NAME, TO_CHAR(oc.ORDINAL_POSITION),
                     CASE WHEN oc.IS_VISIBLE THEN 'Y' ELSE 'N' END, h.FIELD_NAME,
                     h.DEFINITION_HASH) AS PART_HASH
    FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so
    LEFT JOIN SYS_SEMANTIC.ENTITIES re ON re.ENTITY_ID = so.ROOT_ENTITY_ID
    LEFT JOIN SYS_SEMANTIC.OBJECT_COLUMNS oc ON oc.OBJECT_ID = so.OBJECT_ID
    LEFT JOIN SEMANTIC_CATALOG.FIELD_DEFINITION_HASHES h
      ON h.FIELD_KIND = oc.COLUMN_KIND AND h.FIELD_ID = oc.OBJECT_REF_ID
   WHERE so.STATUS = 'ACTIVE'
  UNION ALL
  SELECT s.VERSION_ID,
         HASH_SHA256('synonym', s.OBJECT_TYPE,
                     COALESCE(d.DIMENSION_NAME, mt.METRIC_NAME), s.SYNONYM)
    FROM SYS_SEMANTIC.SYNONYMS s
    LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
      ON s.OBJECT_TYPE = 'DIMENSION' AND d.DIMENSION_ID = s.OBJECT_ID
    LEFT JOIN SYS_SEMANTIC.METRICS mt
      ON s.OBJECT_TYPE = 'METRIC' AND mt.METRIC_ID = s.OBJECT_ID
)
SELECT v.MODEL_ID, v.VERSION_ID,
       HASH_SHA256('esv-definition-1', 'model',
                   GROUP_CONCAT(p.PART_HASH ORDER BY p.PART_HASH SEPARATOR ','))
         AS DEFINITION_HASH
  FROM SYS_SEMANTIC.MODEL_VERSIONS v
  LEFT JOIN parts p ON p.VERSION_ID = v.VERSION_ID
 WHERE v.MODEL_ID IN (SELECT MODEL_ID FROM SEMANTIC_SOURCE.AUTHORIZED_MODELS)
 GROUP BY v.MODEL_ID, v.VERSION_ID;
