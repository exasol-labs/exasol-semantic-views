# Virtual Schema Adapter

The Lua Virtual Schema adapter is optional and belongs after the core
view-plus-preprocessor path is working.

Use it only when it adds value beyond generated metadata views and SQL
preprocessing, such as dynamic metadata, compact `adapterNotes`, or pushdown
participation for already-valid SQL shapes.

It must not replace the preprocessor for metric-column SQL that is invalid
before rewrite.
