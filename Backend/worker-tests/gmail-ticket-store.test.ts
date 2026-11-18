import { describe, expect, it, vi } from "vitest";
import { isRejectedGmailSubject } from "../src/gmail/gmail-parser.js";
import { GmailTicketStore } from "../src/gmail/gmail-ticket-store.js";

describe("GmailTicketStore reconciliation", () => {
  it("removes stale known non-tickets while preserving ticket confirmations", () => {
    const exec = vi.fn((query: string, ..._arguments: SqlStorageValue[]) => {
      if (query.startsWith("SELECT")) {
        return {
          toArray: () => [
            { message_id: "membership", subject: "Your Classique membership has been renewed" },
            { message_id: "terms", subject: "Updates to our Terms & Conditions" },
            { message_id: "ticket", subject: "Your train booking confirmation code" },
          ],
        };
      }
      return { toArray: () => [] };
    });
    const store = new GmailTicketStore({ exec } as unknown as SqlStorage);

    expect(store.removeMatchingSubjects("account-1", isRejectedGmailSubject)).toBe(2);
    const deleteCalls = exec.mock.calls.filter(([query]) => query.startsWith("DELETE"));
    expect(deleteCalls.map((call) => call[2])).toEqual(["membership", "terms"]);
  });
});
