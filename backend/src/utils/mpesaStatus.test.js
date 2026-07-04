const {
  isAmbiguousMpesaDescription,
  normalizeMpesaCallbackStatus,
} = require('./mpesaStatus');

describe('mpesaStatus', () => {
  describe('isAmbiguousMpesaDescription', () => {
    test('returns true for unresolved reason type', () => {
      expect(isAmbiguousMpesaDescription('Unresolved Reason Type')).toBe(true);
    });

    test('returns true for unresolve issue typo variant', () => {
      expect(isAmbiguousMpesaDescription('Request failed due to unresolve issue')).toBe(true);
    });

    test('returns false for normal failure text', () => {
      expect(isAmbiguousMpesaDescription('Invalid initiator information')).toBe(false);
    });
  });

  describe('normalizeMpesaCallbackStatus', () => {
    test('maps result code 0 to completed', () => {
      expect(normalizeMpesaCallbackStatus('0', 'Success')).toBe('completed');
    });

    test('maps result code 1032 to cancelled', () => {
      expect(normalizeMpesaCallbackStatus('1032', 'Request cancelled by user')).toBe('cancelled');
    });

    test('maps ambiguous unresolved description to pending', () => {
      expect(normalizeMpesaCallbackStatus('1', 'Unresolved reason type')).toBe('pending');
    });

    test('maps other non-success callback outcomes to failed', () => {
      expect(normalizeMpesaCallbackStatus('1', 'The initiator information is invalid')).toBe('failed');
    });
  });
});
