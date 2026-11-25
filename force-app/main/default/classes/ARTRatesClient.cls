/**
 * Fetches one table from the AllRatesToday Central Bank Exchange Rate API through the "AllRatesToday"
 * Named Credential (URL https://allratestoday.com, custom header Authorization: Bearer <key>).
 *
 *   'latest'      -> GET /api/v1/central-bank/{bank}/latest
 *   'YYYY-MM-DD'  -> GET /api/v1/central-bank/{bank}/{date}   (the table in force on that date; paid plans)
 *   keyless       -> GET /api/open/central-bank/{bank}          (latest only, evaluation)
 */
public with sharing class ARTRatesClient {

    public class ApiException extends Exception {}

    public static String fetchTable(ARTRateOptions o, String dateOrLatest) {
        String bank = EncodingUtil.urlEncode(o.bank.trim().toLowerCase(), 'UTF-8');
        String path;
        if (o.keyless) {
            if (dateOrLatest != 'latest') {
                throw new ApiException('Dated tables need an API key; the keyless endpoint serves the latest table only.');
            }
            path = '/api/open/central-bank/' + bank;
        } else {
            path = '/api/v1/central-bank/' + bank + '/' + dateOrLatest;
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + o.apiNamedCredential + path);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setHeader('User-Agent', 'salesforce-central-bank-rates/1.0 (+https://allratestoday.com/docs/integrations/salesforce/)');
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new ApiException('AllRatesToday returned HTTP ' + res.getStatusCode() + ' for ' + path + ': ' + res.getBody().left(500));
        }
        return res.getBody();
    }
}
