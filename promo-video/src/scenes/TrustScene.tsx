import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

// Genuine claims, not invented ones: README states usage data never leaves
// the machine, and SettingsView.swift has real optional iCloud backup toggles.
const ROWS = [
  'Free and open source',
  'Your data never leaves your Mac',
  'Optional iCloud sync across your Macs',
];

export const TrustScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  return (
    <Background>
      <div style={{display: 'flex', flexDirection: 'column', gap: 30, fontFamily}}>
        {ROWS.map((text, i) => {
          const p = interpolate(springIn(frame, fps, i * 22), [0, 1], [0, 1]);
          return (
            <div
              key={text}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 22,
                opacity: p,
                transform: `translateY(${(1 - p) * 16}px)`,
              }}
            >
              <span
                style={{
                  width: 34,
                  height: 34,
                  borderRadius: 17,
                  background: colors.accentSoft,
                  color: colors.accent,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 17,
                  fontWeight: 700,
                  flexShrink: 0,
                }}
              >
                &#10003;
              </span>
              <span style={{color: colors.text, fontSize: 26, fontWeight: 500}}>
                {text}
              </span>
            </div>
          );
        })}
      </div>
    </Background>
  );
};
