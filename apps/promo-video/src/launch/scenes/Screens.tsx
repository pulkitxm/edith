import React from 'react';
import {useCurrentFrame, useVideoConfig} from 'remotion';
import {ScreenStage} from '../components/ScreenShot';
import {facts} from '../data';
import {appearance, display, ink, pop, useLayout} from '../theme';

const top = {x: 0, y: 0, w: 3200, h: 1546};
const topSquare = {x: 0, y: 0, w: 2620, h: 2000};

const Badge: React.FC<{text: string; delay: number}> = ({text, delay}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {square} = useLayout();
  const p = pop(frame, fps, delay, true);
  return (
    <div
      style={{
        position: 'absolute',
        bottom: square ? 36 : 30,
        padding: '14px 28px',
        borderRadius: 999,
        background: `${ink.chip}`,
        border: '1px solid rgba(233,182,90,0.55)',
        color: ink.goldLight,
        fontFamily: display,
        fontSize: square ? 28 : 30,
        fontWeight: 600,
        boxShadow: `0 20px 50px ${ink.shadow}`,
        transform: `scale(${p})`,
        opacity: p,
        whiteSpace: 'nowrap',
      }}
    >
      {text}
    </div>
  );
};

export const ExtensionsScreen: React.FC = () => (
  <ScreenStage
    eyebrow="Redesigned · New extension marketplace"
    title={['Install', 'only', 'what', 'you', {text: 'need.', gold: true}]}
    frames={[{src: 'extensions', from: 0}]}
    shots={{
      wide: [
        {at: 0, rect: top},
        {at: 50, rect: {x: 470, y: 100, w: 2730, h: 1319}},
        {at: 130, rect: {x: 480, y: 500, w: 1900, h: 918}},
      ],
      square: [
        {at: 0, rect: topSquare},
        {at: 50, rect: {x: 480, y: 100, w: 1800, h: 1376}},
        {at: 130, rect: {x: 480, y: 520, w: 1600, h: 1223}},
      ],
    }}
  >
    <Badge text={`${facts.extensions} extensions · one click each`} delay={70} />
  </ScreenStage>
);

export const UsageScreen: React.FC = () => (
  <ScreenStage
    eyebrow="Agent usage"
    title={['Know', 'what', 'your', 'agents', {text: 'cost.', gold: true}]}
    frames={[{src: 'usage', from: 0}]}
    glow={ink.coral}
    shots={{
      wide: [
        {at: 0, rect: top},
        {at: 50, rect: {x: 480, y: 440, w: 1980, h: 956}},
        {at: 130, rect: {x: 490, y: 450, w: 1360, h: 657}},
      ],
      square: [
        {at: 0, rect: topSquare},
        {at: 50, rect: {x: 480, y: 440, w: 1980, h: 1513}},
        {at: 130, rect: {x: 490, y: 450, w: 1360, h: 1040}},
      ],
    }}
  >
    <Badge text="Claude Code · Codex · Cursor · read locally" delay={60} />
  </ScreenStage>
);

export const StudioScreen: React.FC = () => (
  <ScreenStage
    eyebrow={`Studio · ${facts.studioTools} tools`}
    title={['Every', 'file', 'tool.', {text: 'Offline.', gold: true}]}
    frames={[{src: 'studio', from: 0}]}
    shots={{
      wide: [
        {at: 0, rect: top},
        {at: 50, rect: {x: 480, y: 620, w: 2720, h: 1314}},
        {at: 130, rect: {x: 490, y: 1080, w: 1460, h: 705}},
        {at: 190, rect: {x: 1820, y: 1080, w: 1360, h: 657}},
      ],
      square: [
        {at: 0, rect: topSquare},
        {at: 50, rect: {x: 480, y: 700, w: 1360, h: 1040}},
        {at: 150, rect: {x: 1830, y: 700, w: 1360, h: 1040}},
      ],
    }}
  >
    <Badge text="Merge, sign, compress, convert. Nothing uploaded." delay={70} />
  </ScreenStage>
);

export const DownloadsScreen: React.FC = () => (
  <ScreenStage
    eyebrow="Downloads"
    title={['Save', 'anything', 'from', 'a', {text: 'link.', gold: true}]}
    frames={[{src: 'downloads', from: 0}]}
    glow={ink.blue}
    shots={
      appearance === 'light'
        ? {
            wide: [
              {at: 0, rect: top},
              {at: 45, rect: {x: 760, y: 250, w: 1680, h: 811}},
            ],
            square: [
              {at: 0, rect: topSquare},
              {at: 45, rect: {x: 860, y: 250, w: 1480, h: 1132}},
            ],
          }
        : {
            wide: [
              {at: 0, rect: top},
              {at: 45, rect: {x: 1060, y: 110, w: 1600, h: 773}},
            ],
            square: [
              {at: 0, rect: topSquare},
              {at: 45, rect: {x: 1080, y: 110, w: 1500, h: 1147}},
            ],
          }
    }
  >
    <Badge text="YouTube · Instagram · TikTok · X · Reddit" delay={60} />
  </ScreenStage>
);

export const AttentionScreen: React.FC = () => (
  <ScreenStage
    eyebrow="Attention"
    title={['See', 'where', 'your', 'day', {text: 'went.', gold: true}]}
    frames={[{src: 'attention', from: 0}]}
    glow={ink.green}
    shots={{
      wide: [
        {at: 0, rect: top},
        {at: 45, rect: {x: 480, y: 560, w: 2720, h: 1314}},
        {at: 120, rect: {x: 480, y: 560, w: 1700, h: 821}},
      ],
      square: [
        {at: 0, rect: topSquare},
        {at: 45, rect: {x: 480, y: 560, w: 1700, h: 1300}},
      ],
    }}
  >
    <Badge text="Automatic time tracking · stays on your Mac" delay={60} />
  </ScreenStage>
);
