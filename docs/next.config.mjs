import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const config = {
  reactStrictMode: true,
  async redirects() {
    return [
      { source: '/', destination: '/docs', permanent: false },
      // the published resources/design.html; its relative image paths need the file URL
      { source: '/overview', destination: '/overview/index.html', permanent: false },
      // folders without an index page, and pages merged into others
      { source: '/docs/ui', destination: '/docs/ui/window', permanent: false },
      { source: '/docs/reference', destination: '/docs/reference/glossary', permanent: false },
      { source: '/docs/ui/chat-card', destination: '/docs/ui/window#pane-card-in-chat-view', permanent: true },
      { source: '/docs/ui/zoom', destination: '/docs/ui/window#zoom', permanent: true },
      { source: '/docs/ui/theme', destination: '/docs/ui/theme-and-accessibility', permanent: true },
      { source: '/docs/ui/accessibility', destination: '/docs/ui/theme-and-accessibility#accessibility', permanent: true },
    ];
  },
};

export default withMDX(config);
