# Gap Analysis Report - v1

## Summary
- **Total Queries**: 5
- **Passed**: 3
- **Failed**: 2
- **Pass Rate**: 60%

## Failed Queries Detail

### Query 1: "How many accounts who choose issuance after transaction are staying in East Bohemia region?"
- **Error Category**: `[IntentError, FilterError, EntityError]`
- **Expected SQL**: `SELECT COUNT(DISTINCT "T1"."account_id") FROM "account" AS "T1" INNER JOIN "district" AS "T2" ON "T1"."district_id" = "T2"."district_id" WHERE "T2"."A3" = 'east Bohemia' AND "T1"."frequency" = 'POPLATEK PO OBRATU'`
- **Actual SQL**: `SELECT COUNT(DISTINCT "account"."account_id") FROM "account" JOIN "district" ON "account"."district_id" = "district"."district_id" JOIN "trans" ON "account"."account_id" = "trans"."account_id" JOIN "disp" ON "account"."account_id" = "disp"."account_id" JOIN "card" ON "disp"."disp_id" = "card"."disp_id" WHERE "district"."A3" = 'East Bohemia' AND "card"."issued" > "trans"."date"`
- **Root Cause**: The model misinterpreted the phrase "issuance after transaction". It tried to literally join card issuance and transaction dates instead of mapping it to the domain-specific account frequency code `POPLATEK PO OBRATU`. It also struggled with the case sensitivity of the region string ('East Bohemia' vs 'east Bohemia').
- **Proposed Mutation**: 
  1. Add a facet for the domain terminology "issuance after transaction" mapping to `account.frequency = 'POPLATEK PO OBRATU'`.
  2. Add a value search configuration for regions (district.A3) to ensure case-insensitive matching.

### Query 2: "How many male customers who are living in North Bohemia have average salary greater than 8000?"
- **Error Category**: `[ValueLinkingError]`
- **Expected SQL**: `SELECT COUNT("T1"."client_id") FROM "client" AS "T1" INNER JOIN "district" AS "T2" ON "T1"."district_id" = "T2"."district_id" WHERE "T1"."gender" = 'M' AND "T2"."A3" = 'north Bohemia' AND "T2"."A11" > 8000`
- **Actual SQL**: `SELECT count("public"."client"."client_id") FROM "public"."client" JOIN "public"."district" ON "public"."client"."district_id" = "public"."district"."district_id" WHERE "public"."client"."gender" = 'M' AND "public"."district"."A3" = 'North Bohemia' AND "public"."district"."A11" > 8000;`
- **Root Cause**: The model correctly deduced the SQL logic but failed due to a case-sensitive string match error. It queried `North Bohemia` with a capital 'N', but the database expects `north Bohemia`. 
- **Proposed Mutation**: Add a value search configuration for `district.A3` (Region) to enable fuzzy or case-insensitive matching for region names. This will fix both Query 1 and Query 2.
