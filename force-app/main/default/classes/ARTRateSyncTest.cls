@IsTest
private class ARTRateSyncTest {

    static final String ECB = '{"bank":"ecb","rate_date":"2026-11-25","stale":false,"rates":['
        + '{"base":"EUR","quote":"USD","type":"reference","value":1.25},'
        + '{"base":"EUR","quote":"GBP","type":"reference","value":0.85},'
        + '{"base":"EUR","quote":"JPY","type":"reference","value":180}]}';

    static final String RBI = '{"bank":"rbi","rate_date":"2026-11-25","stale":true,"rates":['
        + '{"base":"USD","quote":"INR","type":"reference","value":80},'
        + '{"base":"EUR","quote":"INR","type":"reference","value":100}]}';

    /** Answers AllRatesToday GETs with `table` and records every org REST write. */
    class Mock implements HttpCalloutMock {
        String table;
        Integer writeStatus;
        List<HttpRequest> writes = new List<HttpRequest>();
        Mock(String table, Integer writeStatus) { this.table = table; this.writeStatus = writeStatus; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().startsWith('callout:AllRatesToday')) {
                res.setStatusCode(table == null ? 401 : 200);
                res.setBody(table == null ? '{"error":"Invalid API key"}' : table);
            } else {
                writes.add(req);
                res.setStatusCode(writeStatus);
                res.setBody(writeStatus < 300 ? '{"id":"04w000000000001","success":true}' : '[{"message":"bad"}]');
            }
            return res;
        }
    }

    static void fakeOrg(String corporate, Map<String, Id> active, Map<String, Id> existing) {
        ARTSalesforceWriter.corporateOverride = corporate;
        ARTSalesforceWriter.currencyTypeOverride = active;
        ARTSalesforceWriter.existingDatedOverride = existing;
    }

    @IsTest
    static void mapsHomeBasedTableToForeignCorporate() {
        ARTRateMapper.RateTable t = ARTRateMapper.parse(ECB, null);
        System.assertEquals('EUR', t.home);
        System.assertEquals(Date.newInstance(2026, 11, 25), t.rateDate);
        Map<String, Decimal> r = ARTRateMapper.conversionRates(t, 'USD', new Set<String>{ 'EUR', 'GBP', 'JPY', 'CHF' });
        System.assertEquals(0.8, r.get('EUR'));      // 1 / 1.25
        System.assertEquals(0.68, r.get('GBP'));     // 0.85 / 1.25
        System.assertEquals(144, r.get('JPY'));      // 180 / 1.25
        System.assertEquals(false, r.containsKey('CHF'));
    }

    @IsTest
    static void mapsForeignBasedTable() {
        ARTRateMapper.RateTable t = ARTRateMapper.parse(RBI, null);
        System.assertEquals('INR', t.home);
        System.assertEquals(true, t.stale);
        Map<String, Decimal> r = ARTRateMapper.conversionRates(t, 'EUR', new Set<String>{ 'USD', 'INR' });
        System.assertEquals(1.25, r.get('USD'));     // (1/80) / (1/100)
        System.assertEquals(100, r.get('INR'));
    }

    @IsTest
    static void rateTypeFilterAndErrors() {
        String twoTypes = '{"rate_date":"2026-11-25","rates":['
            + '{"base":"USD","quote":"LKR","type":"buying","value":300},'
            + '{"base":"USD","quote":"LKR","type":"selling","value":310},'
            + '{"base":"EUR","quote":"LKR","type":"selling","value":360}]}';
        ARTRateMapper.RateTable sell = ARTRateMapper.parse(twoTypes, 'selling');
        System.assertEquals('LKR', sell.home);
        System.assertEquals(310, ARTRateMapper.conversionRates(sell, 'USD', new Set<String>{ 'LKR' }).get('LKR'));
        // No filter: the first row per pair (buying 300) wins.
        System.assertEquals(300, ARTRateMapper.conversionRates(ARTRateMapper.parse(twoTypes, null), 'USD', new Set<String>{ 'LKR' }).get('LKR'));
        try { ARTRateMapper.parse(twoTypes, 'mid'); System.assert(false); } catch (ARTRateMapper.MappingException e) {}
        try { ARTRateMapper.parse('{"rate_date":"2026-11-25"}', null); System.assert(false); } catch (ARTRateMapper.MappingException e) {}
        try {
            ARTRateMapper.conversionRates(ARTRateMapper.parse(ECB, null), 'AUD', new Set<String>{ 'USD' });
            System.assert(false);
        } catch (ARTRateMapper.MappingException e) {}
        System.assertEquals(2, ARTRateMapper.toDecimal(2));
        System.assertEquals(2, ARTRateMapper.toDecimal(2L));
        System.assertEquals(null, ARTRateMapper.toDecimal(null));
    }

    @IsTest
    static void datedSyncInsertsAndUpdates() {
        Mock m = new Mock(ECB, 201);
        Test.setMock(HttpCalloutMock.class, m);
        fakeOrg('USD', new Map<String, Id>{ 'EUR' => null, 'GBP' => null }, new Map<String, Id>{ 'GBP' => '04w000000000002' });
        ARTRateSyncBatch b = new ARTRateSyncBatch(new ARTRateOptions('ecb'));
        Test.startTest();
        String msg = b.syncOne('latest');
        Test.stopTest();
        System.assert(msg.contains('1 inserted, 1 updated'), msg);
        System.assertEquals(2, m.writes.size());
        Boolean sawPost = false;
        for (HttpRequest w : m.writes) {
            if (w.getMethod() == 'POST') {
                sawPost = true;
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(w.getBody());
                System.assertEquals('EUR', body.get('IsoCode'));
                System.assertEquals('2026-11-25', body.get('StartDate'));
            } else {
                System.assertEquals('PATCH', w.getMethod());
                System.assert(w.getEndpoint().contains('/DatedConversionRate/04w000000000002'), w.getEndpoint());   // Id becomes 18 chars
            }
        }
        System.assert(sawPost);
        // Same rate_date again in one run (holiday) is not rewritten.
        System.assert(b.syncOne('2026-11-26').contains('already written'));
    }

    @IsTest
    static void staticSyncReportsWriteErrors() {
        Test.setMock(HttpCalloutMock.class, new Mock(RBI, 400));
        fakeOrg('EUR', new Map<String, Id>{ 'USD' => '02k000000000001' }, null);
        ARTRateOptions o = new ARTRateOptions('rbi');
        o.mode = ARTRateOptions.SyncMode.STATIC_RATES;
        Test.startTest();
        String msg = new ARTRateSyncBatch(o).syncOne('latest');
        Test.stopTest();
        System.assert(msg.contains('stale'), msg);
        System.assert(msg.contains('errors: USD'), msg);
        // Through the batch, failed writes fail the job so they show in Apex Jobs.
        try {
            new ARTRateSyncBatch(o).execute(null, new List<String>{ 'latest' });
            System.assert(false, 'expected SyncException');
        } catch (ARTRateSyncBatch.SyncException e) {
            System.assert(e.getMessage().contains('errors: USD'), e.getMessage());
        }
    }

    @IsTest
    static void apiErrorAndKeylessRules() {
        Test.setMock(HttpCalloutMock.class, new Mock(null, 200));
        try { ARTRatesClient.fetchTable(new ARTRateOptions('ecb'), 'latest'); System.assert(false); }
        catch (ARTRatesClient.ApiException e) { System.assert(e.getMessage().contains('401')); }
        ARTRateOptions k = new ARTRateOptions('ecb');
        k.keyless = true;
        try { ARTRatesClient.fetchTable(k, '2026-01-02'); System.assert(false); } catch (ARTRatesClient.ApiException e) {}
    }

    @IsTest
    static void batchScheduleAndHistoricalDates() {
        ARTRateSyncBatch h = ARTRateSyncBatch.historical(new ARTRateOptions('ecb'), Date.newInstance(2026, 11, 20), Date.newInstance(2026, 11, 24));
        List<String> ds = (List<String>) h.start(null);
        System.assertEquals(new List<String>{ '2026-11-20', '2026-11-23', '2026-11-24' }, ds);   // Fri, Mon, Tue

        Test.setMock(HttpCalloutMock.class, new Mock(ECB, 201));
        fakeOrg('USD', new Map<String, Id>{ 'EUR' => null }, new Map<String, Id>());
        Test.startTest();
        ARTRateSyncBatch b = new ARTRateSyncBatch(new ARTRateOptions('ecb'));
        b.execute(null, new List<String>{ 'latest' });
        b.finish(null);
        // Scheduling counts as pending work, so it comes after the callouts.
        System.schedule('ART test', '0 0 17 ? * MON-FRI', new ARTRateSyncSchedulable(new ARTRateOptions('ecb')));
        Test.stopTest();
        System.assertEquals(1, b.log.size());
    }
}
