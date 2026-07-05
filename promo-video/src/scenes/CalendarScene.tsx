import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {AppFrame} from '../components/AppFrame';
import {Caption} from '../components/Caption';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

type CalEvent = {time: string; title: string; location?: string; link?: string};

const GROUPS: {day: string; date: string; events: CalEvent[]}[] = [
  {
    day: 'Today',
    date: 'Jul 5',
    events: [
      {time: '9:00 AM – 9:30 AM', title: 'Daily Standup', link: 'meet.google.com'},
      {time: '2:00 PM – 2:45 PM', title: 'Design Review', location: 'Conference Room B'},
    ],
  },
  {
    day: 'Tomorrow',
    date: 'Jul 6',
    events: [{time: '11:00 AM – 12:00 PM', title: '1:1 with Sarah', link: 'zoom.us'}],
  },
  {
    day: 'Monday',
    date: 'Jul 7',
    events: [{time: 'All day', title: 'Team Offsite'}],
  },
];

const providerColor = (link?: string) => {
  if (!link) return colors.accent;
  if (link.includes('zoom.us')) return '#2e8cff';
  if (link.includes('meet.google.com')) return '#00ab47';
  if (link.includes('teams.')) return '#6164a6';
  if (link.includes('webex.com')) return '#00bdeb';
  return colors.accent;
};

const VideoIcon: React.FC<{color: string}> = ({color}) => (
  <svg width="15" height="15" viewBox="0 0 24 24" fill={color} style={{flexShrink: 0}}>
    <rect x="2" y="6" width="14" height="12" rx="2.5" />
    <path d="M17 9.5l5-3.2v11.4l-5-3.2z" />
  </svg>
);

export const CalendarScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const tabIndex = interpolate(springIn(frame, fps, 0), [0, 1], [1, 3]);

  let rowIndex = 0;

  return (
    <Background>
      <AppFrame activeIndex={tabIndex}>
        <div style={{display: 'flex', flexDirection: 'column', gap: 22, fontFamily}}>
          {GROUPS.map((group) => {
            const headerDelay = rowIndex * 10 + 20;
            rowIndex += 1;
            return (
              <div key={group.day}>
                <Row delay={headerDelay} frame={frame} fps={fps}>
                  <div
                    style={{
                      color: colors.label,
                      fontSize: 13,
                      fontWeight: 600,
                      letterSpacing: 1.5,
                      marginBottom: 12,
                    }}
                  >
                    {`${group.day} · ${group.date}`.toUpperCase()}
                  </div>
                </Row>
                {group.events.map((event) => {
                  const delay = rowIndex * 10 + 20;
                  rowIndex += 1;
                  return (
                    <Row key={event.title} delay={delay} frame={frame} fps={fps}>
                      <div
                        style={{
                          display: 'flex',
                          alignItems: 'flex-start',
                          gap: 16,
                          padding: '7px 0',
                        }}
                      >
                        <span
                          style={{
                            color: colors.textDim,
                            fontSize: 14,
                            width: 170,
                            flexShrink: 0,
                            fontVariantNumeric: 'tabular-nums',
                          }}
                        >
                          {event.time}
                        </span>
                        <div style={{flex: 1}}>
                          <div style={{color: colors.text, fontSize: 16}}>{event.title}</div>
                          {event.location && (
                            <div style={{color: colors.label, fontSize: 13, marginTop: 2}}>
                              {event.location}
                            </div>
                          )}
                        </div>
                        {event.link && (
                          <div style={{paddingTop: 2}}>
                            <VideoIcon color={providerColor(event.link)} />
                          </div>
                        )}
                      </div>
                    </Row>
                  );
                })}
              </div>
            );
          })}
        </div>
      </AppFrame>
      <Caption>Today's schedule, right in the panel</Caption>
    </Background>
  );
};

const Row: React.FC<{delay: number; frame: number; fps: number; children: React.ReactNode}> = ({
  delay,
  frame,
  fps,
  children,
}) => {
  const p = interpolate(springIn(frame, fps, delay), [0, 1], [0, 1]);
  return (
    <div style={{opacity: p, transform: `translateY(${(1 - p) * 10}px)`}}>{children}</div>
  );
};
