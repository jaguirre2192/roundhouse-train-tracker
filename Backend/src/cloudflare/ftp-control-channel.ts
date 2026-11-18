import { connect } from "cloudflare:sockets";

const encoder = new TextEncoder();
const maximumDownloadBytes = 20 * 1024 * 1024;
type Socket = ReturnType<typeof connect>;

export interface FTPConnectionConfiguration {
  host: string;
  username: string;
  password: string;
}

interface FTPReply {
  code: number;
  lines: string[];
}

function normalizedHost(value: string): string {
  return value.trim().replace(/^ftp:\/\//iu, "").replace(/\/$/u, "");
}

function remotePath(directory: string, filename?: string): string {
  const clean = directory.trim().replace(/^\/+|\/+$/gu, "");
  return filename === undefined ? clean : `${clean}/${filename}`;
}

async function readBytes(stream: ReadableStream<Uint8Array>, limit: number): Promise<Uint8Array> {
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const value = await reader.read();
      if (value.done) break;
      length += value.value.byteLength;
      if (length > limit) throw new Error(`Darwin FTP response exceeded ${limit} bytes`);
      chunks.push(value.value);
    }
  } finally {
    reader.releaseLock();
  }

  const result = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

export class FTPControlChannel {
  private readonly reader: ReadableStreamDefaultReader<Uint8Array>;
  private readonly writer: WritableStreamDefaultWriter<Uint8Array>;
  private readonly decoder = new TextDecoder();
  private buffer = "";

  private constructor(
    private readonly socket: Socket,
    private readonly host: string,
  ) {
    this.reader = socket.readable.getReader();
    this.writer = socket.writable.getWriter();
  }

  static async login(configuration: FTPConnectionConfiguration): Promise<FTPControlChannel> {
    const host = normalizedHost(configuration.host);
    const socket = connect({ hostname: host, port: 21 }, { allowHalfOpen: true });
    await socket.opened;
    const channel = new FTPControlChannel(socket, host);
    channel.expect(await channel.reply(), [220]);
    const user = await channel.command(`USER ${configuration.username}`);
    if (user.code === 331) channel.expect(await channel.command(`PASS ${configuration.password}`), [230]);
    else channel.expect(user, [230]);
    channel.expect(await channel.command("TYPE I"), [200]);
    return channel;
  }

  async list(directory: string): Promise<string[]> {
    const bytes = await this.dataCommand(`NLST ${remotePath(directory)}`, 2 * 1024 * 1024);
    return new TextDecoder().decode(bytes).split(/\r?\n/gu)
      .map((value) => value.trim().split("/").at(-1) ?? "")
      .filter((value) => value.length > 0);
  }

  retrieve(directory: string, filename: string, limit = maximumDownloadBytes): Promise<Uint8Array> {
    return this.dataCommand(`RETR ${remotePath(directory, filename)}`, limit);
  }

  async close(): Promise<void> {
    try {
      await this.command("QUIT");
    } catch {
      // The server may close the control stream before returning the final reply.
    }
    this.reader.releaseLock();
    this.writer.releaseLock();
    await this.socket.close();
  }

  private async dataCommand(command: string, limit: number): Promise<Uint8Array> {
    const endpoint = await this.passiveEndpoint();
    const dataSocket = connect(endpoint, { allowHalfOpen: true });
    await dataSocket.opened;
    const preliminary = await this.command(command);
    this.expect(preliminary, [125, 150]);
    const bytes = await readBytes(dataSocket.readable, limit);
    await dataSocket.close();
    this.expect(await this.reply(), [226, 250]);
    return bytes;
  }

  private async passiveEndpoint(): Promise<{ hostname: string; port: number }> {
    const epsv = await this.command("EPSV");
    if (epsv.code === 229) {
      const port = Number(epsv.lines.join(" ").match(/\(\|\|\|(\d+)\|\)/u)?.[1]);
      if (Number.isInteger(port) && port > 0 && port <= 65_535) return { hostname: this.host, port };
    }

    const pasv = await this.command("PASV");
    this.expect(pasv, [227]);
    const values = pasv.lines.join(" ").match(/\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)/u);
    const high = Number(values?.[5]);
    const low = Number(values?.[6]);
    const port = high * 256 + low;
    if (!Number.isInteger(port) || port <= 0 || port > 65_535) {
      throw new Error("Darwin FTP returned an invalid passive port");
    }
    return { hostname: this.host, port };
  }

  private async command(value: string): Promise<FTPReply> {
    await this.writer.write(encoder.encode(`${value}\r\n`));
    return this.reply();
  }

  private async reply(): Promise<FTPReply> {
    const first = await this.line();
    const opening = first.match(/^(\d{3})([ -])/u);
    if (opening === null) throw new Error("Darwin FTP returned a malformed reply");
    const code = Number(opening[1]);
    const lines = [first];
    if (opening[2] === "-") {
      while (true) {
        const next = await this.line();
        lines.push(next);
        if (next.startsWith(`${code} `)) break;
      }
    }
    return { code, lines };
  }

  private async line(): Promise<string> {
    while (true) {
      const newline = this.buffer.indexOf("\n");
      if (newline >= 0) {
        const result = this.buffer.slice(0, newline).replace(/\r$/u, "");
        this.buffer = this.buffer.slice(newline + 1);
        return result;
      }
      const value = await this.reader.read();
      if (value.done) throw new Error("Darwin FTP control connection closed unexpectedly");
      this.buffer += this.decoder.decode(value.value, { stream: true });
    }
  }

  private expect(reply: FTPReply, expected: number[]): void {
    if (!expected.includes(reply.code)) {
      throw new Error(`Darwin FTP command failed with reply ${reply.code}`);
    }
  }
}
