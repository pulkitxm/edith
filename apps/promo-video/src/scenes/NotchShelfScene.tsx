import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {Caption} from '../components/Caption';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

const files = [
  {label: 'design.fig', color: '#a259ff'},
  {label: 'invoice.pdf', color: '#ff5f57'},
  {label: 'demo.mov', color: '#f5a623'},
];

export const NotchShelfScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const shelf = springIn(frame, fps, 6, true);

  return (
    <Background>
      <div style={{position: 'relative', width: 760, height: 420}}>
        <div
          style={{
            position: 'absolute',
            top: 0,
            left: '50%',
            transform: 'translateX(-50%)',
            width: 260,
            height: 34,
            background: '#000',
            borderBottomLeftRadius: 20,
            borderBottomRightRadius: 20,
          }}
        />

        <div
          style={{
            position: 'absolute',
            top: 30,
            left: '50%',
            transform: `translateX(-50%) scaleY(${interpolate(shelf, [0, 1], [0.4, 1])})`,
            transformOrigin: 'top',
            opacity: interpolate(shelf, [0, 1], [0, 1]),
            width: 320,
            padding: '18px 20px',
            borderRadius: 20,
            background: colors.panel,
            border: `1px solid ${colors.border}`,
            boxShadow: '0 30px 80px rgba(0,0,0,0.55)',
            display: 'flex',
            gap: 14,
            justifyContent: 'center',
            fontFamily,
          }}
        >
          {files.map((f, i) => {
            const drop = springIn(frame, fps, 24 + i * 10, true);
            return (
              <div
                key={f.label}
                style={{
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  gap: 8,
                  opacity: interpolate(drop, [0, 1], [0, 1]),
                  transform: `translateY(${interpolate(drop, [0, 1], [80, 0])}px)`,
                }}
              >
                <div
                  style={{
                    width: 58,
                    height: 58,
                    borderRadius: 12,
                    background: `linear-gradient(135deg, ${f.color} 0%, rgba(0,0,0,0.3) 140%)`,
                  }}
                />
                <span style={{color: colors.textDim, fontSize: 12}}>{f.label}</span>
              </div>
            );
          })}
        </div>
      </div>

      <Caption>Notch shelf - drop files on the notch, carry them anywhere</Caption>
    </Background>
  );
};
