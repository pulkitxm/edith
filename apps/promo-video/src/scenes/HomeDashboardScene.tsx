import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {Caption} from '../components/Caption';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

const clocks = [
  {city: 'San Francisco', time: '08:24', meridiem: 'AM'},
  {city: 'London', time: '04:24', meridiem: 'PM'},
  {city: 'Tokyo', time: '12:24', meridiem: 'AM'},
];

const meetings = [
  {time: '09:00', title: 'Standup', accent: true},
  {time: '11:30', title: 'Design review'},
  {time: '15:00', title: '1:1 with Priya'},
];

export const HomeDashboardScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const panel = springIn(frame, fps, 0, true);

  return (
    <Background>
      <div
        style={{
          width: 780,
          borderRadius: 26,
          background: colors.panel,
          border: `1px solid ${colors.border}`,
          boxShadow: '0 40px 120px rgba(0,0,0,0.55)',
          fontFamily,
          padding: '30px 34px',
          opacity: interpolate(panel, [0, 1], [0, 1]),
          transform: `scale(${interpolate(panel, [0, 1], [0.92, 1])}) translateY(${interpolate(panel, [0, 1], [22, 0])}px)`,
        }}
      >
        <div
          style={{
            color: colors.text,
            fontSize: 22,
            fontWeight: 700,
            marginBottom: 24,
          }}
        >
          Good morning
        </div>

        <div style={{display: 'flex', gap: 16, marginBottom: 26}}>
          {clocks.map((c, i) => {
            const p = springIn(frame, fps, 10 + i * 6);
            return (
              <div
                key={c.city}
                style={{
                  flex: 1,
                  borderRadius: 16,
                  background: 'rgba(255,255,255,0.04)',
                  padding: '18px 20px',
                  opacity: interpolate(p, [0, 1], [0, 1]),
                  transform: `translateY(${interpolate(p, [0, 1], [16, 0])}px)`,
                }}
              >
                <div style={{color: colors.label, fontSize: 13}}>{c.city}</div>
                <div style={{color: colors.text, fontSize: 30, fontWeight: 700, marginTop: 6}}>
                  {c.time}
                  <span style={{color: colors.textDim, fontSize: 15, marginLeft: 6}}>
                    {c.meridiem}
                  </span>
                </div>
              </div>
            );
          })}
        </div>

        <div style={{color: colors.label, fontSize: 13, letterSpacing: 2, marginBottom: 12}}>
          TODAY
        </div>
        {meetings.map((m, i) => {
          const p = springIn(frame, fps, 26 + i * 6);
          return (
            <div
              key={m.title}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 18,
                padding: '12px 4px',
                opacity: interpolate(p, [0, 1], [0, 1]),
                transform: `translateX(${interpolate(p, [0, 1], [16, 0])}px)`,
              }}
            >
              <div
                style={{
                  width: 4,
                  height: 34,
                  borderRadius: 2,
                  background: m.accent ? colors.accent : colors.track,
                }}
              />
              <span style={{color: colors.textDim, fontSize: 17, width: 70}}>{m.time}</span>
              <span style={{color: colors.text, fontSize: 18, fontWeight: 600}}>{m.title}</span>
            </div>
          );
        })}
      </div>

      <Caption>A home base - clocks, meetings and usage at a glance</Caption>
    </Background>
  );
};
