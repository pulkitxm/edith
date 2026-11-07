import React from 'react';
import {staticFile} from 'remotion';

export const Icon: React.FC<{name: string; size: number; color: string; style?: React.CSSProperties}> = ({
  name,
  size,
  color,
  style,
}) => {
  const url = `url(${staticFile(`launch/icons/${name}.svg`)})`;
  return (
    <div
      style={{
        width: size,
        height: size,
        background: color,
        WebkitMaskImage: url,
        maskImage: url,
        WebkitMaskSize: 'contain',
        maskSize: 'contain',
        WebkitMaskRepeat: 'no-repeat',
        maskRepeat: 'no-repeat',
        flexShrink: 0,
        ...style,
      }}
    />
  );
};

export const IconTile: React.FC<{name: string; size: number; tint?: string; glow?: number}> = ({
  name,
  size,
  tint = '#f5f5f7',
  glow = 0,
}) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: size * 0.26,
      background: 'linear-gradient(160deg, #2e2e32, #1c1c1f)',
      border: '1px solid rgba(255,255,255,0.08)',
      boxShadow: `0 ${size * 0.12}px ${size * 0.4}px rgba(0,0,0,0.45), 0 0 ${glow * size * 0.6}px rgba(233,182,90,${glow * 0.45})`,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      flexShrink: 0,
    }}
  >
    <Icon name={name} size={size * 0.52} color={tint} />
  </div>
);
