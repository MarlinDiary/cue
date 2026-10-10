// Checks App Store signature verification and the purchase and refund routes against `wrangler dev` on :8787:
//   npx esbuild test/purchase.test.ts --bundle --platform=node --format=esm --outfile=.wrangler/purchase.test.mjs && node .wrangler/purchase.test.mjs
import 'reflect-metadata';
import * as x509 from '@peculiar/x509';
import { verifySigned } from '../src/apple';
import { sha256Hex } from '../src/env';

const base = 'http://127.0.0.1:8787';
const P256 = { name: 'ECDSA', namedCurve: 'P-256' } as const;
const P384 = { name: 'ECDSA', namedCurve: 'P-384' } as const;
let failures = 0;
const check = (ok: boolean, what: string) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) failures++;
};

const b64url = (data: ArrayBuffer | Uint8Array | string) => {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data);
  return Buffer.from(bytes).toString('base64url');
};
const der64 = (cert: x509.X509Certificate) => Buffer.from(cert.rawData).toString('base64');

async function sign(payload: object, chain: x509.X509Certificate[], key: CryptoKey): Promise<string> {
  const head = b64url(JSON.stringify({ alg: 'ES256', x5c: chain.map(der64) }));
  const body = b64url(JSON.stringify(payload));
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(signature)}`;
}

async function certificate(subject: string, keys: CryptoKeyPair, issuer: { name: string; keys: CryptoKeyPair },
  algorithm: object, extensions: x509.Extension[] = []) {
  return x509.X509CertificateGenerator.create({
    serialNumber: String(Math.floor(Math.random() * 1e9)),
    subject, issuer: issuer.name, notBefore: new Date(Date.now() - 86_400_000), notAfter: new Date(Date.now() + 86_400_000),
    publicKey: keys.publicKey, signingKey: issuer.keys.privateKey, signingAlgorithm: algorithm, extensions,
  });
}

const account = (id: string, secret: string) => ({ Authorization: `Bearer ${id}.${secret.repeat(43)}`, 'Content-Type': 'application/json' });
const post = (path: string, headers: object, body: object) =>
  fetch(base + path, { method: 'POST', headers: headers as any, body: JSON.stringify(body) }).then(async (r) => ({ status: r.status, body: await r.json() as any }));

// An App Store-like chain: a P-384 root, an intermediate and a P-256 leaf carrying Apple's marks.
const rootKeys = await crypto.subtle.generateKey(P384, true, ['sign', 'verify']) as CryptoKeyPair;
const midKeys = await crypto.subtle.generateKey(P384, true, ['sign', 'verify']) as CryptoKeyPair;
const leafKeys = await crypto.subtle.generateKey(P256, true, ['sign', 'verify']) as CryptoKeyPair;
const sha384 = { name: 'ECDSA', hash: 'SHA-384' };
const root = await certificate('CN=Test Root', rootKeys, { name: 'CN=Test Root', keys: rootKeys }, sha384);
const mid = await certificate('CN=Test Intermediate', midKeys, { name: 'CN=Test Root', keys: rootKeys }, sha384,
  [new x509.Extension('1.2.840.113635.100.6.2.1', false, new Uint8Array([5, 0]))]);
const leaf = await certificate('CN=Test Leaf', leafKeys, { name: 'CN=Test Intermediate', keys: midKeys }, sha384,
  [new x509.Extension('1.2.840.113635.100.6.11.1', false, new Uint8Array([5, 0]))]);
const rootHash = await sha256Hex(new Uint8Array(root.rawData));
const sandbox = { transactionId: '2000000002', productId: 'com.chenye.cue.points.20', bundleId: 'com.chenye.cue',
  appAccountToken: 'b4444444-4444-4444-8444-444444444444', environment: 'Sandbox', type: 'Consumable', signedDate: Date.now() };
const signed = await sign(sandbox, [leaf, mid, root], leafKeys.privateKey);

check((await verifySigned(signed, { allowXcode: false, root: rootHash })).transactionId === '2000000002', 'a chain up to the root verifies');
check(await verifySigned(signed, { allowXcode: false }).then(() => false, (e) => /Not signed by Apple/.test(e.message)), 'another root is refused');
const otherKeys = await crypto.subtle.generateKey(P256, true, ['sign', 'verify']) as CryptoKeyPair;
const forged = await sign(sandbox, [leaf, mid, root], otherKeys.privateKey);
check(await verifySigned(forged, { allowXcode: false, root: rootHash }).then(() => false, (e) => /signature/.test(e.message)), 'a forged signature is refused');
const unmarkedLeaf = await certificate('CN=Plain Leaf', leafKeys, { name: 'CN=Test Intermediate', keys: midKeys }, sha384);
const unmarked = await sign(sandbox, [unmarkedLeaf, mid, root], leafKeys.privateKey);
check(await verifySigned(unmarked, { allowXcode: false, root: rootHash }).then(() => false, (e) => /App Store/.test(e.message)), 'a leaf without Apple’s mark is refused');

// Xcode's StoreKit testing signs with a certificate of its own, accepted by the local server.
const xcodeKeys = await crypto.subtle.generateKey(P256, true, ['sign', 'verify']) as CryptoKeyPair;
const xcodeCert = await certificate('CN=StoreKit Testing in Xcode', xcodeKeys, { name: 'CN=StoreKit Testing in Xcode', keys: xcodeKeys }, { name: 'ECDSA', hash: 'SHA-256' });
const buyer = account('b4444444-4444-4444-8444-444444444444', 'd');
const xcodeTransaction = { ...sandbox, transactionId: '9000000002', environment: 'Xcode' };
const jws = await sign(xcodeTransaction, [xcodeCert], xcodeKeys.privateKey);
const first = await post('/v1/purchase', buyer, { transaction: jws });
check(first.status === 200 && first.body.points === 20, `a purchase gives 20 points (${JSON.stringify(first.body)})`);
const again = await post('/v1/purchase', buyer, { transaction: jws });
check(again.status === 200 && again.body.points === 20, 'the same purchase sent again gives nothing more');
const thief = await post('/v1/purchase', account('b5555555-5555-4555-8555-555555555555', 'e'), { transaction: jws });
check(thief.status === 400 && thief.body.error.code === 'bad_transaction', 'another account can’t claim it');
const sandboxAtServer = await post('/v1/purchase', buyer, { transaction: signed });
check(sandboxAtServer.status === 400 && /Not signed by Apple/.test(sandboxAtServer.body.error.message), 'a transaction not from Apple is refused');

// A refund takes the points back.
const notification = await sign({ notificationType: 'REFUND', data: { environment: 'Xcode', bundleId: 'com.chenye.cue',
  signedTransactionInfo: jws }, signedDate: Date.now() }, [xcodeCert], xcodeKeys.privateKey);
const refunded = await post('/v1/apple/notifications', {}, { signedPayload: notification });
check(refunded.status === 200, 'the refund notification is taken');
const after = await fetch(`${base}/v1/account`, { headers: buyer as any }).then((r) => r.json() as any);
check(after.points === 0, `the refunded points are gone (${after.points})`);
const twice = await post('/v1/apple/notifications', {}, { signedPayload: notification });
const still = await fetch(`${base}/v1/account`, { headers: buyer as any }).then((r) => r.json() as any);
check(twice.status === 200 && still.points === 0, 'a refund told twice takes them once');

console.log(failures ? `${failures} failed` : 'all passed');
process.exit(failures ? 1 : 0);
