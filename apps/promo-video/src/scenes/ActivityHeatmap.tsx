import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {AppFrame, SectionLabel} from '../components/AppFrame';
import {HeatmapGrid} from '../components/HeatmapGrid';
import {Caption} from '../components/Caption';
import {colors} from '../tokens';

export const ActivityHeatmap: React.FC = () => {
  const frame = useCurrentFrame();
  const progress = interpolate(frame, [10, 82], [0, 1.2], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <Background>
      <AppFrame activeIndex={0} width={920}>
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'baseline',
            marginBottom: 20,
          }}
        >
          <SectionLabel>ACTIVITY</SectionLabel>
          <span style={{color: colors.label, fontSize: 14}}>$32164 · 18 weeks</span>
        </div>
        <div style={{display: 'flex', justifyContent: 'center'}}>
          <HeatmapGrid progress={progress} />
        </div>
      </AppFrame>
      <Caption>Full activity history, at a glance</Caption>
    </Background>
  );
};
