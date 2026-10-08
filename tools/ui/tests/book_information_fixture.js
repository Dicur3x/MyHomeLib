"use strict";
const fs = require('fs'), path = require('path'), cp = require('child_process'), crypto = require('crypto');
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
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
  fs.writeFileSync(path.join(photos, 'portrait.png'), png);
  fs.writeFileSync(path.join(other, 'other.png'), png);
  fs.mkdirSync(path.join(authors, 'pictures'));
  archive(['a', '-tzip', path.join(authors, 'pictures', '100.zip'), hash + '/*', hash + 'wrong/*'], photoInput);
};
