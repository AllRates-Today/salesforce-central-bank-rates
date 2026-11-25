/**
 * Settings for one sync job. Passed to ARTRateSyncSchedulable / ARTRateSyncBatch from Anonymous Apex,
 * so the package needs no custom objects or custom settings.
 *
 *   ARTRateOptions o = new ARTRateOptions('ecb');   // bank or tax-authority code, lower case
 *   o.mode = ARTRateOptions.Mode.DATED;            // DatedConversionRate (Advanced Currency Management)
 *   o.rateType = null;                             // e.g. 'reference', 'buying', 'selling'; null = first per pair
 */
public with sharing class ARTRateOptions {
    public enum Mode { DATED, STATIC_RATES }

    /** Bank or tax-authority code as used in /api/v1/central-bank/{bank}/..., e.g. ecb, boe, rbi, hmrc. */
    public String bank;
    /** DATED writes DatedConversionRate (needs Advanced Currency Management); STATIC_RATES updates CurrencyType. */
    public Mode mode = Mode.DATED;
    /** Only use rows of this rate type. Null = the first row seen for each currency. */
    public String rateType;
    /** Named Credential for https://allratestoday.com (sends the Authorization header). */
    public String apiNamedCredential = 'AllRatesToday';
    /** Named Credential for this org's own REST API (DatedConversionRate/CurrencyType cannot be written with Apex DML). */
    public String orgNamedCredential = 'ART_Salesforce_API';
    /** Salesforce REST API version used for the writes. */
    public String orgApiVersion = 'v62.0';
    /** Use the keyless evaluation endpoint /api/open/central-bank/{bank} (latest table only, attribution required). */
    public Boolean keyless = false;

    public ARTRateOptions(String bank) {
        this.bank = bank;
    }
}
