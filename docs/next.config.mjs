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
    ];
  },
};

export default withMDX(config);
