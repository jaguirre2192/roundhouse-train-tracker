import { runInDurableObject } from "cloudflare:test";
import { initializeSchema } from "../src/cloudflare/schema.js";

/** Repository fixtures seed SQL directly; production now initializes it lazily. */
export const runInInitializedWatcher: typeof runInDurableObject = (stub, callback) =>
  runInDurableObject(stub, (instance, state) => {
    initializeSchema(state.storage.sql);
    return callback(instance, state);
  });
