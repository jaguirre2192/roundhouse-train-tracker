# Roundhouse: Train Tracker

Roundhouse is a free iPhone, iPad and Apple Watch app for following passenger trains. Search for a train or import your ticket and follow the stops, platform changes and delays the operator reports. The map distinguishes an observed train position from a timetable estimate. Coverage varies by route and operator. [Roundhouse website](https://gettraintracker.com)

Calendar suggestions, ticket forwarding, delay alerts and automatic Live Activities are free. The optional one-time tip in Settings helps cover hosting. A tip has no effect on the data a rider receives or the features they can use.

## Build the app

Use Xcode 27.1 or later with the iOS and watchOS SDKs. Open `TrainTracker.xcodeproj`, select the **TrainTracker** scheme, choose an iPhone or iPad simulator, and run. The XcodeGen specification is in `project.yml`. If you change it, run `xcodegen generate`. Physical-device signing, push notifications and operator feeds require the corresponding developer accounts or credentials.

```sh
swift test --package-path Packages/TrainTrackerCore
xcodebuild -project TrainTracker.xcodeproj -scheme TrainTracker \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Run the backend

The backend contains the journey planner, provider adapters, ticket forwarding and alert watcher. It supports Cloudflare Workers and a Node/Postgres service. Provider credentials belong on the server. Use Node 22 or later and run the following from `Backend` to check the source locally.

```sh
npm ci
npm run typecheck
npm test
npm run typecheck:worker
npm run test:worker
```

For local Worker development use `npm run dev:worker`. For the Node/Postgres service, copy `.env.example` to `.env`, set a random `JOURNEY_TOKEN_SECRET` of at least 32 characters, run `docker compose up -d postgres`, then `npm run migrate` and `npm run dev`. Use your own HTTPS backend origin for a fork with the app build setting `TRAIN_TRACKER_API_BASE_URL`. Signing a production build and connecting to credentialed providers require your own configuration.

## Source and rail data

The Swift and TypeScript source is available under the [MIT License](LICENSE). Reuse of bundled rail data, provider marks and dependencies follows the [third-party notices](THIRD_PARTY_NOTICES.md). Operator permissions and service accounts belong to each operator of a backend.

International journey planning can use Transitous or your own compatible MOTIS service configured with `MOTIS_BASE_URL`. The public Transitous service supports noncommercial open-source projects and requests coordination for high-volume or automated traffic. Follow the usage policy and acknowledge the data suppliers in your own distribution. [Transitous usage policy](https://transitous.org/api/) · [Transitous sources](https://transitous.org/sources/) · [OpenStreetMap contributors](https://www.openstreetmap.org/copyright)
