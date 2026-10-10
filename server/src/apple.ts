import 'reflect-metadata';
import { X509Certificate } from '@peculiar/x509';
import { base64ToBytes, sha256Hex } from './env';

/** SHA-256 of Apple Root CA - G3, the root every App Store signature chains up to. */
export const APPLE_ROOT_G3 = '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179';
/** Marks a certificate as Apple's for signing App Store data (the leaf), and as its intermediate. */
const LEAF_OID = '1.2.840.113635.100.6.11.1';
const INTERMEDIATE_OID = '1.2.840.113635.100.6.2.1';

export class SignatureError extends Error {}

function decodeText(part: string): string {
  return new TextDecoder().decode(base64ToBytes(part));
}

/**
 * The payload of something the App Store signed (a transaction, a notification), once its signature is checked: the
 * certificates it carries must chain up to Apple's root, and its leaf must have signed it. StoreKit testing in Xcode
 * signs with a certificate of its own, accepted only when `allowXcode` (local development).
 */
export async function verifySigned(jws: string, options: { allowXcode: boolean; root?: string }): Promise<any> {
  const [header64, payload64, signature64] = jws.split('.');
  if (!header64 || !payload64 || !signature64) throw new SignatureError('Not a signed payload.');
  const header = JSON.parse(decodeText(header64));
  const payload = JSON.parse(decodeText(payload64));
  if (header.alg !== 'ES256' || !Array.isArray(header.x5c) || header.x5c.length === 0) {
    throw new SignatureError('Unexpected signature format.');
  }
  const chain = (header.x5c as string[]).map((der) => new X509Certificate(base64ToBytes(der)));
  const xcode = payload.environment === 'Xcode' || payload.environment === 'LocalTesting'
    || payload.data?.environment === 'Xcode' || payload.data?.environment === 'LocalTesting';
  if (xcode) {
    if (!options.allowXcode) throw new SignatureError('Signed by Xcode, outside local development.');
  } else {
    if (chain.length !== 3) throw new SignatureError('Unexpected certificate chain.');
    const [leaf, intermediate, root] = chain;
    if ((await sha256Hex(new Uint8Array(root.rawData))) !== (options.root ?? APPLE_ROOT_G3)) {
      throw new SignatureError('Not signed by Apple.');
    }
    const date = new Date(payload.signedDate ?? Date.now());
    if (!(await intermediate.verify({ publicKey: root.publicKey, date }))
      || !(await leaf.verify({ publicKey: intermediate.publicKey, date }))) {
      throw new SignatureError('The certificate chain doesn’t hold.');
    }
    if (!leaf.getExtension(LEAF_OID) || !intermediate.getExtension(INTERMEDIATE_OID)) {
      throw new SignatureError('Not App Store certificates.');
    }
  }
  const key = await chain[0].publicKey.export({ name: 'ECDSA', namedCurve: 'P-256' }, ['verify']);
  const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, base64ToBytes(signature64),
    new TextEncoder().encode(`${header64}.${payload64}`));
  if (!valid) throw new SignatureError('The signature doesn’t match.');
  return payload;
}
