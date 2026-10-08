'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fsp = require('node:fs/promises');
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { spawnSync } = require('node:child_process');
const { MotionService, normalizeRequest, buildArgs, roundedMask } = require('../lib/motion.cjs');

const request = () => ({ job: 'test-job', format: 'mp4', card: 'Y2FyZA==', video: 'dmlkZW8=', videoName: 'source.mov', cardWidth: 864, cardHeight: 1152, well: { x: 120, y: 180, width: 600, height: 700, radius: 30 }, crop: { x: 0.1, y: 0.2, width: 0.8, height: 0.7 }, start: 1, span: 6, speed: 2, sound: true });

async function temp(t) {
  const base = path.resolve(__dirname, '../.test-tmp');
  await fsp.mkdir(base, { recursive: true });
  const dir = await fsp.mkdtemp(path.join(base, 'motion-'));
  t.after(() => fsp.rm(dir, { recursive: true, force: true }));
  return dir;
}

test('FFmpeg arguments retain full card, original crop, center cover, speed, rounded mask and sound', () => {
  const clip = normalizeRequest(request(), 10);
  const args = buildArgs(clip, { card: 'card', video: 'video', mask: 'mask', output: 'out' }, true);
  const graph = args[args.indexOf('-filter_complex') + 1];
  assert.match(graph, /scale=1440:1920/);
  assert.match(graph, /setpts=\(PTS-STARTPTS\)\/2/);
  assert.match(graph, /crop=w=iw\*0.8:h=ih\*0.7:x=iw\*0.1:y=ih\*0.2/);
  assert.match(graph, /force_original_aspect_ratio=increase/);
  assert.match(graph, /alphamerge/);
  assert.match(graph, /overlay=x=200:y=300/);
  assert.match(graph, /atempo=2/);
  assert.ok(args.includes('libx264') && args.includes('aac') && args.includes('yuv420p') && args.includes('+faststart'));
  assert.equal(clip.duration, 3);
  const gif = normalizeRequest({ ...request(), format: 'gif' }, 10);
  const gifArgs = buildArgs(gif, { card: 'c', video: 'v', mask: 'm', output: 'o' }, true);
  assert.match(gifArgs.join(' '), /scale=864:1152.*fps=15/);
  assert.match(gifArgs.join(' '), /palettegen.*paletteuse/);
  assert.ok(gifArgs.includes('-an') && !gifArgs.includes('aac'));
  const mask = roundedMask({ width: 20, height: 20, radius: 7 });
  const pixels = mask.subarray(mask.indexOf(Buffer.from('255\n')) + 4);
  assert.equal(pixels[0], 0);
  assert.equal(pixels[10 * 20 + 10], 255);
});

test('invalid settings reject instead of injecting filter syntax; duration fits source length', () => {
  assert.throws(() => normalizeRequest({ ...request(), speed: '1;movie=secret' }, 10), /无效/);
  assert.throws(() => normalizeRequest({ ...request(), well: { ...request().well, x: -5 } }, 10), /图片框/);
  assert.throws(() => normalizeRequest({ ...request(), crop: { x: 0.5, y: 0, width: 0.8, height: 1 } }, 10), /取景/);
  const short = normalizeRequest({ ...request(), start: 50 }, 2);
  assert.equal(short.start, 1.95);
  assert.ok(Math.abs(short.duration - 0.025) < 0.0001);
});

function fakeSpawn(calls, hang = false) {
  return (executable, args, options) => {
    calls.push({ executable, args, options });
    const child = new EventEmitter();
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.kill = () => { setImmediate(() => child.emit('close', null)); return true; };
    setImmediate(async () => {
      if (executable === 'probe') {
        child.stdout.end(JSON.stringify({ streams: [{ codec_type: 'video', width: 1920, height: 1080 }, { codec_type: 'audio' }], format: { duration: '10' } }));
        child.emit('close', 0);
      } else if (!hang) {
        await fsp.writeFile(args.at(-1), Buffer.from('encoded'));
        child.stdout.end('out_time_us=1500000\nprogress=continue\n');
        child.emit('close', 0);
      }
    });
    return child;
  };
}

test('fake encoder verifies process isolation, progress, returned data and cleanup', async (t) => {
  const dir = await temp(t);
  const calls = [];
  const progress = [];
  const service = new MotionService({ dataDir: dir, ffmpegPath: 'encode', ffprobePath: 'probe', spawn: fakeSpawn(calls), emit: (owner, detail) => progress.push({ owner, ...detail }) });
  t.after(() => service.dispose());
  const result = await service.render('window-1', request());
  assert.equal(Buffer.from(result.data, 'base64').toString(), 'encoded');
  assert.equal(result.width, 1440);
  assert.equal(result.height, 1920);
  assert.equal(result.duration, 3);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].options.shell, false);
  assert.equal(calls[1].options.windowsHide, true);
  assert.ok(progress.some((item) => item.owner === 'window-1' && item.progress === 0.5));
  assert.equal(progress.at(-1).progress, 1);
  assert.deepEqual(await fsp.readdir(path.join(dir, 'motion-export')), []);
});

test('cancellation is owner checked, terminates encoder and removes job files', async (t) => {
  const dir = await temp(t);
  const calls = [];
  const service = new MotionService({ dataDir: dir, ffmpegPath: 'encode', ffprobePath: 'probe', spawn: fakeSpawn(calls, true) });
  t.after(() => service.dispose());
  const pending = service.render('window-1', request());
  const rejection = assert.rejects(pending, { name: 'AbortError' });
  while (calls.length < 2) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(service.cancel('test-job', 'window-2').cancelled, false);
  assert.equal(service.cancel('test-job', 'window-1').cancelled, true);
  await rejection;
  assert.equal(service.jobs.size, 0);
  assert.deepEqual(await fsp.readdir(path.join(dir, 'motion-export')), []);
});

const ffmpeg = process.env.VIBEPOST_FFMPEG || path.resolve(__dirname, '../resources/ffmpeg/ffmpeg.exe');
const ffprobe = process.env.VIBEPOST_FFPROBE || path.join(path.dirname(ffmpeg), 'ffprobe.exe');
test('real FFmpeg composes MP4 with audio and GIF without audio at declared full-card dimensions', { skip: !fs.existsSync(ffmpeg) || !fs.existsSync(ffprobe), timeout: 120000 }, async (t) => {
  const dir = await temp(t);
  const run = (args) => {
    const result = spawnSync(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', ...args], { windowsHide: true, maxBuffer: 4000000 });
    assert.equal(result.status, 0, result.stderr.toString());
  };
  const card = path.join(dir, 'card.png');
  const video = path.join(dir, 'source.mp4');
  run(['-f', 'lavfi', '-i', 'color=c=yellow:s=1440x1920', '-frames:v', '1', card]);
  run(['-f', 'lavfi', '-i', 'testsrc2=s=320x240:r=30', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', video]);
  const service = new MotionService({ dataDir: dir, ffmpegPath: ffmpeg, ffprobePath: ffprobe });
  t.after(() => service.dispose());
  for (const format of ['mp4', 'gif']) {
    const result = await service.render({ ...request(), job: format, format, card: (await fsp.readFile(card)).toString('base64'), video: (await fsp.readFile(video)).toString('base64'), start: 0, span: 1, speed: 1 });
    const output = path.join(dir, `final.${format}`);
    await fsp.writeFile(output, Buffer.from(result.data, 'base64'));
    const probe = spawnSync(ffprobe, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', output], { windowsHide: true });
    assert.equal(probe.status, 0, probe.stderr.toString());
    const info = JSON.parse(probe.stdout);
    const track = info.streams.find((item) => item.codec_type === 'video');
    assert.equal(track.width, format === 'mp4' ? 1440 : 864);
    assert.equal(track.height, format === 'mp4' ? 1920 : 1152);
    if (format === 'mp4') {
      assert.equal(track.codec_name, 'h264');
      assert.equal(track.pix_fmt, 'yuv420p');
      assert.equal(track.r_frame_rate, '30/1');
      assert.ok(info.streams.some((item) => item.codec_name === 'aac'));
    } else {
      assert.equal(track.codec_name, 'gif');
      assert.ok(!info.streams.some((item) => item.codec_type === 'audio'));
    }
    assert.ok(Math.abs(Number(info.format.duration) - 1) < 0.15);
  }
});

test('real rotated-video crop and rounded corners preserve the surrounding full card', { skip: !fs.existsSync(ffmpeg) || !fs.existsSync(ffprobe), timeout: 60000 }, async (t) => {
  const dir = await temp(t);
  const run = (args, maxBuffer = 8000000) => {
    const result = spawnSync(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', ...args], { windowsHide: true, maxBuffer });
    assert.equal(result.status, 0, result.stderr.toString());
    return result.stdout;
  };
  const card = path.join(dir, 'background.png');
  const video = path.join(dir, 'colors.mp4');
  const rotated = path.join(dir, 'rotated.mov');
  run(['-f', 'lavfi', '-i', 'color=c=yellow:s=1440x1920', '-frames:v', '1', card]);
  run(['-f', 'lavfi', '-i', 'color=c=red:s=320x240:r=30,drawbox=x=160:y=0:w=160:h=240:color=blue:t=fill', '-t', '1', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', video]);
  run(['-display_rotation:v:0', '90', '-i', video, '-map', '0', '-c', 'copy', rotated]);
  const rotationProbe = spawnSync(ffprobe, ['-v', 'error', '-show_streams', '-of', 'json', rotated], { windowsHide: true });
  assert.equal(JSON.parse(rotationProbe.stdout).streams[0].side_data_list.find((item) => item.side_data_type === 'Display Matrix').rotation, 90);
  const service = new MotionService({ dataDir: dir, ffmpegPath: ffmpeg, ffprobePath: ffprobe });
  t.after(() => service.dispose());
  const result = await service.render({ ...request(), card: (await fsp.readFile(card)).toString('base64'), video: (await fsp.readFile(rotated)).toString('base64'), videoName: 'rotated.mov', start: 0, span: 1, speed: 1, sound: false, well: { x: 100, y: 100, width: 240, height: 240, radius: 30 }, crop: { x: 0, y: 0, width: 1, height: 0.5 } });
  const output = path.join(dir, 'composed.mp4');
  await fsp.writeFile(output, Buffer.from(result.data, 'base64'));
  const pixels = run(['-i', output, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], 12000000);
  const pixel = (x, y) => [...pixels.subarray((y * 1440 + x) * 3, (y * 1440 + x) * 3 + 3)];
  const outside = pixel(40, 40);
  const roundedCorner = pixel(168, 168);
  const center = pixel(365, 365);
  assert.ok(outside[0] > 220 && outside[1] > 220 && outside[2] < 30, `outside ${outside}`);
  assert.ok(roundedCorner[0] > 220 && roundedCorner[1] > 220 && roundedCorner[2] < 30, `rounded corner ${roundedCorner}`);
  assert.ok(center[2] > 220 && center[0] < 30 && center[1] < 30, `upright crop center ${center}`);
});
