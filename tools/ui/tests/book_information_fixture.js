"use strict";
const fs = require('fs'), path = require('path'), cp = require('child_process'), crypto = require('crypto');
const zlib = require('zlib');
function portraitPNG() {
  // A real image-sized fixture, rather than a one-pixel tracking/placeholder tile.
  function chunk(type, data) {
    const name = Buffer.from(type), payload = Buffer.concat([name, data]);
    let crc = 0xffffffff;
    for (const byte of payload) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    const length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(data.length); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([length, payload, checksum]);
  }
  const width = 32, height = 48, header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 2;
  const rows = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const offset = y * (width * 3 + 1) + 1 + x * 3;
    rows[offset] = 50 + x; rows[offset + 1] = 80 + y; rows[offset + 2] = 150;
  }
  return Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', header),
    chunk('IDAT', zlib.deflateSync(rows)), chunk('IEND', Buffer.alloc(0))]);
}
module.exports = function stageAuthorFixture(runtime, folder) {
  const toolFolder = path.join(folder, 'tools', '7zip');
  fs.mkdirSync(toolFolder, {recursive: true});
  const tool = path.join(toolFolder, '7za.exe');
  fs.copyFileSync(path.join(runtime, 'tools', '7zip', '7za.exe'), tool);
  const authors = path.join(folder, 'authors'), input = path.join(folder, 'author-fixture-input');
  fs.mkdirSync(authors, {recursive: true}); fs.mkdirSync(input);
  const hash = crypto.createHash('md5').update('толстой лев николаевич', 'utf8').digest('hex');
  fs.writeFileSync(path.join(input, hash), '<h2>Толстой Лев Николаевич</h2><p>Русский писатель. Биография &amp; фотографии.</p>', 'utf8');
  function archive(args, cwd) {
    const result = cp.spawnSync(tool, args, {cwd, windowsHide: true, timeout: 15000, encoding: 'utf8'});
    if (result.error || result.status !== 0) throw result.error || new Error(result.stdout + result.stderr);
  }
  archive(['a', '-t7z', '-m0=PPMd', '-ms=off', path.join(authors, '100.7z'), hash], input);
  fs.writeFileSync(path.join(authors, '000-broken.7z'), 'unrelated broken archive');
  const photoInput = path.join(input, 'photographs'); fs.mkdirSync(photoInput);
  const photos = path.join(photoInput, hash), other = path.join(photoInput, hash + 'wrong');
  fs.mkdirSync(photos); fs.mkdirSync(other);
  // Valid small PNG; a nearby hash prefix must not become this author's photo.
  const png = portraitPNG();
  fs.writeFileSync(path.join(photos, 'portrait.png'), png);
  fs.writeFileSync(path.join(other, 'other.png'), png);
  fs.mkdirSync(path.join(authors, 'pictures'));
  archive(['a', '-tzip', path.join(authors, 'pictures', '100.zip'), hash + '/*', hash + 'wrong/*'], photoInput);
};
