import dns from "node:dns/promises";
import http from "node:http";
import net from "node:net";
import process from "node:process";
import { pathToFileURL } from "node:url";

const HEADER_TIMEOUT_MS = 15_000;
const REQUEST_TIMEOUT_MS = 5 * 60_000;
const CONNECT_TIMEOUT_MS = 15_000;
const IDLE_TIMEOUT_MS = 5 * 60_000;

const IPV4_DENY_RANGES = [
  ["0.0.0.0", 8],
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["127.0.0.0", 8],
  ["168.63.129.16", 32],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.0.0.0", 24],
  ["192.0.2.0", 24],
  ["192.31.196.0", 24],
  ["192.52.193.0", 24],
  ["192.88.99.0", 24],
  ["192.168.0.0", 16],
  ["192.175.48.0", 24],
  ["198.18.0.0", 15],
  ["198.51.100.0", 24],
  ["203.0.113.0", 24],
  ["224.0.0.0", 4],
  ["240.0.0.0", 4],
];

const IPV6_DENY_RANGES = [
  ["::", 128],
  ["::1", 128],
  ["::ffff:0:0", 96],
  ["64:ff9b:1::", 48],
  ["100::", 64],
  ["2001::", 23],
  ["2001:db8::", 32],
  ["2002::", 16],
  ["2620:4f:8000::", 48],
  ["3fff::", 20],
  ["fc00::", 7],
  ["fe80::", 10],
  ["ff00::", 8],
];

const BLOCKED_EXACT_NAMES = new Set([
  "gateway.docker.internal",
  "host.containers.internal",
  "host.docker.internal",
  "instance-data",
  "kubernetes.docker.internal",
  "metadata.google.internal",
  "metadata.goog",
]);

const BLOCKED_NAME_SUFFIXES = [
  "localhost",
  ".localhost",
  ".local",
  ".internal",
  ".home.arpa",
  ".arpa",
  ".alt",
  ".invalid",
  ".onion",
  ".test",
  ".example",
];

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

const STATUS_TEXT = new Map([
  [400, "Bad Request"],
  [403, "Forbidden"],
  [405, "Method Not Allowed"],
  [417, "Expectation Failed"],
  [431, "Request Header Fields Too Large"],
  [502, "Bad Gateway"],
  [504, "Gateway Timeout"],
]);

export class ProxyPolicyError extends Error {
  constructor(statusCode, code) {
    super(code);
    this.name = "ProxyPolicyError";
    this.statusCode = statusCode;
    this.code = code;
  }
}

function ipv4ToBigInt(address) {
  if (!net.isIPv4(address)) {
    throw new TypeError("not-ipv4");
  }
  return address
    .split(".")
    .map((part) => BigInt(Number(part)))
    .reduce((value, part) => (value << 8n) | part, 0n);
}

function ipv6ToBigInt(address) {
  if (!net.isIPv6(address) || address.includes("%")) {
    throw new TypeError("not-ipv6");
  }

  let normalized = address.toLowerCase();
  const embeddedIpv4 = normalized.match(/(?:^|:)(\d+\.\d+\.\d+\.\d+)$/);
  if (embeddedIpv4) {
    const ipv4 = ipv4ToBigInt(embeddedIpv4[1]);
    const high = Number((ipv4 >> 16n) & 0xffffn).toString(16);
    const low = Number(ipv4 & 0xffffn).toString(16);
    normalized = normalized.slice(0, -embeddedIpv4[1].length) + `${high}:${low}`;
  }

  const halves = normalized.split("::");
  if (halves.length > 2) {
    throw new TypeError("invalid-ipv6");
  }
  const left = halves[0] ? halves[0].split(":") : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const missing = 8 - left.length - right.length;
  if ((halves.length === 1 && missing !== 0) || (halves.length === 2 && missing < 1)) {
    throw new TypeError("invalid-ipv6");
  }
  const groups = [...left, ...Array(missing).fill("0"), ...right];
  if (groups.length !== 8 || groups.some((group) => !/^[0-9a-f]{1,4}$/.test(group))) {
    throw new TypeError("invalid-ipv6");
  }
  return groups.reduce((value, group) => (value << 16n) | BigInt(`0x${group}`), 0n);
}

function isInCidr(value, base, prefixLength, totalBits) {
  const shift = BigInt(totalBits - prefixLength);
  return (value >> shift) === (base >> shift);
}

const IPV4_DENY = IPV4_DENY_RANGES.map(([address, prefix]) => [
  ipv4ToBigInt(address),
  prefix,
]);
const IPV6_DENY = IPV6_DENY_RANGES.map(([address, prefix]) => [
  ipv6ToBigInt(address),
  prefix,
]);
const IPV6_GLOBAL_BASE = ipv6ToBigInt("2000::");

export function isPublicAddress(address) {
  if (net.isIPv4(address)) {
    const value = ipv4ToBigInt(address);
    return !IPV4_DENY.some(([base, prefix]) =>
      isInCidr(value, base, prefix, 32),
    );
  }
  if (net.isIPv6(address) && !address.includes("%")) {
    const value = ipv6ToBigInt(address);
    if (!isInCidr(value, IPV6_GLOBAL_BASE, 3, 128)) {
      return false;
    }
    return !IPV6_DENY.some(([base, prefix]) =>
      isInCidr(value, base, prefix, 128),
    );
  }
  return false;
}

function normalizeHostSyntax(hostname, allowSingleLabel = false) {
  let host = String(hostname).trim().toLowerCase();
  if (host.startsWith("[") && host.endsWith("]")) {
    host = host.slice(1, -1);
  }
  if (host.endsWith(".")) {
    host = host.slice(0, -1);
  }
  if (!host || host.length > 253 || /[\s/@\\]/.test(host)) {
    throw new ProxyPolicyError(400, "invalid-target-host");
  }
  if (net.isIP(host)) {
    return host;
  }
  if (!allowSingleLabel && !host.includes(".")) {
    throw new ProxyPolicyError(403, "single-label-target-blocked");
  }
  const labels = host.split(".");
  if (
    labels.some(
      (label) =>
        !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label),
    )
  ) {
    throw new ProxyPolicyError(400, "invalid-target-host");
  }
  return host;
}

function normalizeTargetHost(hostname) {
  const host = normalizeHostSyntax(hostname);
  if (BLOCKED_EXACT_NAMES.has(host)) {
    throw new ProxyPolicyError(403, "platform-hostname-blocked");
  }
  if (BLOCKED_NAME_SUFFIXES.some((suffix) => host === suffix || host.endsWith(suffix))) {
    throw new ProxyPolicyError(403, "special-use-name-blocked");
  }
  return host;
}

export function createDenyPolicy(hosts) {
  const normalized = [];
  const seen = new Set();
  for (const value of hosts ?? []) {
    if (String(value).trim() === "") {
      continue;
    }
    const host = normalizeHostSyntax(value, true);
    if (!seen.has(host)) {
      seen.add(host);
      normalized.push(host);
    }
  }
  return Object.freeze({ hosts: Object.freeze(normalized) });
}

async function lookupAddresses(host, lookup, failureCode) {
  let answers;
  if (net.isIP(host)) {
    answers = [{ address: host, family: net.isIPv4(host) ? 4 : 6 }];
  } else {
    try {
      answers = await lookup(host, { all: true, verbatim: true });
    } catch {
      throw new ProxyPolicyError(502, failureCode);
    }
  }

  const unique = [];
  const seen = new Set();
  for (const answer of answers ?? []) {
    const address = String(answer.address ?? "").toLowerCase();
    const family = Number(answer.family);
    if ((family !== 4 && family !== 6) || net.isIP(address) !== family) {
      throw new ProxyPolicyError(502, "invalid-dns-answer");
    }
    if (!seen.has(address)) {
      seen.add(address);
      unique.push({ address, family });
    }
  }
  if (unique.length === 0) {
    throw new ProxyPolicyError(502, failureCode);
  }
  return unique;
}

async function resolveConfiguredDenyAddresses(denyPolicy, lookup) {
  const denied = new Set();
  for (const host of denyPolicy.hosts) {
    const answers = await lookupAddresses(
      host,
      lookup,
      "configured-deny-resolution-failed",
    );
    for (const { address } of answers) {
      denied.add(address);
    }
  }
  return denied;
}

const configuredDenyHosts = (process.env.CONTROLLED_WEB_DENY_HOSTS ?? "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const ACTIVE_DENY_POLICY = createDenyPolicy(configuredDenyHosts);

export async function resolvePublicTarget(hostname, options = {}) {
  if (typeof options === "function") {
    options = { lookup: options };
  }
  const lookup = options.lookup ?? dns.lookup;
  const denyPolicy = options.denyPolicy ?? ACTIVE_DENY_POLICY;
  const host = normalizeTargetHost(hostname);
  if (denyPolicy.hosts.includes(host)) {
    throw new ProxyPolicyError(403, "configured-host-blocked");
  }

  const addresses = await lookupAddresses(host, lookup, "target-dns-failed");
  if (addresses.some(({ address }) => !isPublicAddress(address))) {
    throw new ProxyPolicyError(403, "non-public-target-blocked");
  }

  const deniedAddresses = await resolveConfiguredDenyAddresses(denyPolicy, lookup);
  if (addresses.some(({ address }) => deniedAddresses.has(address))) {
    throw new ProxyPolicyError(403, "configured-host-address-blocked");
  }
  return { host, addresses };
}

export function parseConnectAuthority(authority) {
  let match;
  if (authority.startsWith("[")) {
    match = authority.match(/^\[([^\]]+)\]:(\d{1,5})$/);
  } else {
    match = authority.match(/^([^:]+):(\d{1,5})$/);
  }
  if (!match) {
    throw new ProxyPolicyError(400, "invalid-connect-authority");
  }
  const port = Number(match[2]);
  if (port !== 443) {
    throw new ProxyPolicyError(403, "connect-port-blocked");
  }
  return { host: normalizeTargetHost(match[1]), port };
}

export function parseHttpTarget(rawTarget) {
  let target;
  try {
    target = new URL(rawTarget);
  } catch {
    throw new ProxyPolicyError(400, "absolute-http-uri-required");
  }
  if (target.protocol !== "http:") {
    throw new ProxyPolicyError(403, "http-scheme-required");
  }
  if (target.username || target.password || target.hash) {
    throw new ProxyPolicyError(400, "target-userinfo-or-fragment-blocked");
  }
  const port = target.port ? Number(target.port) : 80;
  if (port !== 80) {
    throw new ProxyPolicyError(403, "http-port-blocked");
  }
  const host = normalizeTargetHost(target.hostname);
  const originForm = `${target.pathname || "/"}${target.search}`;
  return { host, port, originForm, hostHeader: target.host };
}

function rawHeaderEntries(request) {
  if (request.rawHeaders.length % 2 !== 0) {
    throw new ProxyPolicyError(400, "invalid-request-header");
  }
  const entries = [];
  for (let index = 0; index < request.rawHeaders.length; index += 2) {
    const name = request.rawHeaders[index];
    const value = request.rawHeaders[index + 1];
    if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) || /[\0\r\n]/.test(value)) {
      throw new ProxyPolicyError(400, "invalid-request-header");
    }
    entries.push({ name, lowerName: name.toLowerCase(), value });
  }
  return entries;
}

function inspectRequestHeaders(request) {
  const entries = rawHeaderEntries(request);
  const valuesByName = new Map();
  for (const entry of entries) {
    const values = valuesByName.get(entry.lowerName) ?? [];
    values.push(entry.value.trim());
    valuesByName.set(entry.lowerName, values);
  }

  const hostValues = valuesByName.get("host") ?? [];
  const contentLengths = valuesByName.get("content-length") ?? [];
  const transferEncodings = valuesByName.get("transfer-encoding") ?? [];
  if (hostValues.length !== 1) {
    throw new ProxyPolicyError(400, "exactly-one-host-header-required");
  }
  if (
    contentLengths.length > 1 ||
    transferEncodings.length > 1 ||
    (contentLengths.length && transferEncodings.length)
  ) {
    throw new ProxyPolicyError(400, "ambiguous-request-framing");
  }
  if (contentLengths.length && !/^\d+$/.test(contentLengths[0])) {
    throw new ProxyPolicyError(400, "invalid-content-length");
  }
  if (
    transferEncodings.length &&
    transferEncodings[0].toLowerCase() !== "chunked"
  ) {
    throw new ProxyPolicyError(400, "unsupported-transfer-encoding");
  }
  if (valuesByName.has("upgrade")) {
    throw new ProxyPolicyError(403, "protocol-upgrade-blocked");
  }

  const connectionTokens = new Set();
  for (const headerName of ["connection", "proxy-connection"]) {
    for (const value of valuesByName.get(headerName) ?? []) {
      for (const token of value.split(",").map((item) => item.trim().toLowerCase())) {
        if (!token || !/^[!#$%&'*+.^_`|~0-9a-z-]+$/.test(token)) {
          throw new ProxyPolicyError(400, "invalid-connection-token");
        }
        connectionTokens.add(token);
      }
    }
  }
  return { entries, hostHeader: hostValues[0], connectionTokens };
}

function parseHostHeader(value, expectedPort) {
  let match;
  if (value.startsWith("[")) {
    match = value.match(/^\[([^\]]+)\](?::(\d{1,5}))?$/);
  } else {
    match = value.match(/^([^:]+)(?::(\d{1,5}))?$/);
  }
  if (!match) {
    throw new ProxyPolicyError(400, "invalid-host-header");
  }
  const port = match[2] ? Number(match[2]) : expectedPort;
  if (port !== expectedPort) {
    throw new ProxyPolicyError(400, "host-header-port-mismatch");
  }
  return { host: normalizeTargetHost(match[1]), port };
}

function assertMatchingHostHeader(headerValue, target) {
  const header = parseHostHeader(headerValue, target.port);
  if (header.host !== target.host || header.port !== target.port) {
    throw new ProxyPolicyError(400, "host-header-target-mismatch");
  }
}

function sanitizedRequestHeaders(headerInspection, target) {
  const blocked = new Set([
    ...HOP_BY_HOP_HEADERS,
    ...headerInspection.connectionTokens,
    "expect",
    "host",
  ]);
  const output = { Host: target.hostHeader, Connection: "close" };
  for (const { name, lowerName, value } of headerInspection.entries) {
    if (blocked.has(lowerName)) {
      continue;
    }
    if (Object.hasOwn(output, name)) {
      output[name] = `${output[name]}, ${value}`;
    } else {
      output[name] = value;
    }
  }
  return output;
}

function sanitizedResponseHeaders(proxyResponse) {
  const blocked = new Set(HOP_BY_HOP_HEADERS);
  for (const value of proxyResponse.headers.connection?.split(",") ?? []) {
    const token = value.trim().toLowerCase();
    if (token) {
      blocked.add(token);
    }
  }
  const output = { Connection: "close" };
  for (let index = 0; index < proxyResponse.rawHeaders.length; index += 2) {
    const name = proxyResponse.rawHeaders[index];
    const lowerName = name.toLowerCase();
    const value = proxyResponse.rawHeaders[index + 1];
    if (blocked.has(lowerName)) {
      continue;
    }
    if (Object.hasOwn(output, name)) {
      const existing = output[name];
      output[name] = Array.isArray(existing)
        ? [...existing, value]
        : [existing, value];
    } else {
      output[name] = value;
    }
  }
  return output;
}

function policyStatus(error) {
  return error instanceof ProxyPolicyError
    ? { statusCode: error.statusCode, code: error.code }
    : { statusCode: 502, code: "upstream-failed" };
}

function writeHttpError(response, error) {
  if (response.destroyed || response.writableEnded) {
    response.destroy();
    return;
  }
  if (response.headersSent) {
    response.destroy();
    return;
  }
  const { statusCode, code } = policyStatus(error);
  const statusText = STATUS_TEXT.get(statusCode) ?? "Proxy Error";
  const body = `${statusCode} ${statusText}\n${code}\n`;
  response.shouldKeepAlive = false;
  response.writeHead(statusCode, statusText, {
    "Content-Type": "text/plain; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    Connection: "close",
  });
  response.end(body);
}

function writeSocketError(socket, error) {
  if (socket.destroyed || socket.writableEnded || !socket.writable) {
    socket.destroy();
    return;
  }
  const { statusCode, code } = policyStatus(error);
  const statusText = STATUS_TEXT.get(statusCode) ?? "Proxy Error";
  const body = `${statusCode} ${statusText}\n${code}\n`;
  socket.end(
    `HTTP/1.1 ${statusCode} ${statusText}\r\n` +
      "Content-Type: text/plain; charset=utf-8\r\n" +
      `Content-Length: ${Buffer.byteLength(body)}\r\n` +
      "Connection: close\r\n\r\n" +
      body,
  );
}

async function connectToValidatedTarget(host, port) {
  const resolved = await resolvePublicTarget(host);
  let lastError;
  for (const candidate of resolved.addresses) {
    try {
      return await new Promise((resolve, reject) => {
        const upstream = net.createConnection({
          host: candidate.address,
          family: candidate.family,
          port,
        });
        const timer = setTimeout(() => {
          upstream.destroy();
          reject(new ProxyPolicyError(504, "upstream-connect-timeout"));
        }, CONNECT_TIMEOUT_MS);
        upstream.once("connect", () => {
          clearTimeout(timer);
          upstream.setTimeout(IDLE_TIMEOUT_MS, () => upstream.destroy());
          resolve(upstream);
        });
        upstream.once("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
      });
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new ProxyPolicyError(502, "upstream-connect-failed");
}

async function handleHttpRequest(request, response) {
  try {
    const target = parseHttpTarget(request.url);
    const headerInspection = inspectRequestHeaders(request);
    assertMatchingHostHeader(headerInspection.hostHeader, target);
    const upstreamSocket = await connectToValidatedTarget(target.host, target.port);
    const upstreamAgent = new http.Agent({ keepAlive: false, maxSockets: 1 });
    upstreamAgent.createConnection = () => upstreamSocket;
    const upstreamRequest = http.request({
      hostname: target.host,
      port: target.port,
      method: request.method,
      path: target.originForm,
      headers: sanitizedRequestHeaders(headerInspection, target),
      agent: upstreamAgent,
    });
    upstreamRequest.once("response", (upstreamResponse) => {
      response.shouldKeepAlive = false;
      response.writeHead(
        upstreamResponse.statusCode ?? 502,
        upstreamResponse.statusMessage,
        sanitizedResponseHeaders(upstreamResponse),
      );
      upstreamResponse.pipe(response);
      upstreamResponse.once("end", () => upstreamAgent.destroy());
    });
    upstreamRequest.once("error", (error) => {
      console.warn(
        `controlled-web-v1 upstream HTTP error: ${error.code ?? "unknown"}`,
      );
      upstreamAgent.destroy();
      writeHttpError(response, error);
    });
    request.once("aborted", () => {
      upstreamRequest.destroy();
      upstreamAgent.destroy();
    });
    request.pipe(upstreamRequest);
  } catch (error) {
    request.resume();
    writeHttpError(response, error);
  }
}

async function handleConnect(request, client, head) {
  client.on("error", () => {});
  try {
    const target = parseConnectAuthority(request.url);
    const headerInspection = inspectRequestHeaders(request);
    assertMatchingHostHeader(headerInspection.hostHeader, target);
    const upstream = await connectToValidatedTarget(target.host, target.port);
    client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    if (head.length) {
      upstream.write(head);
    }
    client.setTimeout(IDLE_TIMEOUT_MS, () => client.destroy());
    client.on("error", () => upstream.destroy());
    upstream.on("error", () => client.destroy());
    client.pipe(upstream);
    upstream.pipe(client);
  } catch (error) {
    writeSocketError(client, error);
  }
}

export function startProxy() {
  if (ACTIVE_DENY_POLICY.hosts.length === 0) {
    throw new Error("CONTROLLED_WEB_DENY_HOSTS is required");
  }
  const host = process.env.CONTROLLED_WEB_LISTEN_HOST ?? "0.0.0.0";
  const port = Number(process.env.CONTROLLED_WEB_LISTEN_PORT ?? "3128");
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("invalid-listen-port");
  }

  const server = http.createServer((request, response) => {
    void handleHttpRequest(request, response);
  });
  server.on("connect", (request, client, head) => {
    void handleConnect(request, client, head);
  });
  server.on("upgrade", (_request, socket) => {
    writeSocketError(socket, new ProxyPolicyError(403, "protocol-upgrade-blocked"));
  });
  server.on("clientError", (error, socket) => {
    const status = error.code === "HPE_HEADER_OVERFLOW" ? 431 : 400;
    writeSocketError(socket, new ProxyPolicyError(status, "http-parser-rejected-request"));
  });
  server.on("error", (error) => {
    console.error(`controlled-web-v1 fatal: ${error.code ?? "listen-error"}`);
    process.exitCode = 1;
  });
  server.headersTimeout = HEADER_TIMEOUT_MS;
  server.requestTimeout = REQUEST_TIMEOUT_MS;
  server.keepAliveTimeout = 1_000;
  server.maxRequestsPerSocket = 1;
  server.maxConnections = 128;
  server.listen(port, host, () => {
    console.log(`controlled-web-v1 listening on ${host}:${port}`);
  });
  return server;
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : "";
if (import.meta.url === invokedPath) {
  startProxy();
}
