import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {display, goldGradient, ink, pop} from '../theme';

export type Word = string | {text: string; gold?: boolean; dim?: boolean};

const normalize = (w: Word) => (typeof w === 'string' ? {text: w} : w);

export const Kinetic: React.FC<{
  words: Word[];
  delay?: number;
  stagger?: number;
  size?: number;
  weight?: number;
  align?: 'left' | 'center';
  color?: string;
  maxWidth?: number;
  lineHeight?: number;
}> = ({
  words,
  delay = 0,
  stagger = 3,
  size = 120,
  weight = 700,
  align = 'center',
  color = ink.text,
  maxWidth,
  lineHeight = 1.02,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  return (
    <div
      style={{
        fontFamily: display,
        fontSize: size,
        fontWeight: weight,
        letterSpacing: '-0.045em',
        lineHeight,
        color,
        textAlign: align,
        maxWidth,
        display: 'flex',
        flexWrap: 'wrap',
        justifyContent: align === 'center' ? 'center' : 'flex-start',
        columnGap: '0.24em',
      }}
    >
      {words.map((raw, i) => {
        const w = normalize(raw);
        const p = pop(frame, fps, delay + i * stagger);
        return (
          <span
            key={`${w.text}-${i}`}
            style={{
              display: 'inline-block',
              opacity: interpolate(p, [0, 1], [0, 1]),
              transform: `translateY(${interpolate(p, [0, 1], [0.45, 0])}em)`,
              filter: `blur(${interpolate(p, [0, 1], [14, 0])}px)`,
              paddingBottom: '0.08em',
              color: w.dim ? ink.textFaint : undefined,
              backgroundImage: w.gold ? goldGradient : undefined,
              WebkitBackgroundClip: w.gold ? 'text' : undefined,
              WebkitTextFillColor: w.gold ? 'transparent' : undefined,
            }}
          >
            {w.text}
          </span>
        );
      })}
    </div>
  );
};

export const Eyebrow: React.FC<{children: React.ReactNode; delay?: number; color?: string}> = ({
  children,
  delay = 0,
  color = ink.gold,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const p = pop(frame, fps, delay);
  return (
    <div
      style={{
        fontFamily: display,
        fontSize: 26,
        fontWeight: 600,
        letterSpacing: '0.28em',
        textTransform: 'uppercase',
        color,
        opacity: p,
        transform: `translateY(${(1 - p) * 12}px)`,
      }}
    >
      {children}
    </div>
  );
};
