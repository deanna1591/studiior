/**
 * Reference data for the studio identity fields, with no package behind it.
 *
 * Timezones and currency codes come from the platform's own ICU data via
 * Intl.supportedValuesOf. Names come from Intl.DisplayNames. The only things
 * hardcoded here are the ISO 3166-1 country codes, which no Intl API
 * enumerates, and a country -> currency default, which is a business
 * convention rather than a standard.
 */

/** ISO 3166-1 alpha-2. The list no Intl API will give you. */
const COUNTRY_CODES =
  "AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ " +
  "CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO " +
  "FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE " +
  "JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO " +
  "MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW " +
  "PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM " +
  "TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW";

/**
 * Country -> its usual currency. Not a standard, which is why it is written
 * out: ISO publishes both lists but not the mapping, and the mapping has
 * judgement in it (Kosovo uses EUR without issuing it).
 *
 * A country not listed here simply leaves the currency alone rather than
 * guessing — the field stays whatever the operator last chose.
 */
const COUNTRY_CURRENCY: Record<string, string> = {
  AD:"EUR",AE:"AED",AL:"ALL",AM:"AMD",AR:"ARS",AT:"EUR",AU:"AUD",AZ:"AZN",
  BA:"BAM",BE:"EUR",BG:"BGN",BH:"BHD",BR:"BRL",BY:"BYN",
  CA:"CAD",CH:"CHF",CL:"CLP",CN:"CNY",CO:"COP",CR:"CRC",CY:"EUR",CZ:"CZK",
  DE:"EUR",DK:"DKK",DO:"DOP",DZ:"DZD",EC:"USD",EE:"EUR",EG:"EGP",ES:"EUR",
  FI:"EUR",FR:"EUR",GB:"GBP",GE:"GEL",GR:"EUR",GT:"GTQ",
  HK:"HKD",HR:"EUR",HU:"HUF",ID:"IDR",IE:"EUR",IL:"ILS",IN:"INR",IS:"ISK",IT:"EUR",
  JO:"JOD",JP:"JPY",KE:"KES",KR:"KRW",KW:"KWD",KZ:"KZT",
  LB:"LBP",LI:"CHF",LT:"EUR",LU:"EUR",LV:"EUR",MA:"MAD",MC:"EUR",MD:"MDL",
  ME:"EUR",MK:"MKD",MT:"EUR",MU:"MUR",MX:"MXN",MY:"MYR",
  NG:"NGN",NL:"EUR",NO:"NOK",NZ:"NZD",OM:"OMR",PA:"PAB",PE:"PEN",PH:"PHP",
  PK:"PKR",PL:"PLN",PT:"EUR",QA:"QAR",RO:"RON",RS:"RSD",RU:"RUB",
  SA:"SAR",SE:"SEK",SG:"SGD",SI:"EUR",SK:"EUR",SM:"EUR",TH:"THB",TN:"TND",
  TR:"TRY",TW:"TWD",UA:"UAH",US:"USD",UY:"UYU",VA:"EUR",VN:"VND",ZA:"ZAR",
};

export type Option = { value: string; label: string };

function displayName(type: "region" | "currency", code: string): string {
  try {
    return new Intl.DisplayNames(["en"], { type }).of(code) ?? code;
  } catch {
    return code;
  }
}

export function countryOptions(): Option[] {
  return COUNTRY_CODES.split(" ")
    .map((code) => ({ value: code, label: `${displayName("region", code)} (${code})` }))
    .sort((a, b) => a.label.localeCompare(b.label));
}

export function currencyOptions(): Option[] {
  const codes: string[] =
    typeof Intl.supportedValuesOf === "function"
      ? Intl.supportedValuesOf("currency")
      : Object.values(COUNTRY_CURRENCY);
  return [...new Set(codes)]
    .map((code) => ({ value: code, label: `${code} — ${displayName("currency", code)}` }))
    .sort((a, b) => a.value.localeCompare(b.value));
}

export function currencyForCountry(country: string): string | null {
  return COUNTRY_CURRENCY[country.toUpperCase()] ?? null;
}

/** "+02:00" for a zone right now — DST included, because it is computed. */
export function utcOffset(timeZone: string, at: Date = new Date()): string {
  try {
    const parts = new Intl.DateTimeFormat("en-GB", { timeZone, timeZoneName: "longOffset" })
      .formatToParts(at);
    const name = parts.find((p) => p.type === "timeZoneName")?.value ?? "";
    return name.replace(/^GMT/, "") || "+00:00";
  } catch {
    return "";
  }
}

/**
 * IANA zones from the platform. Labelled with the city and the offset in force
 * today, since "Europe/Prague" alone does not tell an operator whether they
 * picked the right one.
 */
export function timezoneOptions(at: Date = new Date()): Option[] {
  let zones: string[] = [];
  try {
    if (typeof Intl.supportedValuesOf === "function") {
      zones = Intl.supportedValuesOf("timeZone");
    }
  } catch {
    zones = [];
  }
  if (zones.length === 0) {
    // Older runtimes: at minimum offer the one the operator is already in.
    const own = browserTimeZone();
    zones = [...new Set([own, "UTC", "Europe/London", "Europe/Prague", "America/New_York"])];
  }
  return zones
    .map((zone) => {
      const city = zone.split("/").pop()?.replace(/_/g, " ") ?? zone;
      const off = utcOffset(zone, at);
      return { value: zone, label: `${city} — ${zone} (UTC${off})` };
    })
    .sort((a, b) => a.label.localeCompare(b.label));
}

export function browserTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
}
