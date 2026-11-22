// Streamline Ultimate Color / Like, CC BY 4.0. See ../../THIRD_PARTY_NOTICES.md.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Resvg } = require('@resvg/resvg-js');

const source = fs.readFileSync(path.join(__dirname, 'Like.svg'), 'utf8');
const artwork = source.match(/<svg\b[^>]*>([\s\S]*)<\/svg>/)[1];
const appSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect x="96" y="96" width="832" height="832" rx="186" fill="#fff" stroke="#e2e2e2" stroke-width="2"/><svg x="218" y="218" width="588" height="588" viewBox="0 0 24 24">${artwork}</svg></svg>`;
const render = (svg, size, output) => {
  fs.writeFileSync(output, new Resvg(svg, { fitTo: { mode: 'width', value: size } }).render().asPng());
};

fs.writeFileSync(path.join(__dirname, 'AppIcon.svg'), appSvg);
render(source, 80, path.join(__dirname, '../Sources/AccountMenu/Resources/Like-Menu.png'));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-accounts-icons-'));
try {
  const iconset = path.join(temporary, 'AppIcon.iconset');
  fs.mkdirSync(iconset);
  for (const size of [16, 32, 128, 256, 512]) {
    render(appSvg, size, path.join(iconset, `icon_${size}x${size}.png`));
    render(appSvg, size * 2, path.join(iconset, `icon_${size}x${size}@2x.png`));
  }
  execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', path.join(__dirname, 'AppIcon.icns')]);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
