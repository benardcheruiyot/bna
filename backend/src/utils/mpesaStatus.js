const AMBIGUOUS_RESULT_PATTERN = /(unresolved reason type|unresolve issue)/i;

function isAmbiguousMpesaDescription(text) {
  return AMBIGUOUS_RESULT_PATTERN.test(String(text || ''));
}

function normalizeMpesaCallbackStatus(resultCode, resultDesc) {
  const normalizedResultCode = String(resultCode ?? '');

  if (normalizedResultCode === '0') {
    return 'completed';
  }

  if (normalizedResultCode === '1032') {
    return 'cancelled';
  }

  if (isAmbiguousMpesaDescription(resultDesc)) {
    return 'pending';
  }

  return 'failed';
}

module.exports = {
  isAmbiguousMpesaDescription,
  normalizeMpesaCallbackStatus,
};