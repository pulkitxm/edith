import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {Caption} from '../components/Caption';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

const entries = [
  {kind: 'Link', text: 'github.com/edith/releases', tag: '#f5a623'},
  {kind: 'Color', text: '#2b3a3d', tag: '#2b3a3d'},
  {kind: 'Code', text: 'git tag v1.10.1 && git push', tag: '#4c8a6f'},
  {kind: 'Text', text: 'Weekly usage back to green', tag: '#6a8fd0'},
];

export const ClipboardScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const panel = springIn(frame, fps, 0, true);

  return (
    <Background>
      <div
        style={{
          width: 560,
          borderRadius: 24,
          background: colors.panel,
          border: `1px solid ${colors.border}`,
          boxShadow: '0 40px 120px rgba(0,0,0,0.55)',
          fontFamily,
          overflow: 'hidden',
          opacity: interpolate(panel, [0, 1], [0, 1]),
          transform: `scale(${interpolate(panel, [0, 1], [0.9, 1])}) translateY(${interpolate(panel, [0, 1], [24, 0])}px)`,
        }}
      >
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '22px 26px 16px',
          }}
        >
          <span style={{color: colors.text, fontSize: 20, fontWeight: 700}}>
            Clipboard
          </span>
          <span style={{color: colors.label, fontSize: 14, letterSpacing: 2}}>
            &#8997;&#8984;V
          </span>
        </div>

        <div style={{padding: '0 16px 18px'}}>
          {entries.map((e, i) => {
            const p = springIn(frame, fps, 10 + i * 6);
            const active = i === 0;
            return (
              <div
                key={e.text}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 16,
                  padding: '14px 16px',
                  borderRadius: 14,
                  background: active ? colors.accentSoft : 'transparent',
                  opacity: interpolate(p, [0, 1], [0, 1]),
                  transform: `translateX(${interpolate(p, [0, 1], [18, 0])}px)`,
                }}
              >
                <div
                  style={{
                    width: 12,
                    height: 12,
                    borderRadius: 4,
                    background: e.tag,
                    flexShrink: 0,
                  }}
                />
                <div style={{flex: 1, minWidth: 0}}>
                  <div style={{color: colors.label, fontSize: 12, letterSpacing: 1}}>
                    {e.kind.toUpperCase()}
                  </div>
                  <div
                    style={{
                      color: active ? colors.text : colors.textDim,
                      fontSize: 17,
                      fontWeight: 600,
                      whiteSpace: 'nowrap',
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                    }}
                  >
                    {e.text}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>

      <Caption>Clipboard history - every copy, one keystroke away</Caption>
    </Background>
  );
};
