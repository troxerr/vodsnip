import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';

const [, , executable, ffmpegArg, ffprobeArg] = process.argv;
assert(executable, 'Usage: node tools/smoke.mjs path/to/vodsnip.exe [ffmpeg] [ffprobe]');
const app = resolve(executable);
const ffmpeg = ffmpegArg || join(dirname(app), 'bin', 'ffmpeg.exe');
const ffprobe = ffprobeArg || join(dirname(app), 'bin', 'ffprobe.exe');
const root = await mkdtemp(join(tmpdir(), 'Vodsnip café '));
const fixture = join(root, 'fixture.mp4');
let server;

try {
  execFileSync(ffmpeg, [
    '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=30',
    '-t', '16', '-c:v', 'mpeg4', '-g', '30', '-q:v', '3', '-movflags', '+faststart', fixture,
  ]);
  const media = await readFile(fixture);
  let slow = false;
  server = createServer((req, res) => {
    if (req.url !== '/fixture.mp4') {
      res.writeHead(404).end();
      return;
    }
    const range = req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
    const start = range ? Number(range[1]) : 0;
    const end = range?.[2] ? Math.min(Number(range[2]), media.length - 1) : media.length - 1;
    if (start > end) {
      res.writeHead(416, { 'Content-Range': `bytes */${media.length}` }).end();
      return;
    }
    const body = media.subarray(start, end + 1);
    const headers = {
      'Content-Type': 'video/mp4', 'Content-Length': body.length, 'Accept-Ranges': 'bytes',
    };
    if (range) headers['Content-Range'] = `bytes ${start}-${end}/${media.length}`;
    res.writeHead(range ? 206 : 200, headers);
    if (req.method === 'HEAD') res.end();
    else if (!slow) res.end(body);
    else {
      // Give yt-dlp enough data to report progress, then hold the connection until it exits.
      res.write(body.subarray(0, 64 * 1024));
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const url = `http://127.0.0.1:${server.address().port}/fixture.mp4`;

  async function run(mode, auto) {
    const dir = await mkdtemp(join(root, mode + ' '));
    const child = spawn(app, [], {
      env: {
        ...process.env, VODSNIP_URL: url, VODSNIP_MODE: mode,
        VODSNIP_AUTO: auto, VODSNIP_SMOKE_DIR: dir,
      },
      stdio: 'ignore',
    });
    const exited = once(child, 'exit');
    exited.catch(() => {});
    try {
      const deadline = Date.now() + 90_000;
      while (Date.now() < deadline) {
        const result = await readFile(join(dir, 'result.json'), 'utf8').catch((error) => {
          if (error.code !== 'ENOENT') throw error;
        });
        if (result) return { ...JSON.parse(result), dir };
        const exit = await Promise.race([exited, delay(200, null)]);
        if (exit) throw new Error(`Vodsnip exited before reporting its result: ${exit}`);
      }
      throw new Error(`Vodsnip did not report a result for ${auto}.`);
    } finally {
      child.kill();
      await exited;
    }
  }

  const saved = await run('range', 'download');
  assert.equal(saved.event, 'done', JSON.stringify(saved));
  const duration = Number(execFileSync(ffprobe, [
    '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', saved.file,
  ], { encoding: 'utf8' }).trim());
  assert(Math.abs(duration - 10) <= 0.5, `Expected a 10-second clip, got ${duration}`);
  console.log(`Installed app saved a ${duration}-second clip.`);

  slow = true;
  const cancelled = await run('entire', 'download,cancel-on-progress');
  assert.equal(cancelled.event, 'cancelled', JSON.stringify(cancelled));
  assert(!(await readdir(cancelled.dir)).some((name) => name.endsWith('.mp4')));
  console.log('Installed app reported cancellation without producing a finished video.');
} finally {
  server?.closeAllConnections();
  server?.close();
  await rm(root, { recursive: true, force: true });
}
