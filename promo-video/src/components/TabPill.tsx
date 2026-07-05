import React from 'react';
import {colors} from '../tokens';

const TABS = [
  {label: 'Agent Usage', width: 176},
  {label: 'Music', width: 100},
  {label: 'System', width: 108},
  {label: 'Calendar', width: 128},
];
const GAP = 10;

const rectFor = (index: number) => {
  const clamped = Math.max(0, Math.min(TABS.length - 1, index));
  const lo = Math.floor(clamped);
  const hi = Math.min(TABS.length - 1, lo + 1);
  const t = clamped - lo;

  const xAt = (i: number) =>
    TABS.slice(0, i).reduce((sum, tab) => sum + tab.width + GAP, 0);

  const x = xAt(lo) + (xAt(hi) - xAt(lo)) * t;
  const width = TABS[lo].width + (TABS[hi].width - TABS[lo].width) * t;
  return {x, width};
};

export const TabPill: React.FC<{activeIndex: number}> = ({activeIndex}) => {
  const {x, width} = rectFor(activeIndex);

  return (
    <div style={{position: 'relative', height: 46}}>
      <div
        style={{
          position: 'absolute',
          top: 0,
          left: x,
          width,
          height: 46,
          borderRadius: 23,
          background: colors.accent,
        }}
      />
      <div style={{display: 'flex', gap: GAP, position: 'relative'}}>
        {TABS.map((tab, i) => {
          const active = Math.round(activeIndex) === i;
          return (
            <div
              key={tab.label}
              style={{
                width: tab.width,
                height: 46,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                color: active ? '#1a1208' : colors.textDim,
                fontWeight: 600,
                fontSize: 16,
              }}
            >
              {tab.label}
            </div>
          );
        })}
      </div>
    </div>
  );
};
