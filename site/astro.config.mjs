import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://homeclaw.omarknows.app',
  base: '/',
  output: 'static',
  // @astrojs/tailwind is capped at astro ^5 and has no newer release, so it
  // blocks every astro major. Tailwind 4 ships its own Vite plugin instead.
  vite: {
    plugins: [tailwindcss()],
    // Emit every script as a file. Astro otherwise inlines small ones, and the
    // Content-Security-Policy in public/_headers allows only same-origin scripts.
    build: { assetsInlineLimit: 0 },
  },
});
