# Official Exchange Rates for Salesforce — salesforce-central-bank-rates

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Salesforce API](https://img.shields.io/badge/Salesforce%20API-62.0-00A1E0.svg)](sfdx-project.json)
[![dependencies](https://img.shields.io/badge/dependencies-0-brightgreen.svg)](force-app/main/default/classes)
[![EUR/USD published by the ECB](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fallratestoday.com%2Fapi%2Fopen%2Fcentral-bank%2Fecb%3Fsource%3DEUR%26target%3DUSD&query=%24.rate&label=EUR%2FUSD%20published%20by%20ECB&color=0A7E8C&cacheSeconds=3600)](https://allratestoday.com/central-bank-rates-api/ecb/)
[![Powered by AllRatesToday](https://img.shields.io/badge/Powered%20by-AllRatesToday-orange.svg)](https://allratestoday.com/central-bank-rates-api/)

**Apex classes that load the official exchange rate table of a central bank or tax authority (the ECB, Federal Reserve, Bank of England, RBI, HMRC and 170+ more) from the [AllRatesToday Central Bank Exchange Rate API](https://allratestoday.com/central-bank-rates-api/) into Salesforce multi-currency: dated exchange rates (`DatedConversionRate`) or static conversion rates (`CurrencyType`), on a schedule or for a historical date range.**

Full guide: **[allratestoday.com/docs/integrations/salesforce/](https://allratestoday.com/docs/integrations/salesforce/)**

> Open-source code, not a managed AppExchange package. Tested end to end on 2026-11-25 in a Developer Edition org (API 68.0, USD corporate currency, Advanced Currency Management on). The Apex tests pass with 89% coverage, the ECB table was loaded into dated rates and the RBI table into static rates, and reruns update rows instead of duplicating them. Try it in a sandbox before production.

## What it does

- 🏛️ **Official rates, the bank's own date.** One `GET /api/v1/central-bank/{bank}/latest` per run. Rates are written with `StartDate` = the table's `rate_date` (the date the bank states), not the run date.
- 🧭 **Any corporate currency, any table.** Every row is expressed against the publisher's home currency, then against your corporate currency. A USD-corporate org can use the EUR-based ECB table, and a EUR-corporate org can use the INR-based RBI table.
- 📅 **Dated or static.** With Advanced Currency Management on, it upserts `DatedConversionRate`. With it off, it updates `CurrencyType.ConversionRate`.
- 🧮 **Only currencies you use.** It writes active, non-corporate currencies the table covers. It never creates currencies.
- 🕰️ **Historical load.** `ARTRateSyncBatch.historical(options, from, to)` loads the table in force on each weekday in a range. A holiday resolves to the previous table, and each table is written once.
- 🔐 **No secrets in code.** The API key lives encrypted in an External Credential. There are no custom objects or settings, so options are passed in Apex.
- 🧰 **One-command setup.** `scripts/setup-org.sh <alias>` deploys everything, including the credentials and permission sets, and asks for the two secrets.
- 🚨 **Failures show in Apex Jobs.** If a write fails, the batch job fails with the error, not only in a debug log.
- 🐍 **Or run it outside Salesforce.** [`scripts/python/sync_rates.py`](scripts/python/sync_rates.py) does the same thing over the REST API with the OAuth client credentials flow.

### Why the writes go through REST

Apex DML is not allowed on `DatedConversionRate` or `CurrencyType`. The classes write through this org's own REST API (`/services/data/v62.0/sobjects/...`) via a second Named Credential, `ART_Salesforce_API`. Queries use dynamic SOQL, so the classes also compile in single-currency orgs.

### Classes

| Class | Purpose |
|---|---|
| `ARTRateOptions` | Bank code, mode (`DATED` / `STATIC_RATES`), rate type, Named Credential names |
| `ARTRatesClient` | Calls AllRatesToday through the `AllRatesToday` Named Credential |
| `ARTRateMapper` | Parses a table and computes `ConversionRate` per currency (pure logic) |
| `ARTSalesforceWriter` | Upserts `DatedConversionRate` / updates `CurrencyType` over REST |
| `ARTRateSyncBatch` | Batch Apex, one table per item (`'latest'` or `YYYY-MM-DD`), callouts allowed |
| `ARTRateSyncSchedulable` | Scheduled entry point that starts the batch |
| `ARTRateSyncTest` | Tests with `HttpCalloutMock` |

## Prerequisites

- Multi-currency enabled (Setup → Company Information → Currency Settings), and the currencies you want activated in **Manage Currencies**.
- For dated rates: **Advanced Currency Management** enabled.
- An AllRatesToday API key ([free key](https://allratestoday.com/login?redirect=/profile)). Historical dates (`/{date}`) need a paid plan.

## Install

```bash
git clone https://github.com/AllRates-Today/salesforce-central-bank-rates.git
cd salesforce-central-bank-rates
sf org login web --alias myorg                 # add --instance-url https://test.salesforce.com for a sandbox
./scripts/setup-org.sh myorg
sf apex run test --class-names ARTRateSyncTest --target-org myorg --result-format human
```

`setup-org.sh` needs the `sf` CLI and `python3`. It does five things:

1. It deploys `force-app`: the Apex classes, the **`AllRatesToday`** External Credential and Named Credential (`https://allratestoday.com`, sends `Authorization: Bearer <key>`), and the **`AllRatesToday_Rates`** permission set.
2. It deploys `config/self-api` with your org's URL and username filled in:
   - the **ART Rate Sync** External Client App (client credentials flow, run as you);
   - the **`ART_Salesforce_API`** External Credential (OAuth 2.0, client credentials with client secret, token URL `<your domain>/services/oauth2/token`, no scope);
   - its Named Credential (your domain, with *Generate Authorization Header* on);
   - the **`ART_Salesforce_API_Access`** permission set.
3. It assigns both permission sets to you.
4. It asks for your AllRatesToday key and stores it, encrypted, on the `AllRatesToday` principal.
5. It asks for the External Client App's **consumer secret** and stores it with the consumer key on the `ART_Salesforce_API` principal. Salesforce shows the secret only in Setup, under *External Client App Manager → ART Rate Sync → Settings → OAuth Settings → Consumer Key and Secret*, after an emailed code.

It is safe to run again. Each step overwrites what is there.

### Manual setup (without the script)

- **Rates API:** deploy `force-app`. Then open *Setup → Named Credentials → External Credentials → AllRatesToday → Principals → Default* and add an authentication parameter `ApiKey` with your key.
- **This org's API:** create an External Client App with OAuth enabled (any callback URL) and **Enable Client Credentials Flow**, with a run-as user who can manage currencies. Then create an External Credential `ART_Salesforce_API`:
  - Authentication Protocol **OAuth 2.0**
  - Flow **Client Credentials with Client Secret**
  - Identity Provider URL `https://<your-domain>.my.salesforce.com/services/oauth2/token`
  - **leave Scope empty** (the token endpoint rejects it)
  - a Named Principal `Default` with the consumer key and secret

  Then create a Named Credential `ART_Salesforce_API` with URL `https://<your-domain>.my.salesforce.com` and *Generate Authorization Header* ticked.
- **Access:** give the running user principal access to `AllRatesToday - Default` and `ART_Salesforce_API - Default` (the two permission sets do this).

## Run

[`scripts/apex/schedule.apex`](scripts/apex/schedule.apex), in Execute Anonymous:

```apex
ARTRateOptions o = new ARTRateOptions('ecb');          // bank or tax-authority code
o.mode = ARTRateOptions.SyncMode.DATED;                 // or STATIC_RATES
Database.executeBatch(new ARTRateSyncBatch(o), 1);     // latest table, now

// weekdays 17:00 (scheduling user's time zone), after the ECB's ~16:00 CET publication
System.schedule('AllRatesToday ECB rates', '0 0 17 ? * MON-FRI', new ARTRateSyncSchedulable(o));

// historical load, one table per weekday
Database.executeBatch(ARTRateSyncBatch.historical(o, Date.newInstance(2026, 1, 1), Date.today()), 1);
```

Results are in **Setup → Apex Jobs** and the debug log, for example `table 2026-11-25: 12 inserted, 0 updated, 3 active currencies not in table`. Rates show under **Manage Currencies → Manage Dated Exchange Rates**.

Bank codes: [allratestoday.com/central-bank-rates-api/institutions/](https://allratestoday.com/central-bank-rates-api/institutions/). Each bank's publication time is in its `/latest` response (`usually_at_utc`), so schedule after it.

## Rate direction

The API returns `value` = units of `quote` per 1 unit of `base`. Salesforce stores `ConversionRate` = units of the currency per 1 unit of the corporate currency. For corporate currency C and currency X, both taken from the publisher's home currency H:

```
ConversionRate(X) = (X per 1 H) / (C per 1 H)        rounded to 6 decimals
```

With a USD corporate currency and the ECB table (EUR→USD 1.0935, EUR→GBP 0.8373), the rates written are EUR = 0.914495 and GBP = 0.765706.

## 🔗 Links

- **Website:** [allratestoday.com](https://allratestoday.com)
- [Salesforce guide](https://allratestoday.com/docs/integrations/salesforce/)
- [API Documentation](https://allratestoday.com/developers)
- [Register (Free)](https://allratestoday.com/register)
- [Dashboard](https://allratestoday.com/profile)
- [Status](https://allratestoday.com/status)
- [Other ERP guides](https://allratestoday.com/docs/integrations/) — Business Central, SAP, NetSuite, Dynamics 365 Finance, Xero, QuickBooks, Odoo
- [GitHub](https://github.com/AllRates-Today/salesforce-central-bank-rates)

## 📜 License

MIT. Rates are published by the issuing central banks and tax authorities and served by AllRatesToday under its [terms](https://allratestoday.com/terms/).
