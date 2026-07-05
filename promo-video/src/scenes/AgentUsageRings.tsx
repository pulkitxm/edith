import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {AppFrame, SectionLabel} from '../components/AppFrame';
import {Ring} from '../components/Ring';
import {LimitsChart} from '../components/LimitsChart';
import {Caption} from '../components/Caption';
import {springIn} from '../animation';

export const AgentUsageRings: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const sessionP = springIn(frame, fps, 10);
  const weekP = springIn(frame, fps, 20);
  const chartP = interpolate(frame, [55, 125], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <Background>
      <AppFrame activeIndex={0}>
        <SectionLabel>LIMITS</SectionLabel>
        <div style={{display: 'flex', gap: 56, justifyContent: 'center', marginBottom: 28}}>
          <Ring
            percent={14}
            progress={interpolate(sessionP, [0, 1], [0, 1])}
            label="SESSION"
            startSeconds={3 * 3600 + 33 * 60 + 43}
          />
          <Ring
            percent={35}
            progress={interpolate(weekP, [0, 1], [0, 1])}
            label="WEEK"
            startSeconds={4 * 86400 + 13 * 3600 + 43 * 60 + 43}
          />
        </div>
        <LimitsChart progress={chartP} />
      </AppFrame>
      <Caption delay={65}>Live rate-limit rings, 24h history</Caption>
    </Background>
  );
};
