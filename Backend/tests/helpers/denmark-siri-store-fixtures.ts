export const siriClock = "2026-11-16T21:11:20.000Z";
export const siriMilliseconds = Date.parse(siriClock);
export function siriAt(offsetMilliseconds: number): string {
  return new Date(siriMilliseconds + offsetMilliseconds).toISOString();
}

export function siriCall(stopPointRef = "8601309", aimed = siriAt(600_000), expected = siriAt(660_000)): string {
  return `<EstimatedCall><StopPointRef>${stopPointRef}</StopPointRef><AimedDepartureTime>${aimed}</AimedDepartureTime><ExpectedDepartureTime>${expected}</ExpectedDepartureTime></EstimatedCall>`;
}

export function siriJourney(options: {
  reference?: string; trainNumber?: string; observedAt?: string; serviceDate?: string; calls?: string[];
} = {}): string {
  const { reference = "2360-8600026100000", trainNumber = "2360", observedAt = siriClock,
    serviceDate = "2026-11-16", calls = [siriCall()] } = options;
  return `<EstimatedVehicleJourney><RecordedAtTime>${observedAt}</RecordedAtTime><FramedVehicleJourneyRef><DataFrameRef>${serviceDate}</DataFrameRef><DatedVehicleJourneyRef>${reference}</DatedVehicleJourneyRef></FramedVehicleJourneyRef><OperatorRef>DSB</OperatorRef><Monitored>true</Monitored><TrainNumbers><TrainNumberRef>${trainNumber}</TrainNumberRef></TrainNumbers><EstimatedCalls>${calls.join("")}</EstimatedCalls><IsCompleteStopSequence>false</IsCompleteStopSequence></EstimatedVehicleJourney>`;
}

export function siriDelivery(journeys = [siriJourney()], responseTimestamp = siriClock): string {
  return `<Siri xmlns="http://www.siri.org.uk/siri"><ServiceDelivery><ResponseTimestamp>${responseTimestamp}</ResponseTimestamp><ProducerRef>RKRP_RTH</ProducerRef><EstimatedTimetableDelivery><EstimatedJourneyVersionFrame>${journeys.join("")}</EstimatedJourneyVersionFrame></EstimatedTimetableDelivery></ServiceDelivery></Siri>`;
}

interface MemoryTransaction {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
  delete(keys: string[]): Promise<number>;
}

/** Serializable copy-on-commit storage; a failed callback discards every write. */
export class MemorySiriStorage {
  values = new Map<string, unknown>();
  putCount = 0;
  deleteCount = 0;
  failWrites = false;
  private queue: Promise<void> = Promise.resolve();

  async transaction<T>(work: (transaction: MemoryTransaction) => Promise<T>): Promise<T> {
    const previous = this.queue;
    let release!: () => void;
    this.queue = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    const next = structuredClone(this.values);
    try {
      const result = await work({
        get: async <V>(key: string) => structuredClone(next.get(key)) as V | undefined,
        put: async (key, value) => {
          if (this.failWrites) throw new Error("storage write failed");
          this.putCount++;
          next.set(key, structuredClone(value));
        },
        delete: async (keys) => keys.reduce((count, key) => {
          const deleted = Number(next.delete(key)); this.deleteCount += deleted; return count + deleted;
        }, 0),
      });
      this.values = next;
      return result;
    } finally { release(); }
  }
}
