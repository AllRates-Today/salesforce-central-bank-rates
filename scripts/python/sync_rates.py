#!/usr/bin/env python3
"""Load one official exchange rate table from AllRatesToday into Salesforce, from outside Salesforce.

Runs anywhere you can schedule a job (cron, a CI schedule, a serverless timer). It writes:
  --mode dated   DatedConversionRate rows (Advanced Currency Management), StartDate = the bank's rate_date
  --mode static  CurrencyType.ConversionRate (orgs without Advanced Currency Management)

Salesforce auth: OAuth 2.0 client credentials flow (an External Client App or Connected App with
"Enable Client Credentials Flow" and a run-as user allowed to manage currencies).

Environment:
  ALLRATES_API_KEY      AllRatesToday key (art_live_...)
  SF_DOMAIN             https://yourcompany.my.salesforce.com
  SF_CLIENT_ID          consumer key
  SF_CLIENT_SECRET      consumer secret

Examples:
  python sync_rates.py --bank ecb                                  # latest ECB table, dated rates
  python sync_rates.py --bank rbi --mode static                    # latest RBI table, static rates
  python sync_rates.py --bank ecb --from 2026-01-01 --to 2026-11-25  # historical load (weekdays)
  python sync_rates.py --bank ecb --dry-run                        # print, write nothing

Requires: pip install requests
"""
import argparse
import datetime as dt
import os
import sys
from decimal import Decimal, ROUND_HALF_UP

import requests

API = "https://allratestoday.com/api/v1/central-bank"
SF_VERSION = "v62.0"
UA = "salesforce-central-bank-rates/1.0 (+https://allratestoday.com/docs/integrations/salesforce/)"


def fetch_table(bank, day="latest"):
    r = requests.get(
        f"{API}/{bank}/{day}",
        headers={"Authorization": f"Bearer {os.environ['ALLRATES_API_KEY']}", "User-Agent": UA},
        timeout=30,
    )
    r.raise_for_status()
    return r.json()


def per_home(table, rate_type=None):
    """{currency: units per 1 unit of the publisher's home currency}; value = quote per 1 base."""
    rows, seen, counts = [], set(), {}
    for row in table["rates"]:
        if rate_type and row["type"] != rate_type:
            continue
        pair = (row["base"].upper(), row["quote"].upper())
        if pair in seen or not row["value"] or row["value"] <= 0:
            continue
        seen.add(pair)
        rows.append((pair[0], pair[1], Decimal(str(row["value"]))))
        for c in pair:
            counts[c] = counts.get(c, 0) + 1
    if not rows:
        raise SystemExit("No usable rows in the table" + (f" of type {rate_type!r}" if rate_type else ""))
    home = max(counts, key=counts.get)
    out = {home: Decimal(1)}
    for base, quote, value in rows:
        if base == home:
            out.setdefault(quote, value)
        elif quote == home:
            out.setdefault(base, Decimal(1) / value)
    return home, out


class Salesforce:
    def __init__(self):
        self.domain = os.environ["SF_DOMAIN"].rstrip("/")
        tok = requests.post(
            f"{self.domain}/services/oauth2/token",
            data={
                "grant_type": "client_credentials",
                "client_id": os.environ["SF_CLIENT_ID"],
                "client_secret": os.environ["SF_CLIENT_SECRET"],
            },
            timeout=30,
        )
        tok.raise_for_status()
        self.s = requests.Session()
        self.s.headers.update({"Authorization": f"Bearer {tok.json()['access_token']}", "Content-Type": "application/json"})
        self.base = f"{self.domain}/services/data/{SF_VERSION}"

    def query(self, soql):
        r = self.s.get(f"{self.base}/query", params={"q": soql}, timeout=60)
        r.raise_for_status()
        return r.json()["records"]

    def write(self, method, path, body):
        r = self.s.request(method, f"{self.base}/sobjects/{path}", json=body, timeout=30)
        if r.status_code >= 300:
            raise RuntimeError(f"{method} {path}: HTTP {r.status_code} {r.text[:300]}")


def sync(sf, bank, day, mode, rate_type, dry_run, done_dates):
    table = fetch_table(bank, day)
    rate_date = table["rate_date"]
    if mode == "dated" and rate_date in done_dates:
        return f"{day}: table {rate_date} already written"
    done_dates.add(rate_date)
    home, ph = per_home(table, rate_type)

    currencies = sf.query("SELECT Id, IsoCode, IsCorporate FROM CurrencyType WHERE IsActive = true")
    corporate = next(c["IsoCode"] for c in currencies if c["IsCorporate"])
    if corporate not in ph:
        raise SystemExit(f"{bank} table (home {home}) has no rate for the corporate currency {corporate}")
    rates = {
        c["IsoCode"]: (ph[c["IsoCode"]] / ph[corporate]).quantize(Decimal("0.000001"), ROUND_HALF_UP)
        for c in currencies
        if not c["IsCorporate"] and c["IsoCode"] in ph
    }
    if dry_run:
        return f"{day}: table {rate_date} (home {home}, corporate {corporate}) " + ", ".join(f"{k}={v}" for k, v in sorted(rates.items()))

    ins = upd = 0
    if mode == "dated":
        codes = ",".join(f"'{c}'" for c in rates)
        existing = {
            r["IsoCode"]: r["Id"]
            for r in sf.query(f"SELECT Id, IsoCode FROM DatedConversionRate WHERE StartDate = {rate_date} AND IsoCode IN ({codes})")
        } if rates else {}
        for code, rate in rates.items():
            if code in existing:
                sf.write("PATCH", f"DatedConversionRate/{existing[code]}", {"ConversionRate": float(rate)})
                upd += 1
            else:
                sf.write("POST", "DatedConversionRate", {"IsoCode": code, "ConversionRate": float(rate), "StartDate": rate_date})
                ins += 1
    else:
        ids = {c["IsoCode"]: c["Id"] for c in currencies}
        for code, rate in rates.items():
            sf.write("PATCH", f"CurrencyType/{ids[code]}", {"ConversionRate": float(rate)})
            upd += 1
    stale = " (API flags the table as stale)" if table.get("stale") else ""
    return f"{day}: table {rate_date}: {ins} inserted, {upd} updated{stale}"


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--bank", required=True, help="ecb, boe, rbi, hmrc, ... (see allratestoday.com/central-bank-rates-api/institutions/)")
    p.add_argument("--mode", choices=["dated", "static"], default="dated")
    p.add_argument("--rate-type", help="only rows of this type, e.g. reference, buying, selling")
    p.add_argument("--from", dest="date_from", help="historical load start, YYYY-MM-DD (dated mode)")
    p.add_argument("--to", dest="date_to", help="historical load end, YYYY-MM-DD (default today)")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()

    if a.date_from:
        if a.mode != "dated":
            sys.exit("A historical load needs --mode dated")
        d, end = dt.date.fromisoformat(a.date_from), dt.date.fromisoformat(a.date_to) if a.date_to else dt.date.today()
        days = []
        while d <= end:
            if d.weekday() < 5:
                days.append(d.isoformat())
            d += dt.timedelta(days=1)
    else:
        days = ["latest"]

    sf = Salesforce()
    done = set()
    for day in days:
        print(sync(sf, a.bank.lower(), day, a.mode, a.rate_type, a.dry_run, done))


if __name__ == "__main__":
    main()
