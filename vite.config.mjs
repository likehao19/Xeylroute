import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [{
    name: 'resolve-liquid-glass-worker',
    enforce: 'pre',
    transform(code, id) {
      if (id.endsWith('/@wxperia/liquid-glass-vue/dist/index.js')) {
        // Version 1.0.9 publishes the worker beside index.js but points Vite at the app root.
        return code.replace('"/assets/shader-worker-', '"./assets/shader-worker-');
      }
    },
  }],
});
