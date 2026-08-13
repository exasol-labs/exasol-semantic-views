# Virtual Schema Sources

This repository does not implement a general-purpose Virtual Schema adapter.
It can, however, model a relation already exposed by an installed Virtual
Schema adapter as an entity representation with `SOURCE_KIND =
'VIRTUAL_SCHEMA'`.

The semantic compiler generates ordinary Exasol SQL over that relation. Source
connectivity, remote dialect conversion, and pushdown remain responsibilities
of the underlying adapter. Validation treats local and Virtual Schema
representations uniformly and requires a bounded session `QUERY_TIMEOUT` before
multi-representation key and identity probes, including views that indirectly
depend on Virtual Schemas.

A future adapter specific to this project would only be justified for dynamic
metadata or pushdown that cannot be expressed through existing relation
representations. It must not replace the SQL preprocessor: metric-column SQL
must be rewritten before normal SQL validation, while a Virtual Schema adapter
receives already valid SQL shapes.

See [Semantic Catalog](semantic-catalog.md#entity-representations) for source
registration and [Architecture](architecture.md#semantic-fusion-path) for the
fusion model.
