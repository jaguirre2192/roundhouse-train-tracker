# Roundhouse backend

Use Node 22 or later. Install the versions in the lockfile with `npm ci`. The Worker and PostgreSQL development commands are in the [project README](../README.md). Tests use local, synthetic inputs. Some adapters require separate operator permission and account credentials for live service. Runtime data and geographic assets have their own [terms and notices](../THIRD_PARTY_NOTICES.md).

The public Wrangler files are local development templates. They contain no custom route, cron schedule, production signing identifiers or account bindings. For a fork, choose your own Worker names, contact address, email domain, team IDs and rate-limiter namespace. The simulator defaults to `http://127.0.0.1:8787`; a device needs an accessible backend. In `.dev.vars`, set random values of at least 32 characters for `AUTH_TOKEN_ENCRYPTION_KEY`, `TICKET_FORWARDING_SECRET` and `JOURNEY_TOKEN_SECRET` for the corresponding features.

The optional maintenance consumers only publish to pinned destinations. Before enabling one yourself, replace the `roundhouse-api.example.invalid` destination in its publisher, configure the matching receiving Worker, and supply your own shared secret. Configure Denmark's regional watchdog independently if needed. Update the public contact values in `src/cloudflare/public-pages.ts` and the Transitous client contact in `src/providers/transitous-client.ts`. The Worker’s public information pages also require your Apple application identifiers for universal links. Runtime signing secrets and provider keys belong in your local environment or platform secret store.

For Chepe Express boards and trip snapshots, set `CHEPE_TIMETABLE_JSON` to a schedule you may use. The [synthetic example](tests/fixtures/chepe-sample.ts) shows the format and contains invented test times. Station discovery works without a timetable. The adapter checks your identifying phrases against the [operator publication](https://chepe.mx/tren/horarios/) before returning scheduled times.

For a custom account backend, set your HTTPS host in the app’s trusted callback hosts and associated domains as well as `TRAIN_TRACKER_API_BASE_URL`.
