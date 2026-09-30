/** The line the page shows under the release. Small on purpose: it exists so Vitest has something real to test. */
export function greeting(date = new Date()) {
    const hour = date.getHours();
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';

    return 'Good evening';
}
