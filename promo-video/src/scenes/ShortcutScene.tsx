import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {KeyCap} from '../components/KeyCap';
import {AppFrame, SectionLabel} from '../components/AppFrame';
import {Ring} from '../components/Ring';
import {Caption} from '../components/Caption';
import {springIn} from '../animation';

const pressedAt = (frame: number, fps: number, at: number) => {
  const p = springIn(frame, fps, at, true);
  return interpolate(p, [0, 1], [0, 1]);
};

export const ShortcutScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const opt = pressedAt(frame, fps, 0);
  const cmd = pressedAt(frame, fps, 6);
  const e = pressedAt(frame, fps, 12);

  const keysOut = interpolate(frame, [38, 58], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const panelP = springIn(frame, fps, 42);
  const panelScale = interpolate(panelP, [0, 1], [0.85, 1]);
  const panelOpacity = interpolate(panelP, [0, 1], [0, 1]);

  return (
    <Background>
      <div
        style={{
          position: 'absolute',
          display: 'flex',
          gap: 20,
          opacity: 1 - keysOut,
          transform: `translateY(${-keysOut * 40}px) scale(${1 - keysOut * 0.15})`,
        }}
      >
        <KeyCap glyph="&#8997;" pressed={opt} />
        <KeyCap glyph="&#8984;" pressed={cmd} />
        <KeyCap glyph="E" pressed={e} />
      </div>

      {panelOpacity > 0.02 && (
        <div
          style={{
            opacity: panelOpacity,
            transform: `scale(${panelScale * 0.62})`,
          }}
        >
          <AppFrame activeIndex={0}>
            <SectionLabel>LIMITS</SectionLabel>
            <div style={{display: 'flex', gap: 56, justifyContent: 'center'}}>
              <Ring percent={14} progress={1} label="SESSION" startSeconds={12823} />
              <Ring percent={35} progress={1} label="WEEK" startSeconds={395023} />
            </div>
          </AppFrame>
        </div>
      )}

      <Caption>One shortcut, anywhere</Caption>
    </Background>
  );
};
