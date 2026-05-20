# wisa_api test fixtures

These CSV files are **synthetic samples** that mirror the column shape of
each WISA `SMA*` query response. They live here so the connector's
record-and-replay tests can run without a live WISA host.

To regenerate from real production data: capture the base64-decoded CSV
body of each query's SOAP response, redact every PII column (`NAAM`,
`VOORNAAM`, `RIJKSREGISTERNR`, address fields, `WISAID`, `STAMBOEKNUMMER`,
…), and overwrite the matching `*.csv` file. The connector tests will
exercise whatever rows they find.

| File                  | Query        | Columns                                                                                                          |
| --------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------- |
| `sma_get_inst.csv`    | `SMAGetInst` | `ID,NAME,DESCRIPTION` (note: legacy swaps NAME and DESCRIPTION on the model)                                     |
| `sma_sync_lln.csv`    | `SmaSyncLln` | `KLAS,KLASGROEP,NAAM,VOORNAAM,ROEPNAAM,GEBOORTEDATUM,WISAID,STAMBOEKNUMMER,GESLACHT,RIJKSREGISTERNR,GEBOORTEPLAATS,NATIONALITEIT,STRAAT,STRAATNR,BUSNR,POSTCODE,WOONPLAATS,KLASWIJZIGING` |
| `sma_sync_per.csv`    | `SmaSyncPer` | `CODE,WISAID,FAMILIENAAM,VOORNAAM`                                                                               |
| `sync_klas.csv`       | `SyncKlas`   | `KLAS,KLASGROEP,OMSCHRIJVING,ADMINGROEP,INSTELLINGSNUMMER`                                                       |
| `sma_test_con.csv`    | `SMATestCon` | One-line connectivity probe; any non-empty body counts as success.                                               |
