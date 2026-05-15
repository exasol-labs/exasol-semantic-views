-- One-time fixup for the live sales model.
-- Corrects order_quarter expression (QUARTER() is not a valid Exasol function) and
-- removes the order_quarter_test artifact that was added during user study testing.
--
-- Run once against a live instance that has the sales model already installed.
-- Safe to skip on clean --reset installs (the seed SQL never included these dimensions).

-- Fix order_quarter: replace QUARTER() with the correct Exasol equivalent.
UPDATE SYS_SEMANTIC.DIMENSIONS
   SET EXPRESSION = 'CEIL(MONTH(o.order_date) / 3.0)'
 WHERE UPPER(DIMENSION_NAME) = 'ORDER_QUARTER';

-- Remove the order_quarter_test artifact added during testing.
DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
 WHERE OBJECT_REF_ID IN (
   SELECT DIMENSION_ID FROM SYS_SEMANTIC.DIMENSIONS
    WHERE UPPER(DIMENSION_NAME) = 'ORDER_QUARTER_TEST'
 );
DELETE FROM SYS_SEMANTIC.DIMENSIONS
 WHERE UPPER(DIMENSION_NAME) = 'ORDER_QUARTER_TEST';

-- Re-run validation to refresh the metric/dimension matrix with the corrected expressions.
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
