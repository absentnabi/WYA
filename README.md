# WYA

WYA (“Where You At”) is a native iOS companion for getting around New York on the MTA. It lists nearby subway, local bus, and express bus stops with the next arrivals, and it plans a trip from plain language with walking included in the total.

The arrival clocks come from official feeds. The bundled stop index is built from MTA GTFS static files. A language model, if you add a key, only narrates a plan that the app already calculated. It does not invent departure times.

## Open the project

You need Xcode 15 or newer and the iOS 17 SDK.

1. Open `WYA.xcodeproj`.
2. Let Xcode resolve the local `WYACore` Swift package (no external packages).
3. Pick the WYA scheme and an iPhone simulator, or your phone.
4. Run.

The shared scheme simulates location at Union Square (`WYA/Resources/UnionSquare.gpx`). If the simulator is still elsewhere, choose Features > Location > Union Square, or tap the location menu in Nearby and choose **Preview Union Square**.

On a device, select your team under Signing & Capabilities. The bundle id is `dev.brandonortiz.wya`.

## Keys

Copy the template and fill in only what you have. The real file is gitignored.

```bash
cp Secrets.example.plist Secrets.plist
```

A build script copies `Secrets.plist` into the app if it exists, otherwise it copies the example. Empty keys are safe. The app labels sample arrivals instead of pretending they are live.

| Key | Used for |
| --- | --- |
| `MTASubwayAPIKey` | Subway GTFS-realtime. Sent as the `x-api-key` header. |
| `MTABusAPIKey` | MTA Bus Time SIRI stop monitoring. |
| `LLMAPIKey` | Trip narration and looser wording for “from here to …”. |
| `LLMBaseURL` | OpenAI-compatible base URL. Default `https://api.openai.com/v1`. |
| `LLMModel` | Default `gpt-4o-mini`. |

### MTA subway realtime

Create a key at [api.mta.info](https://api.mta.info/). Feeds are the official GTFS-realtime protobuf endpoints, for example:

`https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs`

WYA requests only the line groups that serve the stops on screen (1–7 and S, ACE, BDFM, G, JZ, NQRW, L, Staten Island Railway).

### MTA Bus Time

Request a free key from [MTA Bus Time developers](https://bustime.mta.info/developers). Arrivals use SIRI Stop Monitoring JSON:

`https://bustime.mta.info/api/siri/stop-monitoring.json`

The stop id is the GTFS id from the official bus files. Documentation: [SIRI Stop Monitoring](https://bt.mta.info/developers/siri/stop-monitoring/).

### A cheap language model

Any OpenAI-compatible chat completions endpoint works. Two inexpensive options:

- OpenAI: base `https://api.openai.com/v1`, model `gpt-4o-mini`
- Gemini Flash: base `https://generativelanguage.googleapis.com/v1beta/openai`, model `gemini-2.5-flash`

The model may extract a place name from a messy sentence. The itinerary itself (walk, wait, ride, total) is computed from the stop index, optional live arrivals, and a walking estimate. If the model is down or the key is blank, you still get that breakdown and a plain-language summary written by the app.

## What you can do without keys

- Nearby stops, sorted by distance, from the bundled index. Works offline after the first install.
- Sample countdowns, clearly labeled, so the arrival board is not empty.
- A trip plan with walk, typical wait, and scheduled ride time. Wait is labeled as a typical estimate, not a live train.
- Last live arrivals are cached and shown with the time they were saved if the network drops.

Location permission is When In Use. If you deny it, Nearby explains that and still offers the Union Square preview. Planning can also start from a named place (“from Grand Central to Yankee Stadium”) without GPS.

## Tests

Logic tests live in the `WYACore` package and also in the WYATests target.

```bash
cd WYACore
swift test
```

They cover GTFS-realtime parsing (including the difference between `StopTimeEvent.time` and `delay`), SIRI JSON, walking distance, trip duration math, direct rides, one transfer, and a check that the bundled index can ride the 4, 5, or 6 from Union Square to Grand Central.

## Refresh the stop index

The app ships a compact index derived from official static GTFS, not a scrape. To rebuild it:

```bash
mkdir -p /tmp/mta-gtfs
cd /tmp/mta-gtfs
curl -fsSL -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip
curl -fsSL -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_m.zip
curl -fsSL -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_bx.zip
curl -fsSL -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_b.zip
curl -fsSL -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_q.zip
curl -fsSL -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_si.zip
curl -fsSL -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_busco.zip
cd -
python3 Scripts/build_transit_index.py --gtfs /tmp/mta-gtfs --out WYA/Resources/transit-index.json
```

Those URLs are the feeds linked from [MTA developer resources](https://www.mta.info/developers). Use of the data is subject to the [MTA developer terms](https://www.mta.info/developers/terms-and-conditions). WYA does not ship MTA logos or the official map.

## How it is put together

`WYACore` is Foundation-only so it can be tested on a Mac or in CI without a simulator:

- `TransitCatalog` loads the bundled index and finds nearby stops. Subway stations that share a name inside one complex (Union Square, Times Square, Grand Central) are shown once.
- `GTFSRTParser` reads subway TripUpdates from the protobuf wire format and keeps absolute arrival times.
- `SIRIParser` reads Bus Time stop monitoring.
- `TripEstimator` searches direct rides and one transfer. Ride time comes from a typical weekday trip in the GTFS. Wait is the next live arrival when one was passed in, otherwise a typical wait (3 min subway, 7 min local bus, 12 min express).
- Walking time defaults to distance × 1.25 street factor at 1.3 m/s. The app replaces those walk legs with MapKit walking directions when the request succeeds.

The SwiftUI app (`WYA/`) requests location, calls the feeds, caches arrivals, geocodes places with MapKit, and optionally asks the model to narrate.

Nearby is the arrival board. Plan is a request box: the numbered breakdown stays on screen even when a model writes the paragraph under it.

## Limits of this version

- One transfer, not a full multi-seat journey planner.
- AirTrain, LIRR, Metro-North, and NYC Ferry are not in the index.
- Express buses are the BM, BxM, QM, SIM, and X routes, plus anything the GTFS labels express.
- A missing or rejected API key never gets filled in with made-up live times. You get a sample board or a typical wait, and the screen says which.
