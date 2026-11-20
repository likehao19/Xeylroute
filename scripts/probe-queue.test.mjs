import assert from 'node:assert/strict';
import test from 'node:test';
import { runProbeQueue } from '../src/probe-queue.mjs';

test('starts eight probes immediately and refills slots while slower peers are still running', async () => {
  const started = [];
  const release = [];
  const jobs = Array.from({ length: 10 }, (_, i) => i);
  const done = runProbeQueue(jobs, 8, i => {
    started.push(i);
    return new Promise(resolve => { release[i] = resolve; });
  }, () => true);

  assert.deepEqual(started, jobs.slice(0, 8));
  release[5]();
  await Promise.resolve();
  assert.deepEqual(started, jobs.slice(0, 9));
  release[8]();
  await Promise.resolve();
  assert.deepEqual(started, jobs);
  release.forEach(resolve => resolve());
  await done;
});

test('lets in-flight probes settle without starting queued work after a scope change', async () => {
  let active = true;
  const started = [];
  await runProbeQueue([1, 2, 3, 4], 2, async i => {
    started.push(i);
    await Promise.resolve();
    active = false;
  }, () => active);
  assert.deepEqual(started, [1, 2]);
});
