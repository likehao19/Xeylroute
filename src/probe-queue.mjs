// Workers share the iterator so a slow probe occupies only its own slot.
/**
 * @template T
 * @param {T[]} items
 * @param {number} concurrency
 * @param {(item: T) => Promise<void>} probe
 * @param {() => boolean} active
 */
export async function runProbeQueue(items, concurrency, probe, active) {
  const pending = items.values();
  async function worker() {
    while (active()) {
      const next = pending.next();
      if (next.done) return;
      await probe(next.value);
    }
  }
  await Promise.all(Array.from({ length: Math.min(items.length, concurrency) }, worker));
}
