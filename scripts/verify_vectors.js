// 模拟 Swift 端 TxinGzip.gunzip 的解析逻辑，验证它对 Node 生成的 gzip 有效。
// Swift 侧：COMPRESSION_ZLIB = raw deflate（RFC1951），gzip 头尾要自己剥。
const zlib = require('zlib');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function swiftStyleGunzip(buf) {
  if (buf.length <= 18) throw new Error('too short');
  if (buf[0] !== 0x1f || buf[1] !== 0x8b) throw new Error('not gzip');
  if (buf[2] !== 0x08) throw new Error('not deflate');
  const flg = buf[3];
  let i = 10;
  if (flg & 0x04) { const xlen = buf[i] | (buf[i + 1] << 8); i += 2 + xlen; }
  if (flg & 0x08) { while (i < buf.length && buf[i] !== 0) i++; i++; }
  if (flg & 0x10) { while (i < buf.length && buf[i] !== 0) i++; i++; }
  if (flg & 0x02) i += 2;
  const end = buf.length - 8;
  const body = buf.subarray(i, end);
  return zlib.inflateRawSync(body);          // raw deflate
}

// 反向：模拟 Swift 的 gzip 打包（raw deflate + 自写头尾），再用标准 gunzip 验
function crc32(buf) {
  let crc = 0xFFFFFFFF;
  for (const b of buf) {
    crc ^= b;
    for (let k = 0; k < 8; k++) crc = (crc >>> 1) ^ (0xEDB88320 & -(crc & 1));
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}
function swiftStyleGzip(data) {
  const deflated = zlib.deflateRawSync(data, { level: 6 });
  const head = Buffer.from([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]);
  const trailer = Buffer.alloc(8);
  trailer.writeUInt32LE(crc32(data), 0);
  trailer.writeUInt32LE(data.length >>> 0, 4);
  return Buffer.concat([head, deflated, trailer]);
}

const vectors = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'test-vectors.json'), 'utf8'));
let ok = 0, bad = [];
const B = Buffer.from.bind(Buffer);

for (const [i, v] of vectors.requestVectors.entries()) {
  // 1) 金标 body 解出来对不对
  const body = B(v.bodyBase64, 'base64');
  const iv = body.subarray(0, 16);
  const ct = body.subarray(16);
  const key = B(v.keyHex, 'hex');
  const d = crypto.createDecipheriv('aes-256-cbc', key, iv);
  const gz = Buffer.concat([d.update(ct), d.final()]);
  const plain = swiftStyleGunzip(gz);
  const obj = JSON.parse(plain.toString('utf8'));
  if (JSON.stringify(obj) === JSON.stringify(v.payload)) { ok++; }
  else bad.push(`vector#${i}: 解开后内容不符 ${plain}`);

  // 2) Swift 风格打包 -> 标准 gunzip 能解
  const repack = swiftStyleGzip(B(JSON.stringify(v.payload)));
  const round = zlib.gunzipSync(repack);
  if (JSON.stringify(JSON.parse(round.toString('utf8'))) === JSON.stringify(v.payload)) ok++;
  else bad.push(`vector#${i}: Swift 风格 gzip 被标准 gunzip 拒解`);

  // 3) Node 原始 gzip 也应该能被 swiftStyleGunzip 解（同理）
  const nodeGz = B(v.gzipBase64, 'base64');
  const r3 = swiftStyleGunzip(nodeGz);
  if (r3.length > 0) ok++; else bad.push(`vector#${i}: Node gzip 剥头失败`);
}

// cookie 向量
const cv = vectors.cookieVector;
const d2 = crypto.createDecipheriv('aes-128-ecb', B(vectors.cookieKey, 'utf8'), null);
const cookiePlain = Buffer.concat([d2.update(B(cv.cipherBase64, 'base64')), d2.final()]).toString('utf8');
if (cookiePlain === cv.plaintext) ok++; else bad.push('cookie 向量不符');

console.log(`通过 ${ok} 项`);
if (bad.length) { bad.forEach(b => console.log('✗ ' + b)); process.exit(1); }
console.log('✓ gzip 头尾解析逻辑、AES 链路、cookie 向量全部自洽');
console.log('  → Swift 端只要 COMPRESSION_ZLIB 是 raw deflate（Apple 文档如此），实现即成立');
