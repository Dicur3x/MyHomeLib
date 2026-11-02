// Build the Reader's native icon from the repository's SVG artwork.
// Does not modify catalogue/installer icons or any compiled EXE.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const {bmpEntry, buildIco, makeRes, groupIcon} = require('./make_app_icon');

async function main() {
  const images = [];
  for (const size of [256,128,64,48,40,32,24,20,16]) {
    const source = path.join(__dirname, size <= 32 ? 'reader-icon-small.svg' : 'reader-icon.svg');
    const density = Math.ceil(size / (size <= 32 ? 32 : 256) * 768);
    const raster = sharp(source, {density}).resize(size,size).ensureAlpha();
    const data = size >= 128 ? await raster.png().toBuffer()
      : bmpEntry(await raster.raw().toBuffer(),size,size);
    images.push({size,data});
  }
  const output = path.join(__dirname,'..','reader.ico');
  fs.writeFileSync(output,buildIco(images));
  // Keep IDs separate from MAINICON and sort this named group after it, so
  // adding Reader artwork never changes the catalogue's Explorer icon.
  const firstId = 54001;
  // The initial null record must have zero language/flags; the linker uses
  // this exact sentinel to distinguish Win32 resources from 16-bit ones.
  const header = Buffer.alloc(32);
  header.writeUInt32LE(32,4); header.writeUInt16LE(0xffff,8); header.writeUInt16LE(0xffff,12);
  const resource = Buffer.concat([header,
    ...images.map((image,index)=>makeRes(3,firstId+index,image.data,0x1010)),
    makeRes(14,'ZZ_HOME_LIBRE_READER_ICON',groupIcon(images,firstId),0x1030)]);
  fs.writeFileSync(path.join(__dirname,'..','reader-icon.res'),resource);
  console.log('Built '+path.relative(process.cwd(),output)+' in nine native icon sizes');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
