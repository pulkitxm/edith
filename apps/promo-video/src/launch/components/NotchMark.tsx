import React from 'react';
import {interpolate} from 'remotion';

const tilePath =
  'M512 100 C850 100 924 174 924 512 C924 850 850 924 512 924 C174 924 100 850 100 512 C100 174 174 100 512 100 Z';

const blades = [
  {points: '550.0,370.0 550.0,761.0 512.0,818.0 474.0,761.0 474.0,370.0', origin: '512px 370px'},
  {points: '648.8,326.4 800.5,611.6 793.7,679.7 733.3,647.2 581.7,362.1', origin: '615px 344px'},
  {points: '442.3,362.1 290.7,647.2 230.3,679.7 223.5,611.6 375.2,326.4', origin: '409px 344px'},
  {points: '715.6,241.5 833.4,321.0 859.4,384.3 790.9,384.0 673.1,304.5', origin: '694px 273px'},
  {points: '350.9,304.5 233.1,384.0 164.6,384.3 190.6,321.0 308.4,241.5', origin: '330px 273px'},
];

const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

export const NotchMark: React.FC<{
  size: number;
  progress?: number;
  tile?: boolean;
  shine?: number;
}> = ({size, progress = 1, tile = true, shine = 0}) => {
  const tileIn = interpolate(progress, [0, 0.2], [0, 1], clamp);
  const notchIn = interpolate(progress, [0.08, 0.28], [0, 1], clamp);
  const crescent = interpolate(progress, [0.2, 0.5], [0, 1], clamp);
  const shineX = interpolate(shine, [0, 1], [-400, 1400]);
  return (
    <svg width={size} height={size} viewBox="0 0 1024 1024" style={{overflow: 'visible'}}>
      <defs>
        <linearGradient id="nm-bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#102650" />
          <stop offset="0.55" stopColor="#0a1730" />
          <stop offset="1" stopColor="#050b18" />
        </linearGradient>
        <radialGradient id="nm-au" gradientUnits="userSpaceOnUse" cx="512" cy="150" r="640">
          <stop offset="0" stopColor="#fff6d2" />
          <stop offset="0.18" stopColor="#f0cd7a" />
          <stop offset="0.42" stopColor="#b98a34" />
          <stop offset="0.58" stopColor="#f7e2a6" />
          <stop offset="0.78" stopColor="#c79a45" />
          <stop offset="1" stopColor="#7f5719" />
        </radialGradient>
        <linearGradient id="nm-au3" gradientUnits="userSpaceOnUse" x1="300" y1="150" x2="720" y2="380">
          <stop offset="0" stopColor="#fff6d2" />
          <stop offset="0.18" stopColor="#f0cd7a" />
          <stop offset="0.42" stopColor="#b98a34" />
          <stop offset="0.58" stopColor="#f7e2a6" />
          <stop offset="0.78" stopColor="#c79a45" />
          <stop offset="1" stopColor="#7f5719" />
        </linearGradient>
        <linearGradient id="nm-shine" gradientUnits="userSpaceOnUse" x1={shineX - 120} y1="0" x2={shineX + 120} y2="300">
          <stop offset="0" stopColor="#fff" stopOpacity="0" />
          <stop offset="0.5" stopColor="#fff" stopOpacity="0.55" />
          <stop offset="1" stopColor="#fff" stopOpacity="0" />
        </linearGradient>
        <filter id="nm-glow" x="-40%" y="-40%" width="180%" height="180%">
          <feGaussianBlur stdDeviation="60" />
        </filter>
        <clipPath id="nm-tile">
          <path d={tilePath} />
        </clipPath>
      </defs>
      {tile ? (
        <g opacity={tileIn} style={{transformOrigin: '512px 512px', transform: `scale(${0.85 + tileIn * 0.15})`}}>
          <path d={tilePath} fill="url(#nm-bg)" />
          <path d={tilePath} fill="none" stroke="rgba(255,255,255,0.1)" strokeWidth="4" />
        </g>
      ) : null}
      <g clipPath={tile ? 'url(#nm-tile)' : undefined}>
        <ellipse cx="512" cy="400" rx="330" ry="260" fill="#e9b65a" opacity={0.14 * crescent} filter="url(#nm-glow)" />
        <g>
          {blades.map((b, i) => {
            const p = interpolate(progress, [0.4 + i * 0.08, 0.62 + i * 0.08], [0, 1], clamp);
            return (
              <g key={b.points}>
                <polygon
                  points={b.points}
                  fill="url(#nm-au)"
                  style={{transformOrigin: b.origin, transform: `scale(${p})`}}
                  opacity={p > 0 ? 1 : 0}
                />
                <polygon
                  points={b.points}
                  fill="url(#nm-shine)"
                  style={{transformOrigin: b.origin, transform: `scale(${p})`, mixBlendMode: 'overlay'}}
                  opacity={shine > 0 && shine < 1 ? 1 : 0}
                />
              </g>
            );
          })}
        </g>
        <path
          d="M318,150 A194,194 0 0 0 706,150 L670,150 A158,158 0 0 1 354,150 Z"
          fill="url(#nm-au3)"
          style={{clipPath: `inset(0 ${(1 - crescent) * 50}% 0 ${(1 - crescent) * 50}%)`}}
        />
        <path
          d="M352,92 L672,92 L672,100 C650,100 636,112 636,136 L636,150 C636,190 612,214 572,214 L452,214 C412,214 388,190 388,150 L388,136 C388,112 374,100 352,100 Z"
          fill="#000"
          style={{transformOrigin: '512px 92px', transform: `scaleY(${notchIn})`}}
        />
      </g>
    </svg>
  );
};
