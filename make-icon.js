#!/usr/bin/env node
// Regenerates the app icon art: icon.svg (full detail), icon-small.svg (16/32pt art)
// and icon.png (1024 master, also the fallback source when rsvg-convert isn't installed).
//
//   node make-icon.js          # rewrites the SVGs, and icon.png if rsvg-convert exists
//
// The mark: three Gantt bars cascading down-left, so the stagger traces the "/" in
// Sweck/ban. Small sizes get shorter, chunkier bars with wider gaps — at 16pt the full
// art's 108pt bars land on ~1.7 device pixels and smear into each other.

const fs = require("fs");
const { execFileSync } = require("child_process");

// Apple's macOS icon grid: 1024 canvas, 824 body centered, shadow below.
const A = 412, CX = 512, CY = 512;

// Superellipse — n=5 closely matches Apple's continuous ("squircle") corner.
function squircle(cx = CX, cy = CY, a = A, b = A, n = 5, steps = 480) {
  const p = [];
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * 2 * Math.PI;
    const c = Math.cos(t), s = Math.sin(t);
    p.push(`${i ? "L" : "M"}${(cx + a * Math.sign(c) * Math.pow(Math.abs(c), 2 / n)).toFixed(2)} ` +
           `${(cy + b * Math.sign(s) * Math.pow(Math.abs(s), 2 / n)).toFixed(2)}`);
  }
  return p.join(" ") + " Z";
}
const BODY = squircle();

// Label palette, shared with the board UI
const ORANGE = "#FF4D00", BLUE = "#4DA3FF", GREEN = "#3FBF6F";

// Three equal bars, each stepped left and down from the one above.
function bars({ x, y, w, h, stepX, stepY }) {
  const r = h / 2;
  return [ORANGE, BLUE, GREEN].map((fill, i) =>
    `  <rect x="${x - i * stepX}" y="${y + i * stepY}" width="${w}" height="${h}" rx="${r}" fill="${fill}"/>`
  ).join("\n");
}

function svg({ glyph, grain }) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <clipPath id="clip"><path d="${BODY}"/></clipPath>
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity="0.30"/>
  </filter>
  <linearGradient id="shell" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#34343B"/><stop offset="1" stop-color="#121214"/>
  </linearGradient>
  <filter id="grain" x="0" y="0" width="100%" height="100%">
    <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" stitchTiles="stitch"/>
    <feColorMatrix type="saturate" values="0"/>
  </filter>
</defs>
<g filter="url(#shadow)"><path d="${BODY}" fill="url(#shell)"/></g>
<g clip-path="url(#clip)">
${grain ? `  <rect x="0" y="0" width="1024" height="1024" filter="url(#grain)" opacity="0.05"/>\n` : ""}${glyph}
</g>
<path d="${BODY}" fill="none" stroke="#FFFFFF" stroke-opacity="0.10" stroke-width="3"/>
</svg>
`;
}

// Full detail — 128pt and up. Grain dithers the shell so it doesn't band at 512pt+.
const full = svg({
  grain: true,
  glyph: bars({ x: 430, y: 268, w: 420, h: 108, stepX: 130, stepY: 184 }),
});

// 16/32pt — taller bars, wider gaps, more stagger so three distinct rows survive.
const small = svg({
  grain: false,
  glyph: bars({ x: 404, y: 162, w: 460, h: 180, stepX: 140, stepY: 260 }),
});

fs.writeFileSync(`${__dirname}/icon.svg`, full);
fs.writeFileSync(`${__dirname}/icon-small.svg`, small);
console.log("wrote icon.svg, icon-small.svg");

try {
  execFileSync("rsvg-convert", ["-w", "1024", "-h", "1024", `${__dirname}/icon.svg`,
                                "-o", `${__dirname}/icon.png`]);
  console.log("wrote icon.png (1024)");
} catch (e) {
  console.log("rsvg-convert not found — left icon.png alone (brew install librsvg to refresh it)");
}
