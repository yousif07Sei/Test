import { describe, expect, it } from 'vitest';
import { greeting } from './greeting';

describe('greeting', () => {
    it('follows the time of day', () => {
        expect(greeting(new Date(2026, 0, 1, 9))).toBe('Good morning');
        expect(greeting(new Date(2026, 0, 1, 14))).toBe('Good afternoon');
        expect(greeting(new Date(2026, 0, 1, 20))).toBe('Good evening');
    });
});
