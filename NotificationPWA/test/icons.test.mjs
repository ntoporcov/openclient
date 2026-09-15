import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { inflateSync } from "node:zlib";
import test from "node:test";

function decodeFilterZeroPNG(buffer) {
  assert.equal(buffer.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  const width = buffer.readUInt32BE(16); const height = buffer.readUInt32BE(20);
  let offset = 8; const image = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset); const type = buffer.toString("ascii", offset + 4, offset + 8);
    if (type === "IDAT") image.push(buffer.subarray(offset + 8, offset + 8 + length));
    offset += length + 12;
  }
  const raw = inflateSync(Buffer.concat(image)); const pixels = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y += 1) {
    assert.equal(raw[y * (width * 4 + 1)], 0);
    raw.copy(pixels, y * width * 4 + 0, y * (width * 4 + 1) + 1, y * (width * 4 + 1) + 1 + width * 4);
  }
  return { width, height, pixels };
}

const pixel = ({ pixels, width }, x, y) => pixels.subarray((y * width + x) * 4, (y * width + x + 1) * 4);

test("generated icons contain the opaque official OpenCode mark and notification badge", async () => {
  for (const size of [180, 192, 512]) {
    const icon = decodeFilterZeroPNG(await readFile(new URL(`../public/icons/icon-${size}.png`, import.meta.url)));
    assert.deepEqual([icon.width, icon.height], [size, size]);
    for (let alpha = 3; alpha < icon.pixels.length; alpha += 4) assert.equal(icon.pixels[alpha], 255);
    assert.deepEqual([...pixel(icon, 0, 0)], [0x13, 0x10, 0x10, 255]);
    assert.deepEqual([...pixel(icon, Math.floor(size * 256 / 512), Math.floor(size * 120 / 512))], [255, 255, 255, 255]);
    assert.deepEqual([...pixel(icon, Math.floor(size * 256 / 512), Math.floor(size * 288 / 512))], [0x5a, 0x58, 0x58, 255]);
    assert.deepEqual([...pixel(icon, Math.floor(size * 384 / 512), Math.floor(size * 108 / 512))], [255, 59, 48, 255]);
    assert.equal(pixel(icon, size - 1, size - 1)[3], 255);
  }
});
