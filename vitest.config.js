import { defineConfig } from 'vitest/config';

// Separate from vite.config.js on purpose: laravel-vite-plugin refuses to
// start its dev server under CI, and the unit tests need none of it.
export default defineConfig({
    test: {
        include: ['resources/js/**/*.test.js'],
    },
});
