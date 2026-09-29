import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { link, open, unlink } from 'node:fs/promises';

const MAGIC = Buffer.from('CLRSX2\0\0');
const HEADER_SIZE = MAGIC.length + 8;
const MAX_FRAME = 4 * 1024 * 1024;
const BYTE_CHUNK = 256 * 1024;

async function writeAll(file, buffer, position) {
  let offset = 0;
  while (offset < buffer.length) {
    const { bytesWritten } = await file.write(
      buffer, offset, buffer.length - offset, position + offset,
    );
    if (bytesWritten < 1) throw new Error('Archive write failed');
    offset += bytesWritten;
  }
  return position + buffer.length;
}

function assertKey(key) {
  if (!Buffer.isBuffer(key) || key.length !== 32) {
    throw new Error('Archive key must be exactly 32 bytes');
  }
}

function frameNonce(header, index) {
  const nonce = Buffer.alloc(12);
  header.copy(nonce, 0, MAGIC.length);
  nonce.writeUInt32BE(index, 8);
  return nonce;
}

function frameAad(header, index, lengthBuffer) {
  const number = Buffer.alloc(4);
  number.writeUInt32BE(index);
  return Buffer.concat([header, number, lengthBuffer]);
}

// Every frame is independently authenticated. Only ciphertext and a public
// format header touch disk; the final authenticated frame marks completeness.
export class EncryptedArchiveWriter {
  static async create(outputPath, key) {
    assertKey(key);
    const partialPath = `${outputPath}.partial-${randomBytes(8).toString('hex')}`;
    const file = await open(partialPath, 'wx', 0o600);
    const header = Buffer.concat([MAGIC, randomBytes(8)]);
    try {
      await writeAll(file, header, 0);
      return new EncryptedArchiveWriter(outputPath, partialPath, file, header, key);
    } catch (error) {
      await file.close();
      await unlink(partialPath);
      throw error;
    }
  }

  constructor(outputPath, partialPath, file, header, key) {
    this.outputPath = outputPath;
    this.partialPath = partialPath;
    this.file = file;
    this.header = header;
    this.key = key;
    this.position = HEADER_SIZE;
    this.index = 0;
    this.closed = false;
  }

  async #frame(type, payload) {
    if (this.closed || this.index >= 0xffffffff) throw new Error('Archive is closed or too large');
    if (payload.length + 1 > MAX_FRAME) throw new Error('Archive frame exceeds limit');
    const plain = Buffer.concat([Buffer.from([type]), payload]);
    const lengthBuffer = Buffer.alloc(4);
    lengthBuffer.writeUInt32BE(plain.length);
    const cipher = createCipheriv('aes-256-gcm', this.key, frameNonce(this.header, this.index));
    cipher.setAAD(frameAad(this.header, this.index, lengthBuffer));
    const encrypted = Buffer.concat([cipher.update(plain), cipher.final()]);
    const frame = Buffer.concat([lengthBuffer, encrypted, cipher.getAuthTag()]);
    this.position = await writeAll(this.file, frame, this.position);
    this.index++;
  }

  async writeJson(record) {
    if (record?.kind === 'end') throw new Error('End frame is reserved');
    await this.#frame(1, Buffer.from(JSON.stringify(record), 'utf8'));
  }

  async writeBytes(bytes) {
    const buffer = Buffer.from(bytes);
    for (let offset = 0; offset < buffer.length; offset += BYTE_CHUNK) {
      await this.#frame(2, buffer.subarray(offset, offset + BYTE_CHUNK));
    }
  }

  async finish(summary) {
    if (this.closed) throw new Error('Archive already closed');
    await this.#frame(1, Buffer.from(JSON.stringify({ kind: 'end', summary }), 'utf8'));
    await this.file.sync();
    await this.file.close();
    this.closed = true;
    // A hard link publishes only the complete archive and never replaces one.
    await link(this.partialPath, this.outputPath);
    await unlink(this.partialPath);
  }

  async abort() {
    if (!this.closed) {
      this.closed = true;
      await this.file.close();
    }
    await unlink(this.partialPath).catch((error) => {
      if (error.code !== 'ENOENT') throw error;
    });
  }
}

async function readExact(file, length, position, allowEof = false) {
  const buffer = Buffer.alloc(length);
  let offset = 0;
  while (offset < length) {
    const { bytesRead } = await file.read(buffer, offset, length - offset, position + offset);
    if (bytesRead === 0) {
      if (offset === 0 && allowEof) return null;
      throw new Error('Truncated archive');
    }
    offset += bytesRead;
  }
  return buffer;
}

// The reader authenticates ordering, each frame and the final marker. The
// caller may process arbitrarily large Storage objects one frame at a time.
export async function* readEncryptedArchive(path, key, { onCiphertext } = {}) {
  assertKey(key);
  const file = await open(path, 'r');
  try {
    const header = await readExact(file, HEADER_SIZE, 0);
    if (!header.subarray(0, MAGIC.length).equals(MAGIC)) throw new Error('Invalid archive format');
    onCiphertext?.(header);
    let position = HEADER_SIZE;
    let index = 0;
    let ended = false;
    while (true) {
      const lengthBuffer = await readExact(file, 4, position, true);
      if (!lengthBuffer) break;
      if (ended) throw new Error('Archive has trailing frames');
      const length = lengthBuffer.readUInt32BE();
      if (length < 1 || length > MAX_FRAME || index >= 0xffffffff) {
        throw new Error('Invalid archive frame');
      }
      position += 4;
      const encrypted = await readExact(file, length + 16, position);
      position += length + 16;
      onCiphertext?.(lengthBuffer);
      onCiphertext?.(encrypted);
      const decipher = createDecipheriv('aes-256-gcm', key, frameNonce(header, index));
      decipher.setAAD(frameAad(header, index, lengthBuffer));
      decipher.setAuthTag(encrypted.subarray(length));
      const plain = Buffer.concat([
        decipher.update(encrypted.subarray(0, length)), decipher.final(),
      ]);
      index++;
      if (plain[0] === 1) {
        const record = JSON.parse(plain.subarray(1).toString('utf8'));
        if (record?.kind === 'end') {
          // Do not expose a completion marker until EOF has been checked. A
          // caller may intentionally stop reading as soon as it receives it.
          if (await readExact(file, 1, position, true)) {
            throw new Error('Archive has trailing data');
          }
          ended = true;
        }
        yield { type: 'json', record };
      } else if (plain[0] === 2) {
        yield { type: 'bytes', bytes: plain.subarray(1) };
      } else {
        throw new Error('Unknown archive frame');
      }
    }
    if (!ended) throw new Error('Archive has no completion marker');
  } finally {
    await file.close();
  }
}
