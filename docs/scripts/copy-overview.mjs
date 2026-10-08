// Publish resources/design.html (and the images it uses) at /overview/ without keeping a copy in git.
import { cpSync, mkdirSync, rmSync } from 'node:fs';

const src = new URL('../../resources/', import.meta.url);
const out = new URL('../public/overview/', import.meta.url);
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync(new URL('design.html', src), new URL('index.html', out));
cpSync(new URL('inspirations/selected/', src), new URL('inspirations/selected/', out), { recursive: true });
