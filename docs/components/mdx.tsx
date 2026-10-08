import defaultMdxComponents from 'fumadocs-ui/mdx';
import { Step, Steps } from 'fumadocs-ui/components/steps';
import { Tab, Tabs } from 'fumadocs-ui/components/tabs';
import type { MDXComponents } from 'mdx/types';
import './design/design.css';
import { MacWindow } from './design/mac-window';
import { PillCard, PillsDemo } from './design/pills-demo';
import { SplitDemo } from './design/split-demo';
import { SwipeDiagram } from './design/swipe-diagram';
import { AddMachineSheet, ChatCard, DropZones, PanePicker, Phones } from './design/mocks';
import { Architecture, Flow, Ownership } from './design/diagrams';

export function getMDXComponents(components?: MDXComponents) {
  return {
    ...defaultMdxComponents,
    Step,
    Steps,
    Tab,
    Tabs,
    MacWindow,
    PillsDemo,
    PillCard,
    SplitDemo,
    SwipeDiagram,
    AddMachineSheet,
    ChatCard,
    DropZones,
    PanePicker,
    Phones,
    Architecture,
    Flow,
    Ownership,
    ...components,
  } satisfies MDXComponents;
}

export const useMDXComponents = getMDXComponents;

declare global {
  type MDXProvidedComponents = ReturnType<typeof getMDXComponents>;
}
