import { initializeSchema } from "./schema.js";

/** Public provider reads must not open SQL merely to construct the singleton. */
export function watcherStorage(storage: DurableObjectStorage): DurableObjectStorage {
  let initialized = false;
  const ensureSchema = () => {
    if (initialized) return;
    initializeSchema(storage.sql);
    // A failed initialization must be retried after storage becomes available.
    initialized = true;
  };
  const sql = new Proxy(storage.sql, {
    get(target, property) {
      const value: unknown = Reflect.get(target, property, target);
      if (property === "exec") return (...arguments_: unknown[]) => {
        ensureSchema();
        return Reflect.apply(value as (...args: unknown[]) => unknown, target, arguments_);
      };
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return new Proxy(storage, {
    get(target, property) {
      if (property === "sql") return sql;
      const value: unknown = Reflect.get(target, property, target);
      // Initialize before opening a SQL transaction, preserving FK enforcement.
      if (property === "transactionSync") return (...arguments_: unknown[]) => {
        ensureSchema();
        return Reflect.apply(value as (...args: unknown[]) => unknown, target, arguments_);
      };
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}
