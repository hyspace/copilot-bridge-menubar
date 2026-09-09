import { timingSafeEqual } from "node:crypto";

/** Used by the small, build-time patch to the pinned CLI server. Never forward this key upstream. */
export function validBridgeKey(candidate: string | undefined, expected: string): boolean {
  if (!candidate) return false;
  const left = Buffer.from(candidate), right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}
