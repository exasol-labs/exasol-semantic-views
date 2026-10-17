# Shared script parameters

Each file in this directory is the body of one `SEMANTIC_ADMIN` script, opened
by an annotation block the build turns into its `CREATE SCRIPT` statement and
into `SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS`:

```lua
--- Adds a fact: a numeric column of an entity that metrics aggregate.
-- @script SEMANTIC_ADMIN.ADD_FACT
-- @param MODEL_NAME
-- @param FACT_NAME New fact name, unique on the entity.
-- @returns TABLE
```

| Tag | Meaning |
|---|---|
| `--- <summary>` | first line: what the script does and returns |
| `@script SEMANTIC_ADMIN.<NAME>` | the script; must match the file name |
| `@kind scalar` / `@kind preprocessor` | a Lua UDF or the preprocessor; omit for a scripting script |
| `@param NAME [description]` | one per parameter, in call order |
| `@returns TABLE` / `ROWCOUNT` / `nothing` / a type | the `RETURNS` clause, or none; a scalar gives its type |

A parameter that means the same thing in every script is described once, here,
and a bare `@param NAME` takes this description. A description written on the
`@param` line wins, so a script whose parameter means something more specific
says so where it is used. The build fails on a parameter with no description, on
a row here that no script uses, and on a declared parameter the body never reads.

| Parameter | Description |
|---|---|
| `MODEL_NAME` | Name of the semantic model the script acts on. |
| `IS_CERTIFIED` | Marks it certified: TRUE, 'true' or '1' (any case) mean true; NULL or anything else means false. |
| `IS_PRIVATE` | Marks it private: TRUE, 'true' or '1' (any case) mean true; NULL or anything else means false. |
| `SOURCE_KIND` | RELATION or VIRTUAL_SCHEMA, matching what SOURCE_SCHEMA is; NULL defaults to RELATION. |
