// Mihomo reports cumulative bytes. Chart samples use MiB/s throughout.
const mib = 1024 * 1024;

/** @param {{time:number,down:number,up:number}|null} previous @param {{time:number,down:number,up:number}} current */
export function trafficRates(previous, current) {
  if (!previous || current.time <= previous.time || current.down < previous.down || current.up < previous.up) return null;
  const seconds = (current.time - previous.time) / 1000;
  return {
    down: (current.down - previous.down) / seconds / mib,
    up: (current.up - previous.up) / seconds / mib,
  };
}

/** @param {number} rate */
export function formatRate(rate) {
  if (rate <= 0) return '0 B/s';
  if (rate >= 1) return `${Number(rate.toFixed(2))} MB/s`;
  if (rate >= 1 / 1024) return `${Number((rate * 1024).toFixed(1))} KB/s`;
  return rate * mib < 1 ? '<1 B/s' : `${Math.round(rate * mib)} B/s`;
}
