ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL;

CREATE OR REPLACE LUA PREPROCESSOR SCRIPT SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR AS
exa.import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")
exa.import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local original_sql = sqlparsing.getsqltext()
local result = semantic_definition.preprocess_sql(original_sql)

if result.status == "UNCHANGED" then
    result = compiler.compile_sql_for_preprocessor(original_sql)
end

if result.status == "UNCHANGED" then
    sqlparsing.setsqltext(original_sql)
elseif result.status == "OK" then
    sqlparsing.setsqltext(result.generated_sql)
else
    error((result.error_code or "SEMANTIC_QUERY_999") .. ": " .. (result.error_message or "Semantic SQL preprocessing failed."), 0)
end
/
