import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {Caption} from '../components/Caption';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

const rows = [
  {keys: ['&#8997;', '&#8984;', 'E'], action: 'Toggle panel'},
  {keys: ['&#8997;', '&#8984;', 'V'], action: 'Clipboard history'},
  {keys: ['&#8997;', '&#8984;', 'D'], action: 'Focus Dim'},
  {keys: ['&#8997;', '&#8984;', 'M'], action: 'Play / pause music'},
];

const Chip: React.FC<{glyph: string; lit: number}> = ({glyph, lit}) => (
  <div
    style={{
      width: 42,
      height: 42,
      borderRadius: 10,
      background: lit > 0.5 ? colors.accent : '#1c1814',
      border: `1px solid ${colors.border}`,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontSize: 18,
      fontWeight: 700,
      color: lit > 0.5 ? '#1a1208' : colors.text,
    }}
    dangerouslySetInnerHTML={{__html: glyph}}
  />
);

export const HotkeysScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  return (
    <Background>
      <div style={{display: 'flex', flexDirection: 'column', gap: 16, fontFamily}}>
        {rows.map((r, i) => {
          const p = springIn(frame, fps, 6 + i * 8);
          const lit = interpolate(springIn(frame, fps, 20 + i * 8, true), [0, 1], [0, 1]);
          return (
            <div
              key={r.action}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 20,
                width: 520,
                padding: '14px 20px',
                borderRadius: 16,
                background: colors.panel,
                border: `1px solid ${colors.border}`,
                opacity: interpolate(p, [0, 1], [0, 1]),
                transform: `translateY(${interpolate(p, [0, 1], [20, 0])}px)`,
              }}
            >
              <div style={{display: 'flex', gap: 8}}>
                {r.keys.map((k, ki) => (
                  <Chip key={ki} glyph={k} lit={lit} />
                ))}
              </div>
              <span style={{color: colors.text, fontSize: 19, fontWeight: 600}}>
                {r.action}
              </span>
            </div>
          );
        })}
      </div>

      <Caption>One shortcut for everything - remap any of them</Caption>
    </Background>
  );
};
