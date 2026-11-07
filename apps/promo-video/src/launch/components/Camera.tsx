import React from 'react';
import {interpolate} from 'remotion';
import {smooth} from '../theme';

export type Rect = {x: number; y: number; w: number; h: number};
export type Shot = {at: number; rect: Rect};

const lerpRect = (a: Rect, b: Rect, t: number): Rect => ({
  x: a.x + (b.x - a.x) * t,
  y: a.y + (b.y - a.y) * t,
  w: a.w + (b.w - a.w) * t,
  h: a.h + (b.h - a.h) * t,
});

export const cameraRect = (frame: number, shots: Shot[], move = 30): Rect => {
  let rect = shots[0].rect;
  for (let i = 1; i < shots.length; i++) {
    const t = interpolate(frame, [shots[i].at, shots[i].at + move], [0, 1], {
      easing: smooth,
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    });
    rect = lerpRect(rect, shots[i].rect, t);
  }
  return rect;
};

export const Camera: React.FC<{
  view: {width: number; height: number};
  source: {width: number; height: number};
  rect: Rect;
  radius?: number;
  children: React.ReactNode;
}> = ({view, source, rect, radius = 18, children}) => {
  const scale = Math.min(view.width / rect.w, view.height / rect.h);
  const cx = rect.x + rect.w / 2;
  const cy = rect.y + rect.h / 2;
  return (
    <div
      style={{
        width: view.width,
        height: view.height,
        overflow: 'hidden',
        position: 'relative',
        borderRadius: radius,
      }}
    >
      <div
        style={{
          position: 'absolute',
          width: source.width,
          height: source.height,
          left: 0,
          top: 0,
          transformOrigin: '0 0',
          transform: `translate(${view.width / 2 - cx * scale}px, ${view.height / 2 - cy * scale}px) scale(${scale})`,
        }}
      >
        {children}
      </div>
    </div>
  );
};
