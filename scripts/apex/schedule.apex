// Run in Developer Console > Debug > Open Execute Anonymous Window (or: sf apex run --file scripts/apex/schedule.apex)

// 1. Test once: load the latest ECB table now (check Setup > Apex Jobs, then Setup > Manage Currencies).
ARTRateOptions o = new ARTRateOptions('ecb');          // any code from allratestoday.com/central-bank-rates-api/institutions/
o.mode = ARTRateOptions.Mode.DATED;                    // or ARTRateOptions.Mode.STATIC_RATES without Advanced Currency Management
// o.rateType = 'selling';                             // for tables with buying/selling rows
Database.executeBatch(new ARTRateSyncBatch(o), 1);

// 2. Schedule it: weekdays at 17:00 in the scheduling user's time zone (after the ECB's ~16:00 CET publication).
// System.schedule('AllRatesToday ECB rates', '0 0 17 ? * MON-FRI', new ARTRateSyncSchedulable(o));

// 3. Historical load (dated mode, needs a paid AllRatesToday plan): one table per weekday in the range.
// Database.executeBatch(ARTRateSyncBatch.historical(o, Date.newInstance(2026, 1, 1), Date.today()), 1);
