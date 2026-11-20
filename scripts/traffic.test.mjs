import test from 'node:test';
import assert from 'node:assert/strict';
import { trafficRates, formatRate } from '../src/traffic.mjs';

const first = {time: 1000, down: 3200, up: 600};
test('keeps low traffic visible in both directions and distinguishes an idle interval', () => {
  const sample = trafficRates(first, {time: 3000, down: 7296, up: 646});
  assert.equal(formatRate(sample.down), '2 KB/s');
  assert.equal(formatRate(sample.up), '23 B/s');
  assert.equal(formatRate(trafficRates(first, {...first, time: 4000}).down), '0 B/s');
  assert.equal(formatRate(0.25 / 1048576), '<1 B/s');
  assert.equal(formatRate(1.25), '1.25 MB/s');
});
test('waits for a baseline after resume or a counter reset', () => {
  assert.equal(trafficRates(null, first), null);
  assert.equal(trafficRates(first, first), null);
  assert.equal(trafficRates(first, {time: 2000, down: 0, up: 0}), null);
});
