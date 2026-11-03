--- Always raises SEMANTIC_SURFACE_015: the view reading it was compiled from an earlier definition of its semantic model and has been retired.
-- @script SEMANTIC_ADMIN.FROZEN_VIEW_GUARD
-- @kind scalar
-- @returns VARCHAR(2000000)

-- SYNC_FROZEN_VIEWS puts this in place of a frozen view's SQL once that SQL no
-- longer matches what the model compiles. A scalar script takes no parameters
-- here, so the message cannot name the view; the caller just read it, and the
-- retired view's comment names the model and the object it froze.
function run(ctx)
    error("SEMANTIC_SURFACE_015: this view was compiled from an earlier definition of its"
        .. " semantic model, which has since changed, so it no longer answers. Its comment"
        .. " names the model; EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS('<model>')"
        .. " says what changed. Re-create the view over the semantic object to answer with"
        .. " the current definition.", 0)
end
