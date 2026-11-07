import React from 'react';
import {AbsoluteFill, interpolate, Sequence, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {IconTile} from '../components/Icon';
import {extensions, facts} from '../data';
import {display, goldGradient, ink, pop, ramp, useLayout} from '../theme';
import {ExtensionsScreen} from './Screens';

export const storeLength = 216;
export const wallLength = 135;

const Wall: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {square} = useLayout();
  const cols = square ? 7 : 9;
  const size = square ? 96 : 104;
  const gap = square ? 30 : 34;
  const count = Math.round(ramp(frame, 0, 40, [0, facts.extensions]));
  const zoom = interpolate(frame, [0, wallLength], [1.08, 1]);
  return (
    <Backdrop glow={ink.coral}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div style={{display: 'grid', gridTemplateColumns: `repeat(${cols}, ${size}px)`, gap, transform: `scale(${zoom})`, opacity: 0.5}}>
          {extensions.map((e, i) => {
            const d = Math.hypot((i % cols) - (cols - 1) / 2, Math.floor(i / cols) - 2.5);
            const p = pop(frame, fps, d * 3, true);
            return (
              <div key={e.id} style={{transform: `scale(${p})`, opacity: p}}>
                <IconTile name={e.id} size={size} glow={0.3} />
              </div>
            );
          })}
        </div>
        <AbsoluteFill
          style={{
            alignItems: 'center',
            justifyContent: 'center',
            background: `radial-gradient(42% 38% at 50% 50%, ${ink.scrim}, ${ink.scrimSoft} 100%)`,
          }}
        >
          <div
            style={{
              fontFamily: display,
              fontSize: square ? 260 : 300,
              fontWeight: 800,
              letterSpacing: '-0.06em',
              lineHeight: 0.9,
              backgroundImage: goldGradient,
              WebkitBackgroundClip: 'text',
              WebkitTextFillColor: 'transparent',
              fontVariantNumeric: 'tabular-nums',
            }}
          >
            {count}
          </div>
          <div style={{fontFamily: display, fontSize: square ? 52 : 58, fontWeight: 700, color: ink.text, letterSpacing: '-0.03em', textAlign: 'center'}}>
            extensions and counting.
          </div>
          <div style={{fontFamily: display, fontSize: 28, color: ink.textSoft, marginTop: 16, opacity: ramp(frame, 24, 40), textAlign: 'center', maxWidth: square ? 900 : undefined}}>
            Agents, PDFs, downloads, clipboard, notch, music, servers and more.
          </div>
        </AbsoluteFill>
      </AbsoluteFill>
    </Backdrop>
  );
};

export const Marketplace: React.FC = () => (
  <>
    <Sequence durationInFrames={storeLength}>
      <ExtensionsScreen />
    </Sequence>
    <Sequence from={storeLength} durationInFrames={wallLength}>
      <Wall />
    </Sequence>
  </>
);
