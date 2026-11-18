/** Rhea's optional native Kerberos module is not used by this OAuth-only consumer.
 * Explicitly reject it instead of shipping a native dependency into Workers. */
export async function initializeClient(): Promise<never> {
  throw new Error("Denmark Service Bus supports OAuth TokenCredential only");
}
