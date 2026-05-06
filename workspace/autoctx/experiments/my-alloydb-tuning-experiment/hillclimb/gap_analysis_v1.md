# Gap Analysis Report - v1

## Summary
- **Total Queries**: 4
- **Passed**: 2
- **Failed**: 2
- **Pass Rate**: 50%

## Failed Queries Detail

### Query 1: "How many accounts who choose issuance after transaction are staying in East Bohemia region? A3 contains the data of region; 'POPLATEK PO OBRATU' represents for 'issuance after transaction'."
- **Error Category**: `ValueLinkingError`, `CountingError`
- **Expected SQL**: `SELECT COUNT(DISTINCT "T1"."account_id") FROM "account" AS "T1" INNER JOIN "district" AS "T2" ON "T1"."district_id" = "T2"."district_id" WHERE "T2"."A3" = 'east Bohemia' AND "T1"."frequency" = 'POPLATEK PO OBRATU'`
- **Actual SQL**: `SELECT COUNT("public"."account"."account_id") FROM "public"."account" JOIN "public"."district" ON "public"."account"."district_id" = "public"."district"."district_id" WHERE "public"."district"."A3" = 'East Bohemia' AND "public"."account"."frequency" = 'POPLATEK PO OBRATU';`
- **Root Cause**:
    1.  Case sensitivity in region name: Golden SQL uses 'east Bohemia' (lowercase 'e'), generated SQL uses 'East Bohemia' (uppercase 'E').
    2.  Counting Distinct Accounts: Golden SQL uses COUNT(DISTINCT "T1"."account_id"), generated SQL uses COUNT("public"."account"."account_id").
- **Proposed Mutation**:
    1.  Add a Value Search for `district.A3` using a case-insensitive match function or a mapping for "East Bohemia". (Note: This is out of scope for the current skill, as it only allows `templates` and `facets` mutations).
    2.  Update the existing template or create a new template to ensure `COUNT(DISTINCT account_id)` is used when the natural language query asks "How many accounts".

### Query 2: "How many accounts who have region in Prague are eligible for loans? A3 contains the data of region"
- **Error Category**: `IntentError`, `LogicError`
- **Expected SQL**: `SELECT COUNT("T1"."account_id") FROM "account" AS "T1" INNER JOIN "loan" AS "T2" ON "T1"."account_id" = "T2"."account_id" INNER JOIN "district" AS "T3" ON "T1"."district_id" = "T3"."district_id" WHERE "T3"."A3" = 'Prague'`
- **Actual SQL**: `SELECT COUNT("account"."account_id") FROM "account" JOIN "district" ON "account"."district_id" = "district"."district_id" WHERE "district"."A3" = 'Prague';`
- **Root Cause**: Generated SQL omitted the INNER JOIN with the 'loan' table, failing to capture the "eligible for loans" intent.
- **Proposed Mutation**: Add a template or facet that correctly interprets "eligible for loans" and includes the necessary join to the `loan` table.