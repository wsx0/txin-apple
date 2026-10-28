//  Swift 静态自查（在 Windows 上没法编译，退而求其次做过得去的结构性检查）
//  1) 括号/引号平衡
//  2) 常见跨 module 可见性错误：别的 target 用 TxinKit 里的 struct memberwise init
//  3) SwiftUI 里 List(selection:) 必须绑 Optional
//  4) 未 import 就使用 AppKit/AVKit 符号
import fs from 'fs';
import path from 'path';

const root = process.argv[2] || '.';
const problems = [];
let fileCount = 0;
let lineCount = 0;

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (['.build', 'build', '.git', 'node_modules'].includes(e.name)) continue;
      walk(p, out);
    } else if (e.name.endsWith('.swift')) {
      out.push(p);
    }
  }
  return out;
}

function stripNoise(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const ch = src[i], nx = src[i + 1];
    if (ch === '/' && nx === '/') { while (i < n && src[i] !== '\n') i++; continue; }
    if (ch === '/' && nx === '*') {
      i += 2;
      let depth = 1;
      while (i < n && depth > 0) {
        if (src[i] === '/' && src[i + 1] === '*') { depth++; i += 2; continue; }
        if (src[i] === '*' && src[i + 1] === '/') { depth--; i += 2; continue; }
        i++;
      }
      continue;
    }
    if (ch === '"') {
      if (src.slice(i, i + 3) === '"""') {
        i += 3;
        while (i < n && src.slice(i, i + 3) !== '"""') i++;
        i += 3;
        continue;
      }
      i++;
      while (i < n) {
        if (src[i] === '\\') { i += 2; continue; }
        if (src[i] === '"') { i++; break; }
        i++;
      }
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

const files = walk(root);
for (const f of files) {
  fileCount++;
  const src = fs.readFileSync(f, 'utf8');
  lineCount += src.split('\n').length;
  const rel = path.relative(root, f);
  const code = stripNoise(src);

  for (const [a, b] of [['{', '}'], ['[', ']'], ['(', ')']]) {
    const ca = (code.match(new RegExp('\\' + a, 'g')) || []).length;
    const cb = (code.match(new RegExp('\\' + b, 'g')) || []).length;
    if (ca !== cb) problems.push(`${rel}: ${a}${b} 不平衡 ${ca} vs ${cb}`);
  }

  const isKit = rel.includes('TxinKit');
  const isApp = rel.includes('TxinApp') || rel.includes(path.join('txin', ''));

  // App/CLI 用 AppKit 符号却没 import
  if (!isKit) {
    const needsAppKit = /\b(NSOpenPanel|NSPasteboard|NSWorkspace|NSSavePanel)\b/.test(code);
    if (needsAppKit && !/import AppKit/.test(src)) {
      problems.push(`${rel}: 用了 AppKit 符号但没有 import AppKit`);
    }
    const needsAVKit = /\b(AVPlayer|AVPlayerItem|AVURLAsset|VideoPlayer)\b/.test(code);
    if (needsAVKit && !/import AVKit/.test(src)) {
      problems.push(`${rel}: 用了 AVKit 符号但没有 import AVKit`);
    }
  }

  // TxinKit 里 public struct 被别处用 memberwise init 构造 —— 必须有 public init
  if (!isKit) {
    if (/TxinMovieBrief\s*\(/.test(code) && !/struct TxinMovieBrief/.test(code)) {
      const kitSrc = files
        .filter(x => x.includes('Models.swift'))
        .map(x => fs.readFileSync(x, 'utf8'))
        .join('\n');
      if (!/public init\(\s*id:/.test(kitSrc)) {
        problems.push(`${rel}: 构造了 TxinMovieBrief，但 TxinKit 里没有 public init`);
      }
    }
  }

  // List(selection:) 必须绑 Optional
  if (/List\([^)]*selection:\s*\$([A-Za-z_]\w*)/.test(code)) {
    const m = code.match(/List\([^)]*selection:\s*\$([A-Za-z_]\w*)/);
    const name = m[1];
    const decl = src.match(new RegExp(`@State[^\\n]*\\b${name}\\b[^\\n]*`));
    if (decl && !decl[0].includes('?')) {
      problems.push(`${rel}: List(selection: $${name}) 需要 Optional 绑定`);
    }
  }

  // Identifiable 的 id 为同一常量 —— 会在 ForEach 里撞车
  if (/struct\s+\w+\s*:\s*[^{]*Identifiable/.test(code)) {
    if (/let id: String\?\n\s+let code/.test(src)) {
      problems.push(`${rel}: Identifiable 的 id 可能重复（多线路同 id），改为按 index 迭代`);
    }
  }
}

console.log(`扫描 ${fileCount} 个 .swift 文件，${lineCount} 行`);
if (problems.length === 0) {
  console.log('✓ 未发现结构性问题');
  process.exit(0);
} else {
  for (const p of problems) console.log('⚠ ' + p);
  process.exit(1);
}
