function fail(message) {
  throw new Error(`HomeClaw freshness contract violation: ${message}`);
}

function isTimestamp(value) {
  return typeof value === 'string'
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(value)
    && !Number.isNaN(Date.parse(value));
}

/**
 * Validates the producer's get_accessory freshness contract.
 * Returns true for a fresh payload and false only for explicit no-refresh data.
 */
export function validateFreshAccessoryPayload(payload, { allowStale = false } = {}) {
  if (!payload || typeof payload !== 'object') fail('response data is missing');

  const { refreshed, read_attempted: attempted, read_succeeded: succeeded } = payload;
  if (!Number.isInteger(attempted) || !Number.isInteger(succeeded)) {
    fail('read counts are missing or malformed');
  }

  if (allowStale) {
    if (refreshed !== false || attempted !== 0 || succeeded !== 0) {
      fail('invalid no-refresh response');
    }
    return false;
  }

  if (refreshed !== true || attempted <= 0 || succeeded !== attempted) {
    fail('live refresh failed; values may be last-known');
  }
  if (!Array.isArray(payload.services)) fail('services are missing');

  const reads = payload.services.flatMap((service) => {
    if (!Array.isArray(service?.characteristics)) return [];
    return service.characteristics
      .filter((characteristic) => Object.hasOwn(characteristic, 'read'))
      .map((characteristic) => characteristic.read);
  });
  if (reads.length !== attempted) fail('characteristic read count is inconsistent');

  for (const read of reads) {
    if (read?.succeeded !== true || !isTimestamp(read.observed_at)) {
      fail('characteristic attestation is invalid');
    }
  }
  return true;
}
