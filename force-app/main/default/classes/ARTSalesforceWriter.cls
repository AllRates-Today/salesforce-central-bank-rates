/**
 * Writes conversion rates into this org. Apex DML is not allowed on DatedConversionRate or CurrencyType,
 * so writes go through the org's own REST API via the "ART_Salesforce_API" Named Credential.
 *
 * Queries use dynamic SOQL so the classes also compile in single-currency orgs (where these objects
 * do not exist) — only running a sync there fails.
 */
public with sharing class ARTSalesforceWriter {

    public class WriteException extends Exception {}

    public class Result {
        public Integer inserted = 0;
        public Integer updated = 0;
        public List<String> errors = new List<String>();
    }

    @TestVisible static String corporateOverride;
    @TestVisible static Map<String, Id> currencyTypeOverride;      // IsoCode -> CurrencyType Id (active, non-corporate)
    @TestVisible static Map<String, Id> existingDatedOverride;     // IsoCode -> DatedConversionRate Id on the date

    /** Corporate currency ISO code. */
    public static String corporateCurrency() {
        if (corporateOverride != null) return corporateOverride;
        List<SObject> rows = Database.query('SELECT IsoCode FROM CurrencyType WHERE IsCorporate = true LIMIT 1');
        if (rows.isEmpty()) throw new WriteException('No corporate currency: is multi-currency enabled in this org?');
        return (String) rows[0].get('IsoCode');
    }

    /** Active, non-corporate currencies: IsoCode -> CurrencyType Id. */
    public static Map<String, Id> activeCurrencies() {
        if (currencyTypeOverride != null) return currencyTypeOverride;
        Map<String, Id> m = new Map<String, Id>();
        for (SObject s : Database.query('SELECT Id, IsoCode FROM CurrencyType WHERE IsActive = true AND IsCorporate = false')) {
            m.put((String) s.get('IsoCode'), s.Id);
        }
        return m;
    }

    /** Upserts one DatedConversionRate per currency with StartDate = the bank's rate date. */
    public static Result writeDated(ARTRateOptions o, Date startDate, Map<String, Decimal> rates) {
        Result r = new Result();
        if (rates.isEmpty()) return r;
        Map<String, Id> existing = existingDatedOverride;
        if (existing == null) {
            existing = new Map<String, Id>();
            Set<String> codes = rates.keySet();
            for (SObject s : Database.query('SELECT Id, IsoCode FROM DatedConversionRate WHERE StartDate = :startDate AND IsoCode IN :codes')) {
                existing.put((String) s.get('IsoCode'), s.Id);
            }
        }
        String base = '/services/data/' + o.orgApiVersion + '/sobjects/DatedConversionRate';
        for (String code : rates.keySet()) {
            try {
                if (existing.containsKey(code)) {
                    send(o, 'PATCH', base + '/' + existing.get(code), new Map<String, Object>{ 'ConversionRate' => rates.get(code) });
                    r.updated++;
                } else {
                    send(o, 'POST', base, new Map<String, Object>{
                        'IsoCode' => code,
                        'ConversionRate' => rates.get(code),
                        'StartDate' => String.valueOf(startDate)
                    });
                    r.inserted++;
                }
            } catch (Exception e) {
                r.errors.add(code + ': ' + e.getMessage());
            }
        }
        return r;
    }

    /** Updates CurrencyType.ConversionRate (static rates, used when Advanced Currency Management is off). */
    public static Result writeStatic(ARTRateOptions o, Map<String, Decimal> rates, Map<String, Id> currencyIds) {
        Result r = new Result();
        String base = '/services/data/' + o.orgApiVersion + '/sobjects/CurrencyType/';
        for (String code : rates.keySet()) {
            if (!currencyIds.containsKey(code)) continue;
            try {
                send(o, 'PATCH', base + currencyIds.get(code), new Map<String, Object>{ 'ConversionRate' => rates.get(code) });
                r.updated++;
            } catch (Exception e) {
                r.errors.add(code + ': ' + e.getMessage());
            }
        }
        return r;
    }

    private static void send(ARTRateOptions o, String method, String path, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + o.orgNamedCredential + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(body));
        req.setTimeout(30000);
        HttpResponse res = new Http().send(req);
        Integer sc = res.getStatusCode();
        if (sc < 200 || sc >= 300) {
            throw new WriteException('HTTP ' + sc + ' ' + res.getBody().left(300));
        }
    }
}
