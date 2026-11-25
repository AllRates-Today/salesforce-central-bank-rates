/**
 * Scheduled entry point. Scheduled Apex cannot make callouts itself, so it starts ARTRateSyncBatch.
 *
 *   // ECB publishes around 16:00 CET: run at 17:00, Monday to Friday (cron uses the scheduling user's time zone)
 *   System.schedule('AllRatesToday ECB rates', '0 0 17 ? * MON-FRI', new ARTRateSyncSchedulable(new ARTRateOptions('ecb')));
 */
public with sharing class ARTRateSyncSchedulable implements Schedulable {

    private ARTRateOptions options;

    public ARTRateSyncSchedulable(ARTRateOptions options) {
        this.options = options;
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ARTRateSyncBatch(options), 1);
    }
}
