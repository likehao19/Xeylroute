import fs from 'node:fs';
import path from 'node:path';

const hosts = [
  'baidu.com', 'google.com', 'bing.com', 'wikipedia.org', 'duckduckgo.com', 'zhihu.com',
  'bilibili.com', 'youtube.com', 'netflix.com', 'spotify.com', 'twitch.tv', 'music.apple.com',
  'github.com', 'stackoverflow.com', 'npmjs.com', 'chatgpt.com', 'claude.ai', 'huggingface.co',
  'feishu.cn', 'notion.so', 'slack.com', 'discord.com', 'reddit.com', 'weibo.com',
];
const dir = 'public/site-icons';
fs.mkdirSync(dir, { recursive: true });

function extFrom(type, url) {
  const value = (type || '').toLowerCase();
  if (value.includes('png')) return 'png';
  if (value.includes('jpeg') || value.includes('jpg')) return 'jpg';
  if (value.includes('svg')) return 'svg';
  if (value.includes('webp')) return 'webp';
  if (value.includes('icon')) return 'ico';
  if (value === 'application/octet-stream' && url.endsWith('.ico')) return 'ico';
  throw new Error('Unexpected icon content type: ' + value);
}

async function grab(url) {
  const res = await fetch(url, {
    redirect: 'follow',
    headers: { 'user-agent': 'RoutePilot-icon-fetch' },
    signal: AbortSignal.timeout(12000),
  });
  if (!res.ok) throw new Error(String(res.status));
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length < 80) throw new Error('too small ' + buf.length);
  return { buf, type: res.headers.get('content-type') || '', url: res.url };
}

for (const host of hosts) {
  const sources = [
    `https://${host}/favicon.ico`,
  ];
  let saved = false;
  for (const url of sources) {
    try {
      const { buf, type, url: finalUrl } = await grab(url);
      const ext = extFrom(type, finalUrl);
      fs.writeFileSync(path.join(dir, `${host}.${ext}`), buf);
      console.log('OK', host, ext, buf.length, type);
      saved = true;
      break;
    } catch (error) {
      console.log('MISS', host, url, error.message);
    }
  }
  if (!saved) console.log('FAIL', host);
}
