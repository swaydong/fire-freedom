# Third-party notices

F.I.R.E source code is licensed under [MIT](LICENSE). Third-party software and data retain their own terms. Mentioning a service does not imply affiliation or endorsement.

## Bundled software

The versions below are locked in `Package.resolved`. The full license texts in `ThirdPartyLicenses/` are also included as resources in both app targets. Preserve them when redistributing a compiled app.

| Component | Version | License text |
| --- | --- | --- |
| [CoreXLSX](https://github.com/CoreOffice/CoreXLSX) | 0.14.2 | [Apache-2.0](ThirdPartyLicenses/CoreXLSX-Apache-2.0.txt) |
| [XMLCoder](https://github.com/CoreOffice/XMLCoder) | 0.14.0 | [MIT, Shawn Moore and XMLCoder contributors](ThirdPartyLicenses/XMLCoder-MIT.txt) |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | [MIT, Thomas Zoechling](ThirdPartyLicenses/ZIPFoundation-MIT.txt) |

CoreXLSX 0.14.2 does not include a separate upstream NOTICE file. Its source is fetched as a dependency and is not modified or vendored here.

## Optional tools and local data

- [XcodeGen](https://github.com/yonaskolb/XcodeGen/blob/master/LICENSE) is an external MIT-licensed build tool, not bundled in the apps.
- [AKShare](https://github.com/akfamily/akshare/blob/main/LICENSE) is an optional externally installed MIT-licensed Python package. Its providers have separate data terms. Installing it is not necessary for the local ledger or FIRE calculations.
- [FinanceDatabase](https://github.com/JerBouma/FinanceDatabase/blob/main/LICENSE) is MIT-licensed, copyright 2023 Jeroen Bouma. This public release includes the local-directory format and loader, but an empty bundled directory: it redistributes no FinanceDatabase records or HKEX overlays. When adding or distributing a dataset, retain its complete license and provenance; the code license does not license third-party data.
- Codex CLI, Apple SDKs and system frameworks are external prerequisites. They are not included under this project's MIT license. Codex access requires the user's own supported ChatGPT login and available usage.

## Runtime data services

This repository contains service clients, not cached personal account data or a redistributable market-data feed.

- **ECB:** Source: ECB statistics. Currency conversions are *derived from ECB reference rates* by dividing the target-currency-per-EUR rate by the source-currency-per-EUR rate. These cross rates and freshness labels are project calculations, not an ECB endorsement. [ECB reuse policy](https://www.ecb.europa.eu/stats/ecb_statistics/governance_and_quality_framework/html/usage_policy.en.html).
- **World Bank:** World Development Indicators, `FP.CPI.TOTL.ZG` (Inflation, consumer prices, annual %), China; underlying source as identified by the service: IMF International Financial Statistics. F.I.R.E derives a planning reference from recent annual observations; it is not a forecast published by the World Bank. World Bank datasets are generally CC BY 4.0 unless otherwise specified; check the indicator's current third-party restrictions. [Dataset terms](https://www.worldbank.org/ext/en/legal/terms-conditions/datasets).
- **ChinaBond / Ministry of Finance yield curve:** The app reads the ten-year government bond yield as a planning reference. No market-data redistribution license is granted here. Review provider permission and terms before distributing a commercial service using this endpoint. [Source page](https://yield.chinabond.com.cn/cbweb-czb-web/czb/historyQuery).
- **OpenFIGI:** Used for instrument identity lookup. FIGI identifiers and related data are subject to the [OpenFIGI terms](https://www.openfigi.com/docs/terms-of-service), including trademark restrictions. API availability and rate limits apply independently of this code's license. API keys, if configured, belong in the user's environment and must not be committed.
- Other instrument-verification endpoints are runtime sources; availability, usage terms and data accuracy remain provider-dependent. The app requires confirmation when identity cannot be uniquely verified.

## Artwork and test fixtures

The app icon was generated for this project with an AI image tool. It contains no imported photo or third-party logo. Project-created artwork is offered under the project license to the extent the contributors hold rights in it; no exclusive copyright in AI output is claimed.

Public test fixtures are synthetic. They are not a person's ledger, portfolio or investment recommendations.
