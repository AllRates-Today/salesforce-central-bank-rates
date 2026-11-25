/**
 * Turns one AllRatesToday table into Salesforce conversion rates. Pure logic, no callouts or queries.
 *
 * API rows: { base, quote, type, value } = `value` units of quote per 1 unit of base.
 * Salesforce ConversionRate: units of the currency per 1 unit of the corporate currency.
 *
 * Every row involves the publisher's home currency (EUR for the ECB, INR for the RBI). Each currency is first
 * expressed per 1 unit of home currency, then divided by the corporate currency's figure, so a USD-corporate
 * org can use the ECB table (EUR-based) and a EUR-corporate org can use the RBI table (INR-based).
 */
public with sharing class ARTRateMapper {

    public class RateTable {
        public Date rateDate;
        public Boolean stale = false;
        public String home;
        /** Units of currency per 1 unit of home currency. Contains home -> 1. */
        public Map<String, Decimal> perHome = new Map<String, Decimal>();
    }

    public class MappingException extends Exception {}

    /** Parses a /latest or /{date} response body. */
    public static RateTable parse(String body, String rateTypeFilter) {
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
        if (!root.containsKey('rates') || !(root.get('rates') instanceof List<Object>)) {
            throw new MappingException('Response has no "rates" array.');
        }
        RateTable t = new RateTable();
        t.rateDate = Date.valueOf((String) root.get('rate_date'));
        t.stale = root.get('stale') == true;

        String filter = String.isBlank(rateTypeFilter) ? null : rateTypeFilter.toLowerCase();
        List<List<Object>> rows = new List<List<Object>>();
        Map<String, Integer> counts = new Map<String, Integer>();
        Set<String> seenPairs = new Set<String>();
        for (Object o : (List<Object>) root.get('rates')) {
            Map<String, Object> r = (Map<String, Object>) o;
            String base = ((String) r.get('base')).toUpperCase();
            String quote = ((String) r.get('quote')).toUpperCase();
            String type = r.get('type') == null ? '' : ((String) r.get('type')).toLowerCase();
            Decimal value = toDecimal(r.get('value'));
            if (value == null || value <= 0) continue;
            if (filter != null && type != filter) continue;
            // Several rate types (buying/selling/mid) for one pair: keep the first one seen.
            if (!seenPairs.add(base + '/' + quote)) continue;
            rows.add(new List<Object>{ base, quote, value });
            counts.put(base, (counts.containsKey(base) ? counts.get(base) : 0) + 1);
            counts.put(quote, (counts.containsKey(quote) ? counts.get(quote) : 0) + 1);
        }
        if (rows.isEmpty()) {
            throw new MappingException('No usable rows' + (filter == null ? '' : ' of type "' + filter + '"') + ' in the table.');
        }

        // Home currency = the one that appears in the most rows.
        Integer best = -1;
        for (String c : counts.keySet()) {
            if (counts.get(c) > best) { best = counts.get(c); t.home = c; }
        }
        t.perHome.put(t.home, 1);
        for (List<Object> row : rows) {
            String base = (String) row[0];
            String quote = (String) row[1];
            Decimal value = (Decimal) row[2];
            if (base == t.home && !t.perHome.containsKey(quote)) {
                t.perHome.put(quote, value);                       // ECB style: USD per 1 EUR
            } else if (quote == t.home && !t.perHome.containsKey(base)) {
                t.perHome.put(base, Decimal.valueOf(1).divide(value, 12));                    // RBI style: INR per 1 USD -> USD per 1 INR
            }
        }
        return t;
    }

    /**
     * ConversionRate for each active non-corporate currency the table covers, rounded to 6 decimals
     * (the scale Salesforce stores). Currencies the table does not cover are left out.
     */
    public static Map<String, Decimal> conversionRates(RateTable t, String corporate, Set<String> activeCodes) {
        corporate = corporate.toUpperCase();
        if (!t.perHome.containsKey(corporate)) {
            throw new MappingException('The table (home currency ' + t.home + ') has no rate for the corporate currency ' + corporate + '.');
        }
        Decimal corpPerHome = t.perHome.get(corporate);
        Map<String, Decimal> result = new Map<String, Decimal>();
        for (String code : activeCodes) {
            String c = code.toUpperCase();
            if (c == corporate || !t.perHome.containsKey(c)) continue;
            Decimal rate = t.perHome.get(c).divide(corpPerHome, 6, System.RoundingMode.HALF_UP);
            if (rate > 0) result.put(c, rate);
        }
        return result;
    }

    /** JSON.deserializeUntyped returns Integer, Long, Decimal or Double for numbers. */
    @TestVisible
    private static Decimal toDecimal(Object o) {
        if (o == null) return null;
        if (o instanceof Decimal) return (Decimal) o;
        if (o instanceof Integer) return Decimal.valueOf((Integer) o);
        if (o instanceof Long) return Decimal.valueOf((Long) o);
        if (o instanceof Double) return Decimal.valueOf((Double) o);
        return Decimal.valueOf(String.valueOf(o));
    }
}
