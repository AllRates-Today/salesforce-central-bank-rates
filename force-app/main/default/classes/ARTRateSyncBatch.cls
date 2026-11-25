/**
 * One batch item = one table ('latest' or a YYYY-MM-DD date). Run with scope 1 so each execute() makes
 * 1 call to AllRatesToday plus one write callout per currency (well under the 100-callout limit).
 *
 * Latest table now:
 *   Database.executeBatch(new ARTRateSyncBatch(new ARTRateOptions('ecb')), 1);
 *
 * Historical load (weekdays from..to; weekends and holidays resolve to the table in force):
 *   Database.executeBatch(ARTRateSyncBatch.historical(new ARTRateOptions('ecb'), Date.newInstance(2026,1,1), Date.today()), 1);
 */
public with sharing class ARTRateSyncBatch implements Database.Batchable<String>, Database.AllowsCallouts, Database.Stateful {

    private ARTRateOptions options;
    private List<String> dates;
    private Set<Date> written = new Set<Date>();
    public List<String> log = new List<String>();

    public class SyncException extends Exception {}

    public ARTRateSyncBatch(ARTRateOptions options) {
        this(options, new List<String>{ 'latest' });
    }

    public ARTRateSyncBatch(ARTRateOptions options, List<String> dates) {
        if (options == null || String.isBlank(options.bank)) throw new IllegalArgumentException('A bank code is required.');
        this.options = options;
        this.dates = dates;
    }

    public static ARTRateSyncBatch historical(ARTRateOptions options, Date fromDate, Date toDate) {
        if (options.mode != ARTRateOptions.SyncMode.DATED) throw new IllegalArgumentException('A historical load needs SyncMode.DATED.');
        List<String> ds = new List<String>();
        for (Date d = fromDate; d <= toDate; d = d.addDays(1)) {
            // 2024-01-01 is a Monday; skip Saturdays (5) and Sundays (6).
            Integer dow = Math.mod(Date.newInstance(2024, 1, 1).daysBetween(d), 7);
            if (dow < 0) dow += 7;
            if (dow < 5) ds.add(String.valueOf(d));
        }
        return new ARTRateSyncBatch(options, ds);
    }

    public Iterable<String> start(Database.BatchableContext bc) {
        return dates;
    }

    public void execute(Database.BatchableContext bc, List<String> scope) {
        for (String d : scope) {
            String msg = syncOne(d);
            log.add(msg);
            System.debug(LoggingLevel.INFO, 'AllRatesToday ' + options.bank + ' ' + d + ': ' + msg);
            // Surface write failures in Setup > Apex Jobs (NumberOfErrors / ExtendedStatus), not only in the debug log.
            if (msg.contains(', errors: ')) throw new SyncException(options.bank + ' ' + d + ': ' + msg.left(900));
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'AllRatesToday sync finished: ' + String.join(log, ' | ').left(30000));
    }

    @TestVisible
    private String syncOne(String dateOrLatest) {
        ARTRateMapper.RateTable t = ARTRateMapper.parse(ARTRatesClient.fetchTable(options, dateOrLatest), options.rateType);
        // A holiday returns the previous table: write each rate_date once per run.
        if (options.mode == ARTRateOptions.SyncMode.DATED && !written.add(t.rateDate)) {
            return 'table ' + String.valueOf(t.rateDate) + ' already written in this run';
        }
        Map<String, Id> active = ARTSalesforceWriter.activeCurrencies();
        Map<String, Decimal> rates = ARTRateMapper.conversionRates(t, ARTSalesforceWriter.corporateCurrency(), active.keySet());
        ARTSalesforceWriter.Result r = options.mode == ARTRateOptions.SyncMode.DATED
            ? ARTSalesforceWriter.writeDated(options, t.rateDate, rates)
            : ARTSalesforceWriter.writeStatic(options, rates, active);
        String msg = 'table ' + String.valueOf(t.rateDate) + ': ' + r.inserted + ' inserted, ' + r.updated + ' updated, '
            + (active.size() - rates.size()) + ' active currencies not in table';
        if (t.stale) msg += ', API flags the table as stale';
        if (!r.errors.isEmpty()) msg += ', errors: ' + String.join(r.errors, '; ');
        return msg;
    }
}
