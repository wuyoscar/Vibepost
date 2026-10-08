'use strict';

const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn: defaultSpawn } = require('node:child_process');

function number(value, name, fallback) {
  const result = value === undefined && fallback !== undefined ? fallback : Number(value);
  if (!Number.isFinite(result)) throw new Error(`动态导出的${name}无效`);
  return result;
}

function normalizeRequest(request, duration) {
  const format = request.format || 'mp4';
  if (!['mp4', 'gif'].includes(format)) throw new Error('动态导出只支持 MP4 或 GIF');
  const cardWidth = number(request.cardWidth, '卡片宽度', 864);
  const cardHeight = number(request.cardHeight, '卡片高度', 1152);
  const raw = request.well || {};
  const well = Object.fromEntries(['x', 'y', 'width', 'height', 'radius'].map((key) => [key, number(raw[key], `图片框 ${key}`, key === 'radius' ? 0 : undefined)]));
  if (cardWidth <= 0 || cardHeight <= 0 || well.width <= 0 || well.height <= 0 || well.radius < 0 || well.x < 0 || well.y < 0 || well.x + well.width > cardWidth + 0.01 || well.y + well.height > cardHeight + 0.01) throw new Error('动态导出的图片框不在卡片内');
  const cropRaw = request.crop || { x: 0, y: 0, width: 1, height: 1 };
  const crop = Object.fromEntries(['x', 'y', 'width', 'height'].map((key) => [key, number(cropRaw[key], `取景 ${key}`)]));
  if (crop.x < 0 || crop.y < 0 || crop.width <= 0 || crop.height <= 0 || crop.x + crop.width > 1.0001 || crop.y + crop.height > 1.0001) throw new Error('动态导出的取景框无效');
  const speed = number(request.speed, '倍速', 1);
  let start = number(request.start, '起点', 0);
  let span = number(request.span, '时长');
  if (start < 0 || span <= 0 || speed <= 0 || speed > 8 || span / speed > 120) throw new Error('动态导出的时间设置无效');
  if (Number.isFinite(duration) && duration > 0) {
    start = Math.min(start, Math.max(0, duration - 0.05));
    span = Math.max(0.05, Math.min(span, duration - start));
  }
  const width = format === 'gif' ? 864 : 1440;
  const height = format === 'gif' ? 1152 : 1920;
  // Compose at full resolution for both formats; GIF is resized after compositing.
  const sx = 1440 / cardWidth;
  const sy = 1920 / cardHeight;
  const placed = {
    x: Math.round(well.x * sx), y: Math.round(well.y * sy),
    width: Math.max(1, Math.round(well.width * sx)), height: Math.max(1, Math.round(well.height * sy)),
    radius: Math.min(well.radius * Math.min(sx, sy), well.width * sx / 2, well.height * sy / 2),
  };
  return { format, crop, well: placed, start, span, speed, sound: request.sound !== false, duration: span / speed, width, height };
}

function roundedMask({ width, height, radius }) {
  const header = Buffer.from(`P5\n${width} ${height}\n255\n`);
  const data = Buffer.alloc(width * height, 255);
  if (radius > 0) {
    // Four subpixel samples keep the same antialiased rounded corners as the card.
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      let inside = 0;
      for (const dx of [0.25, 0.75]) for (const dy of [0.25, 0.75]) {
        const cx = Math.max(radius, Math.min(width - radius, x + dx));
        const cy = Math.max(radius, Math.min(height - radius, y + dy));
        if ((x + dx - cx) ** 2 + (y + dy - cy) ** 2 <= radius ** 2) inside++;
      }
      data[y * width + x] = Math.round(255 * inside / 4);
    }
  }
  return Buffer.concat([header, data]);
}

function tempo(speed) {
  const filters = [];
  while (speed > 2) { filters.push('atempo=2'); speed /= 2; }
  while (speed < 0.5) { filters.push('atempo=0.5'); speed *= 2; }
  filters.push(`atempo=${speed}`);
  return filters.join(',');
}

function buildArgs(clip, files, hasAudio) {
  const { well, crop } = clip;
  // FFmpeg applies display-matrix/rotation metadata before these filters, so the
  // normalized crop uses the same upright coordinates as the browser preview.
  const filters = [
    '[0:v]scale=1440:1920:flags=lanczos,setsar=1,format=rgba[card]',
    `[1:v]trim=duration=${clip.span},setpts=(PTS-STARTPTS)/${clip.speed},format=rgba,crop=w=iw*${crop.width}:h=ih*${crop.height}:x=iw*${crop.x}:y=ih*${crop.y},scale=${well.width}:${well.height}:force_original_aspect_ratio=increase:flags=lanczos,crop=${well.width}:${well.height},setsar=1,fps=30,format=rgba[well]`,
    '[2:v]format=gray[mask]',
    '[well][mask]alphamerge=shortest=1[cut]',
    `[card][cut]overlay=x=${well.x}:y=${well.y}:shortest=1:eof_action=endall:format=auto[composed]`,
  ];
  if (clip.format === 'gif') {
    filters.push('[composed]scale=864:1152:flags=lanczos,fps=15,split[g1][g2]', '[g1]palettegen=stats_mode=diff[palette]', '[g2][palette]paletteuse=dither=sierra2_4a[video]');
  } else filters.push('[composed]format=yuv420p[video]');
  const audio = clip.format === 'mp4' && clip.sound && hasAudio;
  if (audio) filters.push(`[1:a]atrim=duration=${clip.span},asetpts=PTS-STARTPTS,${tempo(clip.speed)},apad,atrim=duration=${clip.duration}[audio]`);
  const args = ['-hide_banner', '-y', '-nostdin', '-filter_complex_threads', '1', '-loop', '1', '-framerate', '30', '-i', files.card, '-ss', String(clip.start), '-i', files.video, '-loop', '1', '-framerate', '30', '-i', files.mask, '-filter_complex', filters.join(';'), '-map', '[video]'];
  if (audio) args.push('-map', '[audio]', '-c:a', 'aac', '-b:a', '128k', '-ar', '44100');
  else args.push('-an');
  if (clip.format === 'mp4') args.push('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-r', '30', '-movflags', '+faststart');
  else args.push('-loop', '0');
  args.push('-t', String(clip.duration), '-progress', 'pipe:1', '-nostats', files.output);
  return args;
}

function binary(value, label) {
  if (typeof value !== 'string' || !value.length || value.length > 1400 * 1024 * 1024 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw new Error(`动态导出的${label}不是有效 Base64`);
  const data = Buffer.from(value, 'base64');
  if (!data.length) throw new Error(`动态导出的${label}为空`);
  return data;
}

const cancelledError = () => Object.assign(new Error('已取消'), { name: 'AbortError', code: 'ABORT_ERR' });

class MotionService {
  constructor({ dataDir, ffmpegPath, ffprobePath, emit = () => {}, spawn = defaultSpawn }) {
    if (!dataDir || !ffmpegPath || !ffprobePath) throw new Error('动态导出缺少 FFmpeg 或存储目录');
    this.root = path.resolve(dataDir, 'motion-export');
    this.ffmpegPath = ffmpegPath;
    this.ffprobePath = ffprobePath;
    this.emit = emit;
    this.spawn = spawn;
    this.jobs = new Map();
    this.disposed = false;
  }

  process(job, executable, args, onOutput) {
    if (job.cancelled) return Promise.reject(cancelledError());
    return new Promise((resolve, reject) => {
      const child = this.spawn(executable, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], shell: false });
      job.child = child;
      let output = '';
      let errors = '';
      let settled = false;
      const finish = (error) => {
        if (settled) return;
        settled = true;
        if (job.child === child) job.child = null;
        error ? reject(error) : resolve(output);
      };
      child.stdout.on('data', (chunk) => { output = (output + chunk.toString()).slice(-2 * 1024 * 1024); onOutput?.(chunk.toString()); });
      child.stderr.on('data', (chunk) => { errors = (errors + chunk.toString()).slice(-16000); });
      child.once('error', (error) => finish(job.cancelled ? cancelledError() : error));
      child.once('close', (code) => finish(job.cancelled ? cancelledError() : code === 0 ? null : new Error(`动态视频没能生成：${errors.trim() || `FFmpeg 退出代码 ${code}`}`)));
    });
  }

  async render(owner, request) {
    if (request === undefined) { request = owner; owner = undefined; }
    if (this.disposed) throw new Error('动态导出服务已关闭');
    if (!request || typeof request !== 'object') throw new Error('动态导出请求无效');
    const jobId = String(request.job || crypto.randomUUID());
    if (this.jobs.has(jobId)) throw new Error('这个动态导出任务正在进行');
    // Never use a caller supplied job ID as part of a filesystem path.
    const dir = path.join(this.root, crypto.randomUUID());
    const job = { owner, cancelled: false, child: null, done: null };
    this.jobs.set(jobId, job);
    job.done = (async () => {
      try {
        await fsp.mkdir(dir, { recursive: true });
        const ext = ['.mov', '.mp4', '.m4v'].includes(path.extname(String(request.videoName)).toLowerCase()) ? path.extname(String(request.videoName)).toLowerCase() : '.mp4';
        const files = { card: path.join(dir, 'card.png'), video: path.join(dir, `source${ext}`), mask: path.join(dir, 'mask.pgm'), output: path.join(dir, `output.${request.format === 'gif' ? 'gif' : 'mp4'}`) };
        await fsp.writeFile(files.card, binary(request.card, '卡片'));
        await fsp.writeFile(files.video, binary(request.video, '视频'));
        this.emit(owner, { job: jobId, progress: 0 });
        const probeText = await this.process(job, this.ffprobePath, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', files.video]);
        let probe;
        try { probe = JSON.parse(probeText); } catch { throw new Error('视频信息读不出来'); }
        const track = probe.streams?.find((item) => item.codec_type === 'video');
        if (!track || !(Number(track.width) > 0) || !(Number(track.height) > 0)) throw new Error('这段视频没有可读取的画面');
        const clip = normalizeRequest(request, Number(probe.format?.duration || track.duration));
        await fsp.writeFile(files.mask, roundedMask(clip.well));
        let buffered = '';
        let reported = 0;
        await this.process(job, this.ffmpegPath, buildArgs(clip, files, probe.streams.some((item) => item.codec_type === 'audio')), (chunk) => {
          buffered += chunk;
          const lines = buffered.split(/\r?\n/);
          buffered = lines.pop();
          for (const line of lines) if (line.startsWith('out_time_us=')) {
            const progress = Math.min(0.99, Number(line.slice(12)) / 1000000 / clip.duration);
            if (Number.isFinite(progress) && progress - reported >= 0.02) { reported = progress; this.emit(owner, { job: jobId, progress }); }
          }
        });
        if (job.cancelled) throw cancelledError();
        const data = await fsp.readFile(files.output);
        if (!data.length) throw new Error('动态导出的文件为空');
        this.emit(owner, { job: jobId, progress: 1 });
        return { job: jobId, format: clip.format, type: clip.format === 'gif' ? 'image/gif' : 'video/mp4', data: data.toString('base64'), width: clip.width, height: clip.height, duration: clip.duration };
      } finally {
        this.jobs.delete(jobId);
        await fsp.rm(dir, { recursive: true, force: true });
      }
    })();
    return job.done;
  }

  cancel(jobId, owner) {
    const job = this.jobs.get(String(jobId));
    if (!job || (owner !== undefined && job.owner !== owner)) return { cancelled: false };
    job.cancelled = true;
    job.child?.kill();
    return { cancelled: true };
  }

  async dispose() {
    this.disposed = true;
    const pending = [...this.jobs.entries()];
    for (const [id] of pending) this.cancel(id);
    await Promise.allSettled(pending.map(([, job]) => job.done));
  }
}

module.exports = { MotionService, normalizeRequest, roundedMask, buildArgs };
