// Run with Node.js and sharp available (or LIVECOPILOT_SHARP_PATH pointing to it).
const fs = require('node:fs/promises');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const sharp = require(process.env.LIVECOPILOT_SHARP_PATH || 'sharp');
async function main() {
  const root = path.resolve(__dirname, '../..');
  const svg = await fs.readFile(path.join(root, 'assets/brand/LiveCopilot.svg'));
  const iconset = path.join(root, 'dist/LiveCopilot.iconset');
  await fs.mkdir(iconset, { recursive: true });
  for (const size of [16, 32, 128, 256, 512]) {
    for (const scale of [1, 2]) {
      const name = `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`;
      await sharp(svg).resize(size*scale, size*scale).png().toFile(path.join(iconset, name));
    }
  }
  await sharp(svg).resize(512, 512).png().toFile(path.join(root, 'assets/brand/LiveCopilot-preview.png'));
  execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', path.join(root, 'StealthApp/Resources/AppIcon.icns')]);
  console.log('Rendered SVG to transparent PNG sizes and AppIcon.icns.');
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
