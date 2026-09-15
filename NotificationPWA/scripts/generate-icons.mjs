import { mkdir, writeFile } from "node:fs/promises";
import { deflateSync } from "node:zlib";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const output = path.join(root, "public", "icons");

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const name = Buffer.from(type);
  const result = Buffer.alloc(data.length + 12);
  result.writeUInt32BE(data.length, 0);
  name.copy(result, 4);
  data.copy(result, 8);
  result.writeUInt32BE(crc32(Buffer.concat([name, data])), data.length + 8);
  return result;
}

// OpenCode favicon geometry; source and MIT notice are in THIRD-PARTY-NOTICES.md.
function makeIcon(size) {
  const scale = 4;
  const coordinateScale = 512 / size;
  const rows = [];
  const colors = { background: [0x13, 0x10, 0x10], gray: [0x5a, 0x58, 0x58], white: [255, 255, 255], red: [0xff, 0x3b, 0x30] };
  const sample = (x, y) => {
    const sourceX = ((x + 0.5) / scale) * coordinateScale;
    const sourceY = ((y + 0.5) / scale) * coordinateScale;
    let color = colors.background;
    if (sourceX >= 128 && sourceX < 384 && sourceY >= 96 && sourceY < 416 && !(sourceX >= 192 && sourceX < 320 && sourceY >= 160 && sourceY < 352)) color = colors.white;
    if (sourceX >= 192 && sourceX < 320 && sourceY >= 224 && sourceY < 352) color = colors.gray;
    const distance = Math.hypot(sourceX - 384, sourceY - 108);
    if (distance < 59) color = colors.background;
    if (distance < 52) color = colors.red;
    return color;
  };
  for (let y = 0; y < size; y += 1) {
    const row = Buffer.alloc(1 + size * 4);
    for (let x = 0; x < size; x += 1) {
      const totals = [0, 0, 0];
      for (let sy = 0; sy < scale; sy += 1) for (let sx = 0; sx < scale; sx += 1) {
        const color = sample(x * scale + sx, y * scale + sy);
        totals[0] += color[0]; totals[1] += color[1]; totals[2] += color[2];
      }
      const offset = 1 + x * 4;
      row[offset] = Math.round(totals[0] / (scale * scale));
      row[offset + 1] = Math.round(totals[1] / (scale * scale));
      row[offset + 2] = Math.round(totals[2] / (scale * scale));
      row[offset + 3] = 255;
    }
    rows.push(row);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([
    Buffer.from("89504e470d0a1a0a", "hex"),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(rows), { level: 9 })),
    chunk("IEND", Buffer.alloc(0))
  ]);
}

await mkdir(output, { recursive: true });
for (const size of [180, 192, 512]) {
  await writeFile(path.join(output, `icon-${size}.png`), makeIcon(size), { mode: 0o644 });
}
