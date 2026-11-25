#!/usr/bin/env bash
# One-time setup of salesforce-central-bank-rates in an org you are logged into with the sf CLI.
#
#   sf org login web --alias myorg
#   ./scripts/setup-org.sh myorg
#
# It deploys the Apex classes, the AllRatesToday Named Credential and the AllRatesToday_Rates permission set,
# then creates the ART Rate Sync External Client App (client credentials flow, run as you) and the
# ART_Salesforce_API Named Credential the classes use to write DatedConversionRate / CurrencyType over REST.
# It asks for two secrets and never prints them: your AllRatesToday API key, and the External Client App's
# consumer secret (Salesforce shows it only in Setup).
set -euo pipefail
ORG="${1:?usage: setup-org.sh <org alias>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
API=v64.0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
umask 077

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
INFO="$(sf org display -o "$ORG" --json)"
URL="$(echo "$INFO" | json "d['result']['instanceUrl']")"
USERNAME="$(echo "$INFO" | json "d['result']['username']")"
EMAIL="$(sf data query -o "$ORG" -q "SELECT Email FROM User WHERE Username = '$USERNAME'" --json | json "d['result']['records'][0]['Email']")"
echo "Org: $URL (run-as user $USERNAME)"

echo "1/5 Deploying classes, AllRatesToday credential and permission set..."
(cd "$HERE" && sf project deploy start -o "$ORG" --source-dir force-app --wait 20 >/dev/null)

echo "2/5 Deploying the ART Rate Sync External Client App and ART_Salesforce_API credential..."
mkdir -p "$WORK/proj" && cp "$HERE/sfdx-project.json" "$WORK/proj/"
mkdir -p "$WORK/proj/force-app/main" && cp -r "$HERE/config/self-api" "$WORK/proj/force-app/main/default"
find "$WORK/proj/force-app" -name '*.xml' -exec sed -i -e "s#__INSTANCE_URL__#$URL#g" -e "s#__RUN_AS_USERNAME__#$USERNAME#g" -e "s#__CONTACT_EMAIL__#$EMAIL#g" {} +
(cd "$WORK/proj" && sf project deploy start -o "$ORG" --source-dir force-app --wait 20 >/dev/null)

echo "3/5 Assigning permission sets to $USERNAME..."
sf org assign permset -o "$ORG" -n AllRatesToday_Rates -n ART_Salesforce_API_Access >/dev/null 2>&1 || true

# POST a principal's credentials; on CONFLICT (already set) overwrite with PUT.
put_cred() {
  local body="$1" out
  out="$(sf api request rest "/services/data/$API/named-credentials/credential" --method POST --body @"$body" -o "$ORG" 2>&1 || true)"
  if echo "$out" | grep -q CONFLICT; then
    out="$(sf api request rest "/services/data/$API/named-credentials/credential" --method PUT --body @"$body" -o "$ORG" 2>&1 || true)"
  fi
  echo "$out" | grep -q '"authenticationStatus"' || { echo "   failed: $(echo "$out" | grep -o '"message"[^,]*' | head -1)"; return 1; }
}

echo "4/5 AllRatesToday API key (art_live_..., from https://allratestoday.com/profile):"
read -rsp "   key: " KEY; echo
KEY="$KEY" python3 -c "import json,os; print(json.dumps({'externalCredential':'AllRatesToday','principalName':'Default','principalType':'NamedPrincipal','credentials':{'ApiKey':{'value':os.environ['KEY'],'encrypted':True}}}))" > "$WORK/k.json"
unset KEY; put_cred "$WORK/k.json" && echo "   stored"

echo "5/5 External Client App consumer secret."
APP_ID="$(sf data query -o "$ORG" --use-tooling-api -q "SELECT Id FROM ExternalClientApplication WHERE DeveloperName = 'ART_Rate_Sync'" --json | json "d['result']['records'][0]['Id']")"
CONSUMER="$(sf api request rest "/services/data/$API/apps/oauth/credentials/$APP_ID" -o "$ORG" | json "d['consumers'][0]['id']")"
CLIENT_ID="$(sf api request rest "/services/data/$API/apps/oauth/credentials/$APP_ID/$CONSUMER?part=keyandsecret" -o "$ORG" | json "d['key']")"
echo "   Setup > External Client App Manager > ART Rate Sync > Settings > OAuth Settings > Consumer Key and Secret"
echo "   (Salesforce emails you a verification code), copy the Consumer Secret."
read -rsp "   consumer secret: " SECRET; echo
CID="$CLIENT_ID" SECRET="$SECRET" python3 -c "import json,os; print(json.dumps({'externalCredential':'ART_Salesforce_API','principalName':'Default','principalType':'NamedPrincipal','credentials':{'clientId':{'value':os.environ['CID'],'encrypted':False},'clientSecret':{'value':os.environ['SECRET'],'encrypted':True}}}))" > "$WORK/s.json"
unset SECRET; put_cred "$WORK/s.json" && echo "   stored"

cat <<MSG

Done. Test with a one-off run of the latest ECB table (Execute Anonymous or sf apex run):
  Database.executeBatch(new ARTRateSyncBatch(new ARTRateOptions('ecb')), 1);
then check Setup > Apex Jobs and Manage Currencies > Manage Dated Exchange Rates.
Schedule it with scripts/apex/schedule.apex.
MSG
