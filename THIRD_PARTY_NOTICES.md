# Third-party notices

The MIT license in this repository applies to Roundhouse’s own software. The data, provider branding, libraries and platform frameworks below retain their respective terms. Distribution of the code grants no API credentials or special access to a rail feed.

## Bundled geographic and station data

| Material | Source and attribution | How Roundhouse uses it |
| --- | --- | --- |
| Canadian rail route shapes | VIA Rail Canada. Contains information licensed under the Open Government Licence – Canada. [VIA Rail developer resources](https://www.viarail.ca/en/developer-resources) · [Open Government Licence – Canada 2.0](https://open.canada.ca/en/open-government-licence-canada) | Selected VIA GTFS routes and coordinates, simplified and indexed for display. |
| U.S. passenger rail network | Federal Railroad Administration, Amtrak and the U.S. Department of Transportation, Bureau of Transportation Statistics. [National Transportation Atlas Database, Amtrak Routes](https://geodata.bts.gov/datasets/usdot::amtrak-routes/about) | Normalized route names and geometries from the federal public-domain layer. |
| Country boundaries | Made with Natural Earth. [Public domain terms](https://www.naturalearthdata.com/about/terms-of-use/) | Simplified and indexed country polygons. |
| Austrian rail stations | Datenquelle: [ÖBB-Infrastruktur AG](https://infrastruktur.oebb.at/de/). [Geo Netz](https://data.oebb.at/de/datensaetze~geo-netz~) · [CC BY 3.0 AT](https://creativecommons.org/licenses/by/3.0/at/) | Station identifiers, names and coordinates selected and converted to TypeScript. |
| Skåne rail services | Trafiklab and the contributing operators. [GTFS Regional](https://www.trafiklab.se/api/gtfs-datasets/gtfs-regional/) · [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | A dated index of static regional rail stops and trips. Live feeds have distinct terms. |
| New South Wales platforms | Transport for NSW. [Transport Open Data](https://opendata.transport.nsw.gov.au/) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | Selected and indexed platform numbers and parent stations from the NSW Trains GTFS stops file. |
| Western Australian stations | Public Transport Authority of Western Australia. The source data is available free of charge from [www.transperth.wa.gov.au](https://www.transperth.wa.gov.au/). [Spatial data terms](https://www.transperth.wa.gov.au/About/Spatial-Data-Access) | Selected Transwa stops from the published GTFS data. |

## Network data and maps

International journey queries may use [Transitous](https://transitous.org/), [its data suppliers](https://transitous.org/sources/) and © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright). Retain visible attribution and observe the [public API usage policy](https://transitous.org/api/). Other national and regional adapters require the relevant operator's own terms, attribution and, in some cases, approval. Runtime data remains subject to its source terms. Apple Maps attribution is supplied by MapKit.

## Artwork and software

Google’s G mark identifies the Google sign-in action and is subject to [Google’s branding guidelines](https://developers.google.com/identity/branding-guidelines). Apple product names, system symbols and SDKs are used under Apple’s terms. The Roundhouse name, logo and app icon identify the original project. The software license grants no trademark rights.

The backend fetches its open-source dependencies through npm. See `Backend/package.json`, `Backend/package-lock.json` and the individual packages’ distributed license files for the notices that accompany them. The [GTFS Realtime language bindings](https://github.com/MobilityData/gtfs-realtime-bindings/blob/master/LICENSE) use Apache-2.0.
